"""Drain unreleased main commits. Run only under the main-release CI concurrency lock."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from release_version import STABLE_VERSION, next_version, version_parts
from release_assets import validate_asset_metadata, verify_release_assets

PROJECT = Path(__file__).resolve().parent.parent


def run(arguments, cwd=PROJECT):
    result = subprocess.run(arguments, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE)
    return result.stdout.strip()


def release_plan(history, tags, published, messages):
    """Return (tag, sha) work; unfinished tags remain ahead of new versions."""
    if not history:
        raise ValueError("main has no commits")
    stable = sorted(((tag, sha) for tag, sha in tags.items()
                     if tag.startswith("v") and STABLE_VERSION.fullmatch(tag[1:])),
                    key=lambda item: version_parts(item[0][1:]))
    if not stable:
        return [("v1.0.0", history[-1])]
    positions = {sha: index for index, sha in enumerate(history)}
    last_index = -1
    pending = []
    for tag, sha in stable:
        if sha not in positions or positions[sha] <= last_index:
            raise ValueError(f"Release tag {tag} is not on the ordered main history")
        last_index = positions[sha]
        if tag not in published:
            pending.append((tag, sha))
    previous = stable[-1][0][1:]
    for sha in history[last_index + 1:]:
        previous = next_version(previous, messages(sha))
        pending.append((f"v{previous}", sha))
    return pending


def asset_names(tag):
    archive = f"AgentPulse-{tag[1:]}-macOS-arm64.zip"
    return [archive, f"{archive}.sha256"]


def api(repository, endpoint):
    return json.loads(run(["gh", "api", f"repos/{repository}/{endpoint}"]))


def tag_commit(repository, tag):
    ref = api(repository, f"git/ref/tags/{tag}")["object"]
    while ref["type"] == "tag":
        ref = api(repository, f"git/tags/{ref['sha']}")["object"]
    if ref["type"] != "commit":
        raise ValueError(f"{tag} does not identify a commit")
    return ref["sha"]


def releases_by_tag(repository):
    pages = json.loads(run(["gh", "api", "--paginate", "--slurp",
                           f"repos/{repository}/releases?per_page=100"]))
    return {release["tag_name"]: release for page in pages for release in page}


def snapshot(repository):
    run(["git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main", "--tags"])
    history = run(["git", "rev-list", "--first-parent", "--reverse", "origin/main"]).splitlines()
    tags = {}
    for tag in run(["git", "tag", "--list", "v*"]).splitlines():
        if STABLE_VERSION.fullmatch(tag[1:]):
            tags[tag] = run(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"])
    releases = releases_by_tag(repository)
    published = set()
    for tag, release in releases.items():
        if tag in tags and not release["draft"] and not release["prerelease"]:
            # Publication verified these bytes already. Routine queue recovery only
            # checks completion metadata, never re-downloads the release archive history.
            validate_asset_metadata(tag, release)
            published.add(tag)
    return history, tags, releases, published


def commit_messages(sha, cwd=PROJECT):
    # Include merged commits when a push uses a merge commit instead of squash.
    records = run(["git", "log", "--format=%B%x00", f"{sha}^..{sha}"], cwd=cwd).split("\0")
    return [record.strip() for record in records if record.strip()]


def publish(repository, tag, sha, existing, tagged):
    print(f"Preparing {tag} from {sha}", flush=True)
    with tempfile.TemporaryDirectory(prefix="agent-pulse-release-") as temporary:
        root = Path(temporary)
        checkout = root / "checkout"
        run(["git", "worktree", "add", "--detach", str(checkout), sha])
        try:
            # Run the exact revision's checks and packager, never the moving main checkout.
            subprocess.run(["python3", str(checkout / "scripts/verify.py")], cwd=checkout, check=True)
            subprocess.run(["python3", str(checkout / "scripts/package_app.py"), "--archive",
                            "--version", tag[1:], "--output-dir", str(root / "assets")],
                           cwd=checkout, check=True)
            notes = root / "notes.md"
            notes.write_text(f"macOS 14+ · Apple Silicon (arm64)\n\n"
                             f"Built from `{sha}`. Bundle version: `{tag[1:]}`.\n\n"
                             "The app is ad-hoc signed; it is not notarized. "
                             "The accompanying `.sha256` file verifies the ZIP download.\n")
            # Reserve the exact SHA first. Draft releases do not necessarily create
            # their tag until publication; a failed draft must remain discoverable.
            if not tagged:
                run(["gh", "api", f"repos/{repository}/git/refs", "--method", "POST",
                     "-f", f"ref=refs/tags/{tag}", "-f", f"sha={sha}"])
            if tag_commit(repository, tag) != sha:
                raise ValueError(f"Refusing to publish {tag}: tag differs from built SHA {sha}")
            if existing is None:
                run(["gh", "release", "create", tag, "--repo", repository, "--target", sha,
                     "--verify-tag", "--draft", "--title", f"Agent Pulse {tag}", "--notes-file", str(notes)])
            elif not existing["draft"]:
                raise ValueError(f"Refusing to replace published or prerelease {tag}")
            assets = [str(root / "assets" / name) for name in asset_names(tag)]
            run(["gh", "release", "upload", tag, *assets, "--clobber", "--repo", repository])
            # The tag endpoint is for published releases; list includes our draft.
            remote = releases_by_tag(repository)[tag]
            verify_release_assets(repository, tag, remote, local_directory=root / "assets")
            run(["gh", "release", "edit", tag, "--draft=false", "--latest",
                 "--repo", repository, "--notes-file", str(notes)])
            print(f"Published {tag} ({sha})", flush=True)
        finally:
            run(["git", "worktree", "remove", "--force", str(checkout)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"), help="owner/repository")
    parser.add_argument("--dry-run", action="store_true", help="Print queue without building or publishing")
    args = parser.parse_args()
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    if not args.dry_run and (os.environ.get("GITHUB_ACTIONS") != "true"
                            or os.environ.get("GITHUB_REF") != "refs/heads/main"):
        parser.error("Publishing must run in the trusted main-release GitHub Actions job")
    try:
        while True:
            history, tags, releases, published = snapshot(args.repo)
            pending = release_plan(history, tags, published, commit_messages)
            if args.dry_run:
                print(json.dumps(pending, indent=2))
                return
            if not pending:
                return
            for tag, sha in pending:
                publish(args.repo, tag, sha, releases.get(tag), tag in tags)
            # Catch pushes received while building, including cancelled pending workflow runs.
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release failed; rerun the workflow to resume: {error}\n")


if __name__ == "__main__":
    main()
