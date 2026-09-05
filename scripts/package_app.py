"""Build and ad-hoc sign an arm64 macOS app, optionally creating release assets."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

from release_version import INITIAL_VERSION, STABLE_VERSION, version_parts

PROJECT = Path(__file__).resolve().parent.parent
APP_NAME = "AgentPulse"


def command(arguments, project, capture=False):
    return subprocess.run(arguments, cwd=project, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def local_version(project):
    tags = command(["git", "tag", "--points-at", "HEAD"], project, capture=True).splitlines()
    versions = [tag[1:] for tag in tags if tag.startswith("v") and STABLE_VERSION.fullmatch(tag[1:])]
    return max(versions, key=version_parts) if versions else INITIAL_VERSION


def package(project, output, version, archive):
    version_parts(version)
    output.mkdir(parents=True, exist_ok=True)
    command(["swift", "build", "-c", "release", "--arch", "arm64", "--product", APP_NAME], project)
    binary_dir = Path(command(["swift", "build", "-c", "release", "--arch", "arm64",
                               "--show-bin-path"], project, capture=True).strip())
    commit = command(["git", "rev-parse", "HEAD"], project, capture=True).strip()
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output) as staging:
        bundle = Path(staging) / f"{APP_NAME}.app"
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        shutil.copy2(binary_dir / APP_NAME, contents / "MacOS" / APP_NAME)
        shutil.copy2(project / "Resources/AppIcon.icns", contents / "Resources/AppIcon.icns")
        with (project / "Resources/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info.update(CFBundleShortVersionString=version, CFBundleVersion=version,
                    AgentPulseCommitSHA=commit)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        command(["lipo", str(contents / "MacOS" / APP_NAME), "-verify_arch", "arm64"], project)
        command(["codesign", "--force", "--sign", "-", str(bundle)], project)
        command(["codesign", "--verify", "--deep", "--strict", str(bundle)], project)
        destination = output / bundle.name
        previous = output / f".previous-{uuid.uuid4()}"
        if destination.exists():
            destination.rename(previous)
        try:
            bundle.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise
        if previous.exists():
            shutil.rmtree(previous)
        print(destination)
        if archive:
            filename = f"{APP_NAME}-{version}-macOS-arm64.zip"
            temporary_zip = Path(staging) / filename
            command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(destination),
                     str(temporary_zip)], project)
            digest = hashlib.sha256()
            with temporary_zip.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            os.replace(temporary_zip, output / filename)
            checksum = Path(staging) / f"{filename}.sha256"
            checksum.write_text(f"{digest.hexdigest()}  {filename}\n")
            os.replace(checksum, output / checksum.name)
            print(output / filename)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=PROJECT)
    parser.add_argument("--output-dir", type=Path, help="Defaults to PROJECT/dist")
    parser.add_argument("--version", help="Stable SemVer; default is HEAD tag or 1.0.0")
    parser.add_argument("--archive", action="store_true", help="Also create ZIP and SHA-256 assets")
    args = parser.parse_args()
    project = args.project_dir.resolve()
    try:
        package(project, (args.output_dir or project / "dist").resolve(),
                args.version or local_version(project), args.archive)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
