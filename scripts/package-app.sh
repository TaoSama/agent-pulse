#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package-app.sh [-h|--help]

Build AgentPulse in release mode and assemble dist/AgentPulse.app.

Options:
  -h, --help    Show this help message and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$project_dir/dist/AgentPulse.app"
contents_dir="$app_bundle/Contents"

cd "$project_dir"
swift build -c release

rm -rf "$app_bundle"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/AgentPulse" "$contents_dir/MacOS/AgentPulse"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
codesign --force --sign - "$app_bundle"

echo "$app_bundle"
