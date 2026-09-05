"""Offline regression tests for version decisions and resumable release planning."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from publish_release import asset_names, commit_messages, publish, release_plan
from release_assets import validate_asset_metadata, verify_release_assets
from release_version import next_version, version_parts


class ReleaseTests(unittest.TestCase):
    def test_bootstrap_is_one_point_zero(self):
        self.assertEqual(next_version(None, ["feat!: initial release"]), "1.0.0")
        self.assertEqual(release_plan(["a", "b"], {}, set(), lambda _: []), [("v1.0.0", "b")])

    def test_bump_precedence(self):
        cases = [(["fix: bug"], "1.2.4"), (["perf: faster"], "1.2.4"),
                 (["feat(scope): support new input"], "1.3.0"),
                 (["fix!: new format"], "2.0.0"),
                 (["feat(scope)!: new format"], "2.0.0"),
                 (["fix: update\n\nBREAKING CHANGE: format changed"], "2.0.0"),
                 (["fix: update\n\nBREAKING-CHANGE: format changed"], "2.0.0"),
                 (["feat: feature", "fix!: incompatible"], "2.0.0"),
                 (["docs: mention feat: examples", "fix: loud!"], "1.2.4"),
                 (["fix: prose says BREAKING CHANGE: but is not a footer"], "1.2.4"),
                 (["", "featish: not a feature"], "1.2.4")]
        for messages, expected in cases:
            with self.subTest(messages=messages):
                self.assertEqual(next_version("1.2.3", messages), expected)

    def test_invalid_versions(self):
        for version in ["v1.0.0", "01.2.3", "1.2", "-1.0.0", "1.0.0-beta", "1.0.0+sha", "1.0.0\n"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                version_parts(version)
        self.assertEqual(next_version("1.2.999", ["fix: bug"]), "1.2.1000")

    def test_backlog_is_never_coalesced(self):
        messages = {"b": ["feat: feature"], "c": ["fix: bug"], "d": ["refactor!: format"]}
        self.assertEqual(release_plan(["a", "b", "c", "d"], {"v1.0.0": "a"}, {"v1.0.0"}, messages.get),
                         [("v1.1.0", "b"), ("v1.1.1", "c"), ("v2.0.0", "d")])

    def test_orphan_tag_and_draft_are_retried_before_new_work(self):
        tags = {"v1.0.0": "a", "v1.0.1": "b"}
        expected = [("v1.0.1", "b"), ("v1.0.2", "c")]
        self.assertEqual(release_plan(["a", "b", "c"], tags, {"v1.0.0"}, lambda _: []), expected)
        self.assertEqual(release_plan(["a", "b"], tags, set(tags), lambda _: []), [])

    def test_rewritten_or_misordered_main_is_rejected(self):
        for tags in [{"v1.0.0": "gone"}, {"v1.0.0": "b", "v1.0.1": "a"},
                     {"v1.0.0": "a", "v1.0.1": "a"}]:
            with self.subTest(tags=tags), self.assertRaises(ValueError):
                release_plan(["a", "b"], tags, set(), lambda _: [])

    def test_real_merge_history_preserves_nonfirst_subjects(self):
        for subject, expected in [("feat(scope): add feature", "1.1.0"),
                                  ("fix(scope)!: replace format", "2.0.0")]:
            with self.subTest(subject=subject), tempfile.TemporaryDirectory(prefix="release-git-test-") as root:
                def git(*arguments):
                    return subprocess.run(
                        ["git", "-c", "user.name=Release Fixture", "-c", "user.email=fixture@example.invalid",
                         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments],
                        cwd=root, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
                    ).stdout.strip()
                git("init", "--initial-branch=main")
                git("commit", "--allow-empty", "-m", "chore: initial")
                baseline = git("rev-parse", "HEAD")
                git("switch", "-c", "feature")
                git("commit", "--allow-empty", "-m", subject)
                git("switch", "main")
                git("merge", "--no-ff", "--no-gpg-sign", "feature", "-m", "chore: merge feature branch")
                head = git("rev-parse", "HEAD")
                raw = git("log", "--format=%B%x00", f"{head}^..{head}")
                self.assertIn("\0\n", raw, "Fixture must exercise Git's real record boundary")
                messages = commit_messages(head, cwd=root)
                self.assertEqual(messages[0], "chore: merge feature branch")
                self.assertIn(subject, messages[1:])
                self.assertEqual(release_plan([baseline, head], {"v1.0.0": baseline}, {"v1.0.0"},
                                             lambda sha: commit_messages(sha, cwd=root)), [(f"v{expected}", head)])

    def test_uploaded_integrity_rejects_same_size_corruption(self):
        tag = "v1.0.0"
        archive_name, checksum_name = asset_names(tag)
        payload = b"valid ZIP fixture"
        digest = hashlib.sha256(payload).hexdigest()
        checksum = f"{digest}  {archive_name}\n".encode()
        release = {"assets": [
            {"id": 1, "name": archive_name, "size": len(payload), "digest": f"sha256:{digest}"},
            {"id": 2, "name": checksum_name, "size": len(checksum),
             "digest": f"sha256:{hashlib.sha256(checksum).hexdigest()}"},
        ]}
        with tempfile.TemporaryDirectory(prefix="release-integrity-test-") as root:
            directory = Path(root)
            (directory / archive_name).write_bytes(payload)
            (directory / checksum_name).write_bytes(checksum)
            with patch("release_assets.download_checksum", return_value=checksum), \
                 patch("release_assets.download_archive") as download:
                verify_release_assets("owner/repo", tag, release, directory)
                download.assert_not_called()
                release["assets"][0]["digest"] = "sha256:" + "0" * 64
                with self.assertRaisesRegex(ValueError, "GitHub digest mismatch"):
                    verify_release_assets("owner/repo", tag, release, directory)
                release["assets"][0]["digest"] = f"sha256:{digest}"
                (directory / archive_name).write_bytes(b"x" * len(payload))
                with self.assertRaisesRegex(ValueError, "does not match the built archive"):
                    verify_release_assets("owner/repo", tag, release, directory)
            corrupt_checksum = ("0" * 64 + f"  {archive_name}\n").encode()
            with patch("release_assets.download_checksum", return_value=corrupt_checksum):
                with self.assertRaisesRegex(ValueError, "GitHub digest mismatch"):
                    verify_release_assets("owner/repo", tag, release, directory)

    def test_missing_server_digest_checks_download_and_history_stays_metadata_only(self):
        tag = "v1.0.0"
        archive_name, checksum_name = asset_names(tag)
        payload = b"zip fixture"
        checksum = f"{hashlib.sha256(payload).hexdigest()}  {archive_name}\n".encode()
        release = {"assets": [
            {"id": 1, "name": archive_name, "size": len(payload)},
            {"id": 2, "name": checksum_name, "size": len(checksum)},
        ]}
        with patch("release_assets.download_checksum", return_value=checksum) as fetch, \
             patch("release_assets.download_archive", side_effect=lambda repo, tag, name, path: path.write_bytes(payload)) as download:
            validate_asset_metadata(tag, release)
            fetch.assert_not_called()
            download.assert_not_called()
            verify_release_assets("owner/repo", tag, release)
            download.assert_called_once()
        with patch("release_assets.download_checksum", return_value=checksum), \
             patch("release_assets.download_archive", side_effect=lambda repo, tag, name, path: path.write_bytes(b"x" * len(payload))):
            with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                verify_release_assets("owner/repo", tag, release)

    def exercise_publication(self, *, existing=None, tagged=False, failure=None, remote_sha="built-sha"):
        calls = []

        def fake_run(arguments, **kwargs):
            calls.append(arguments)
            if failure == "upload" and arguments[:3] == ["gh", "release", "upload"]:
                raise subprocess.CalledProcessError(1, arguments)
            return ""

        def fake_build(arguments, **kwargs):
            calls.append(arguments)
            if failure == "verify" and arguments[1].endswith("verify.py"):
                raise subprocess.CalledProcessError(1, arguments)
            if "--output-dir" in arguments:
                directory = Path(arguments[arguments.index("--output-dir") + 1])
                directory.mkdir()
                for name in asset_names("v1.0.0"):
                    (directory / name).write_bytes(b"fixture")

        def fake_integrity(*arguments, **kwargs):
            calls.append(["verify_assets"])
            if failure == "integrity":
                raise ValueError("Uploaded checksum differs from the build")

        with patch("publish_release.run", side_effect=fake_run), \
             patch("publish_release.subprocess.run", side_effect=fake_build), \
             patch("publish_release.tag_commit", return_value=remote_sha), \
             patch("publish_release.verify_release_assets", side_effect=fake_integrity), \
             patch("publish_release.releases_by_tag", return_value={"v1.0.0": {"assets": [
                 {"name": name, "size": 7} for name in asset_names("v1.0.0")]}}):
            if failure or remote_sha != "built-sha":
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    publish("owner/repo", "v1.0.0", "built-sha", existing, tagged)
            else:
                publish("owner/repo", "v1.0.0", "built-sha", existing, tagged)
        return calls

    def test_publication_checks_exact_revision_before_exposing_assets(self):
        calls = self.exercise_publication()
        self.assertEqual(calls[0][-1], "built-sha")
        verify = next(i for i, call in enumerate(calls) if len(call) > 1 and call[1].endswith("verify.py"))
        reserve = next(i for i, call in enumerate(calls) if "refs/tags/v1.0.0" in " ".join(call))
        create = next(i for i, call in enumerate(calls) if call[:3] == ["gh", "release", "create"])
        upload = next(i for i, call in enumerate(calls) if call[:3] == ["gh", "release", "upload"])
        integrity = calls.index(["verify_assets"])
        expose = next(i for i, call in enumerate(calls) if call[:3] == ["gh", "release", "edit"])
        self.assertLess(verify, reserve)
        self.assertLess(reserve, create)
        self.assertLess(create, upload)
        self.assertLess(upload, integrity)
        self.assertLess(integrity, expose)
        self.assertIn("built-sha", calls[create])
        self.assertIn("--draft", calls[create])

    def test_failures_never_publish_and_retry_reuses_draft(self):
        for failure in ["verify", "upload", "integrity"]:
            with self.subTest(failure=failure):
                calls = self.exercise_publication(failure=failure)
                self.assertFalse(any(call[:3] == ["gh", "release", "edit"] for call in calls))
                if failure == "verify":
                    self.assertFalse(any(call[0] == "gh" for call in calls))
        calls = self.exercise_publication(existing={"draft": True}, tagged=True)
        self.assertFalse(any(call[:3] == ["gh", "release", "create"] for call in calls))
        self.assertFalse(any("--method" in call for call in calls))
        self.assertTrue(any(call[:3] == ["gh", "release", "edit"] for call in calls))

    def test_tag_mismatch_stops_before_release_write(self):
        calls = self.exercise_publication(tagged=True, remote_sha="different-sha")
        self.assertFalse(any(call[:2] == ["gh", "release"] for call in calls))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseTests))
    raise SystemExit(0 if result.wasSuccessful() else 1)
