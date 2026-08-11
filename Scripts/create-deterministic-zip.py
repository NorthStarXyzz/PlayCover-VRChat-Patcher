#!/usr/bin/python3
"""Create a no-clobber, metadata-normalized ZIP from one directory tree."""

import argparse
import datetime
import os
import pathlib
import stat
import tempfile
import zipfile
from typing import List, Tuple


class ArchiveError(RuntimeError):
    pass


def zip_timestamp(epoch: int) -> Tuple[int, int, int, int, int, int]:
    value = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    if value.year < 1980 or value.year > 2107:
        raise ArchiveError("ZIP timestamp must be between 1980 and 2107")
    return (value.year, value.month, value.day, value.hour, value.minute, value.second)


def collect(root: pathlib.Path) -> List[Tuple[pathlib.Path, str, int, bool]]:
    root_mode = root.lstat().st_mode
    if not stat.S_ISDIR(root_mode) or root.is_symlink():
        raise ArchiveError("input must be a non-symlink directory")
    if "/" in root.name or root.name in ("", ".", ".."):
        raise ArchiveError("unsafe archive root name")

    entries: List[Tuple[pathlib.Path, str, int, bool]] = [
        (root, root.name + "/", root_mode, True)
    ]
    for directory, directory_names, file_names in os.walk(str(root), followlinks=False):
        directory_names.sort()
        file_names.sort()
        base = pathlib.Path(directory)
        for name in directory_names:
            path = base / name
            mode = path.lstat().st_mode
            if path.is_symlink() or not stat.S_ISDIR(mode):
                raise ArchiveError("symlink or special directory entry: {}".format(path))
            relative = path.relative_to(root).as_posix()
            entries.append((path, root.name + "/" + relative + "/", mode, True))
        for name in file_names:
            path = base / name
            mode = path.lstat().st_mode
            if path.is_symlink() or not stat.S_ISREG(mode):
                raise ArchiveError("symlink or special file entry: {}".format(path))
            relative = path.relative_to(root).as_posix()
            entries.append((path, root.name + "/" + relative, mode, False))
    return sorted(entries, key=lambda item: item[1].encode("utf-8"))


def regular_file_bytes(path: pathlib.Path, expected_mode: int) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(str(path), flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_mode != expected_mode:
            raise ArchiveError("file changed while archiving: {}".format(path))
        chunks = []
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ArchiveError("file changed while archiving: {}".format(path))
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def create_archive(root: pathlib.Path, output: pathlib.Path, epoch: int) -> None:
    if not output.is_absolute():
        raise ArchiveError("output path must be absolute")
    if not output.parent.is_dir() or output.parent.is_symlink():
        raise ArchiveError("output parent must be an existing non-symlink directory")
    if output.exists() or output.is_symlink():
        raise ArchiveError("refusing to replace existing output")
    entries = collect(root)
    timestamp = zip_timestamp(epoch)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".pcvr-zip-", dir=str(output.parent))
    os.close(descriptor)
    temporary = pathlib.Path(temporary_name)
    try:
        with zipfile.ZipFile(
            str(temporary), mode="w", compression=zipfile.ZIP_STORED, allowZip64=True
        ) as archive:
            for path, archive_name, mode, is_directory in entries:
                info = zipfile.ZipInfo(archive_name, timestamp)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = (mode & 0xFFFF) << 16
                if is_directory:
                    info.external_attr |= 0x10
                    payload = b""
                else:
                    payload = regular_file_bytes(path, mode)
                archive.writestr(info, payload)
        with zipfile.ZipFile(str(temporary), mode="r") as archive:
            corrupt = archive.testzip()
            if corrupt is not None:
                raise ArchiveError("ZIP integrity failure at {}".format(corrupt))
            if archive.namelist() != [entry[1] for entry in entries]:
                raise ArchiveError("ZIP entry order mismatch")
        os.chmod(str(temporary), 0o644)
        os.link(str(temporary), str(output))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--source-date-epoch", required=True, type=int)
    arguments = parser.parse_args()
    try:
        root = arguments.input.absolute()
        output = arguments.output.absolute()
        create_archive(root, output, arguments.source_date_epoch)
    except (ArchiveError, OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, "error: {}\n".format(error))
    print("Created deterministic ZIP: {}".format(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
