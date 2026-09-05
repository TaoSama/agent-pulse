"""Verify release archives against downloaded checksums and GitHub asset digests."""

import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

MAXIMUM_CHECKSUM_BYTES = 4096
HASH_CHUNK_BYTES = 1024 * 1024


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(HASH_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_checksum(repository, asset):
    return subprocess.run(["gh", "api", f"repos/{repository}/releases/assets/{asset['id']}",
                           "-H", "Accept: application/octet-stream"],
                          check=True, stdout=subprocess.PIPE).stdout


def download_archive(repository, tag, name, path):
    subprocess.run(["gh", "release", "download", tag, "--repo", repository,
                    "--pattern", name, "--output", str(path)], check=True)


def check_github_digest(asset, expected):
    digest = asset.get("digest")
    if digest and digest.lower() != f"sha256:{expected}":
        raise ValueError(f"GitHub digest mismatch for {asset['name']}")


def validate_asset_metadata(tag, release):
    archive_name = f"AgentPulse-{tag[1:]}-macOS-arm64.zip"
    checksum_name = f"{archive_name}.sha256"
    assets = {asset["name"]: asset for asset in release["assets"]}
    for name in (archive_name, checksum_name):
        if name not in assets or assets[name]["size"] <= 0:
            raise ValueError(f"Missing or empty release asset: {name}")
        if assets[name].get("state", "uploaded") != "uploaded":
            raise ValueError(f"Release asset is not fully uploaded: {name}")
        digest = assets[name].get("digest")
        if digest and not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
            raise ValueError(f"Malformed GitHub digest: {name}")
    if assets[checksum_name]["size"] > MAXIMUM_CHECKSUM_BYTES:
        raise ValueError(f"Oversized checksum asset: {checksum_name}")
    return assets, archive_name, checksum_name


def verify_release_assets(repository, tag, release, local_directory=None):
    assets, archive_name, checksum_name = validate_asset_metadata(tag, release)
    if local_directory:
        for name in (archive_name, checksum_name):
            if assets[name]["size"] != (local_directory / name).stat().st_size:
                raise ValueError(f"Uploaded asset size mismatch: {name}")
    checksum = download_checksum(repository, assets[checksum_name])
    if len(checksum) != assets[checksum_name]["size"]:
        raise ValueError(f"Downloaded checksum size mismatch: {checksum_name}")
    expression = rb"([0-9a-f]{64})  " + re.escape(archive_name.encode()) + rb"\n"
    match = re.fullmatch(expression, checksum)
    if not match:
        raise ValueError(f"Malformed checksum file: {checksum_name}")
    expected_archive_digest = match[1].decode("ascii")
    check_github_digest(assets[checksum_name], hashlib.sha256(checksum).hexdigest())
    check_github_digest(assets[archive_name], expected_archive_digest)
    if local_directory:
        if checksum != (local_directory / checksum_name).read_bytes():
            raise ValueError(f"Uploaded checksum differs from the build: {checksum_name}")
        if file_digest(local_directory / archive_name) != expected_archive_digest:
            raise ValueError(f"Uploaded checksum does not match the built archive: {archive_name}")
    if not assets[archive_name].get("digest"):
        # Older GitHub assets may lack a server SHA-256. Verify their bytes instead
        # of declaring a size-only comparison to be a successful integrity check.
        with tempfile.TemporaryDirectory(prefix="agent-pulse-asset-check-") as temporary:
            downloaded = Path(temporary) / archive_name
            download_archive(repository, tag, archive_name, downloaded)
            if downloaded.stat().st_size != assets[archive_name]["size"]:
                raise ValueError(f"Downloaded archive size mismatch: {archive_name}")
            if file_digest(downloaded) != expected_archive_digest:
                raise ValueError(f"Downloaded archive checksum mismatch: {archive_name}")
