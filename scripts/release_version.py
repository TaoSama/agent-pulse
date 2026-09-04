"""Deterministic stable SemVer decisions; no repository or network side effects."""

import argparse
import re

INITIAL_VERSION = "1.0.0"
STABLE_VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
CONVENTIONAL_SUBJECT = re.compile(r"(?P<type>[a-z][a-z0-9-]*)(?:\([^\r\n)]+\))?(?P<breaking>!)?: .+")
BREAKING_FOOTER = re.compile(r"^BREAKING(?: CHANGE|-CHANGE):\s*\S", re.MULTILINE)


def version_parts(version):
    match = STABLE_VERSION.fullmatch(version)
    if not match:
        raise ValueError(f"Not a stable SemVer version: {version!r}")
    return tuple(int(part) for part in match.groups())


def next_version(previous, messages):
    if previous is None:
        return INITIAL_VERSION
    major, minor, patch = version_parts(previous)
    bump = "patch"
    for message in messages:
        message = message.strip()
        subject = message.splitlines()[0] if message else ""
        conventional = CONVENTIONAL_SUBJECT.fullmatch(subject)
        if (conventional and conventional["breaking"]) or BREAKING_FOOTER.search(message):
            bump = "major"
            break
        if conventional and conventional["type"] == "feat":
            bump = "minor"
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", help="Previous stable version, without v; omit for 1.0.0")
    parser.add_argument("--message", action="append", default=[], help="Commit message; repeatable")
    args = parser.parse_args()
    try:
        print(next_version(args.previous, args.message))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
