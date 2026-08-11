#!/usr/bin/python3
"""Canonicalize the metadata-only outer XAR layer of a flat component pkg."""

from __future__ import annotations

import hashlib
import os
import pathlib
import struct
import sys
import xml.etree.ElementTree as ET
import zlib


HEADER = struct.Struct(">IHHQQI")
XAR_MAGIC = 0x78617221
XAR_HEADER_SIZE = 28
XAR_VERSION = 1
XAR_SHA256 = 3
FIXED_TIME = "2020-01-01T00:00:00"
FIXED_FILE_TIME = FIXED_TIME + "Z"
EXPECTED_MEMBERS = ("Bom", "Payload", "Scripts", "PackageInfo")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def set_child_text(parent: ET.Element, name: str, value: str) -> None:
    child = parent.find(name)
    if child is None:
        child = ET.SubElement(parent, name)
    child.text = value


def canonical_toc(raw: bytes) -> bytes:
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        fail(f"invalid XAR TOC XML: {error}")
    if root.tag != "xar":
        fail("unexpected XAR TOC root")
    toc = root.find("toc")
    if toc is None:
        fail("XAR TOC is missing toc")
    if toc.find("signature") is not None:
        fail("refusing to normalize a signed package")
    creation_time = toc.find("creation-time")
    if creation_time is None:
        fail("XAR TOC is missing creation-time")
    creation_time.text = FIXED_TIME

    files = toc.findall("file")
    names = tuple((node.findtext("name") or "") for node in files)
    if names != EXPECTED_MEMBERS:
        fail(f"unexpected flat-package members: {names!r}")
    for index, node in enumerate(files, start=1):
        if node.findtext("type") != "file":
            fail("flat-package member is not a regular file")
        node.set("id", str(index))
        set_child_text(node, "inode", str(index))
        set_child_text(node, "deviceno", "0")
        set_child_text(node, "mode", "0644")
        set_child_text(node, "uid", "0")
        set_child_text(node, "user", "root")
        set_child_text(node, "gid", "0")
        set_child_text(node, "group", "wheel")
        set_child_text(node, "atime", FIXED_FILE_TIME)
        set_child_text(node, "mtime", FIXED_FILE_TIME)
        set_child_text(node, "ctime", FIXED_FILE_TIME)
        for child_name in ("FinderCreateTime", "ea"):
            for child in list(node.findall(child_name)):
                node.remove(child)

    checksum = toc.find("checksum")
    if checksum is None or checksum.get("style") != "sha256":
        fail("outer XAR must use a SHA-256 TOC checksum")
    if checksum.findtext("size") != "32" or checksum.findtext("offset") != "0":
        fail("unexpected outer XAR checksum layout")

    ET.indent(root, space=" ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def normalize(source: pathlib.Path, destination: pathlib.Path) -> None:
    if not source.is_absolute() or not destination.is_absolute():
        fail("source and destination must be absolute paths")
    if source == destination:
        fail("source and destination must differ")
    data = source.read_bytes()
    if len(data) < HEADER.size:
        fail("flat package is shorter than its XAR header")
    magic, header_size, version, compressed_size, raw_size, algorithm = HEADER.unpack_from(data)
    if (
        magic != XAR_MAGIC
        or header_size != XAR_HEADER_SIZE
        or version != XAR_VERSION
        or algorithm != XAR_SHA256
    ):
        fail("unsupported or unsigned/noncanonical XAR header")
    toc_start = header_size
    toc_end = toc_start + compressed_size
    if toc_end + hashlib.sha256().digest_size > len(data):
        fail("truncated XAR TOC or heap checksum")
    compressed_toc = data[toc_start:toc_end]
    try:
        raw_toc = zlib.decompress(compressed_toc)
    except zlib.error as error:
        fail(f"invalid compressed XAR TOC: {error}")
    if len(raw_toc) != raw_size:
        fail("XAR TOC size differs from its header")
    old_heap = data[toc_end:]
    old_checksum = old_heap[: hashlib.sha256().digest_size]
    if old_checksum != hashlib.sha256(compressed_toc).digest():
        fail("XAR TOC checksum does not match")

    new_raw_toc = canonical_toc(raw_toc)
    new_compressed_toc = zlib.compress(new_raw_toc, level=9)
    new_header = HEADER.pack(
        XAR_MAGIC,
        XAR_HEADER_SIZE,
        XAR_VERSION,
        len(new_compressed_toc),
        len(new_raw_toc),
        XAR_SHA256,
    )
    new_heap = hashlib.sha256(new_compressed_toc).digest() + old_heap[32:]
    result = new_header + new_compressed_toc + new_heap

    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(result)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: normalize-flat-package.py /absolute/input.pkg /absolute/output.pkg")
    normalize(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))


if __name__ == "__main__":
    main()
