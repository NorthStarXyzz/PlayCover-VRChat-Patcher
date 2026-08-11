#!/usr/bin/env python3
"""Reject tracked or archived Mach-O binaries from source-only releases."""

import argparse
import pathlib
import stat
import subprocess
import tarfile


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
FORBIDDEN_BINARY_SUFFIXES = (
    ".app", ".dmg", ".ipa", ".p12", ".pkg", ".provisionprofile",
    ".mobileprovision", ".xcarchive", ".zip",
)


def has_forbidden_suffix(name: str) -> bool:
    return name.lower().endswith(FORBIDDEN_BINARY_SUFFIXES)


def is_macho_prefix(prefix: bytes) -> bool:
    return prefix[:4] in MACHO_MAGICS


def check_repository(root: pathlib.Path) -> None:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(root), "ls-files", "-z"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr.decode("utf-8", "replace").strip())
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        relative = raw.decode("utf-8")
        if has_forbidden_suffix(relative):
            raise SystemExit("tracked release binary is forbidden: " + relative)
        path = root / relative
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode):
            continue
        with path.open("rb") as stream:
            if is_macho_prefix(stream.read(4)):
                raise SystemExit("tracked Mach-O is forbidden: " + relative)


def check_archive(path: pathlib.Path) -> None:
    with tarfile.open(path, "r:*") as archive:
        for member in archive.getmembers():
            if has_forbidden_suffix(member.name):
                raise SystemExit("source archive contains release binary: " + member.name)
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            if stream is None:
                raise SystemExit("could not inspect archive member: " + member.name)
            if is_macho_prefix(stream.read(4)):
                raise SystemExit("source archive contains Mach-O: " + member.name)


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--repo-root", type=pathlib.Path)
    group.add_argument("--tar", type=pathlib.Path)
    arguments = parser.parse_args()
    if arguments.repo_root is not None:
        check_repository(arguments.repo_root.resolve())
    else:
        check_archive(arguments.tar.resolve())
    print("Source-only Mach-O exclusion passed.")


if __name__ == "__main__":
    main()
