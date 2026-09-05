# Release workflow

`Release main` runs on every push to `main`, or by manual workflow dispatch on
`main`. The first release is `v1.0.0` at the final merged main revision. After that,
every unreleased first-parent main commit receives its own version and release.
Squash merges therefore normally produce one release per push. A multi-commit
push produces one release per main commit, so no intermediate work is lost when
GitHub replaces a pending workflow run.

Version decisions use all commit messages introduced by that main commit:

- `type!:` / `type(scope)!:` or a `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer:
  increment major and reset minor/patch.
- `feat:` / `feat(scope):`: increment minor and reset patch.
- All other changes: increment patch.

Release jobs share a concurrency group and never cancel the running release.
The controller refreshes main and drains the remaining queue before exiting.
There are no generated version commits and the workflow only listens to main
branch pushes, so creating tags/releases cannot cause a release loop.

Every version is built and verified in a temporary detached worktree at the
exact SHA. An explicit immutable tag is reserved only after verification and
packaging succeed. A draft release receives the arm64 ZIP and SHA-256 file; it
becomes public only after the tag SHA, uploaded asset sizes, downloaded checksum,
local archive SHA-256, and available GitHub asset digests are checked. A newly
uploaded archive without a GitHub digest is downloaded and hashed once.
Interrupted tags and drafts are retried first, using the same version and SHA.
Published releases are not overwritten. A malformed/incomplete published
release fails explicitly and must be repaired before later versions proceed.
Previously published versions are checked using tag and asset metadata only;
routine pushes do not re-download historical archives.

To retry a failed publication, rerun `Release main` or manually dispatch it on
main. Do not move a release tag. Normal pushes arriving during a failure remain
in the queue and will be handled on the next successful run.

## Local commands

```sh
python3 scripts/test_release.py
python3 scripts/verify.py
scripts/package-app.sh --archive --version 1.0.0
python3 scripts/publish_release.py --repo TaoSama/agent-pulse --dry-run
```

The dry run fetches git refs and reads GitHub release metadata; it does not
create tags/releases or build. Local packaging defaults to an exact stable
HEAD tag, otherwise `1.0.0`; use `--version` to select a prospective version.
The source plist is a development default. Packaging injects the selected
version into both bundle version fields and records `AgentPulseCommitSHA`.

Artifacts are `dist/AgentPulse.app`, `AgentPulse-VERSION-macOS-arm64.zip`, and
the matching `.zip.sha256` file. The app is ad-hoc signed, not notarized. All
verification uses fixture databases; the live reconcile command is excluded.
