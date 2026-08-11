#!/usr/bin/env python3

import io
import pathlib
import subprocess
import sys
import tarfile
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[1]
GATE = REPO / "Scripts/reject-release-binaries.py"
MACHO = b"\xcf\xfa\xed\xfe" + b"test"


def run(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GATE), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="pcvr-binary-gate.") as directory:
        root = pathlib.Path(directory)
        subprocess.run(["/usr/bin/git", "init", "-q", str(root)], check=True)
        (root / "README.md").write_text("source\n", encoding="utf-8")
        subprocess.run(
            ["/usr/bin/git", "-C", str(root), "add", "README.md"],
            check=True,
        )
        if run("--repo-root", str(root)).returncode != 0:
            raise SystemExit("text-only tracked source was rejected")

        binary = root / "Build/forced-controller"
        binary.parent.mkdir()
        binary.write_bytes(MACHO)
        subprocess.run(
            ["/usr/bin/git", "-C", str(root), "add", "-f", "Build/forced-controller"],
            check=True,
        )
        if run("--repo-root", str(root)).returncode == 0:
            raise SystemExit("force-added Build Mach-O bypassed the repository gate")

        package = root / "Artifacts/forced.pkg"
        package.parent.mkdir()
        package.write_bytes(b"not-even-a-package")
        subprocess.run(
            ["/usr/bin/git", "-C", str(root), "add", "-f", "Artifacts/forced.pkg"],
            check=True,
        )
        if run("--repo-root", str(root)).returncode == 0:
            raise SystemExit("force-added package bypassed the repository gate")

        archive_path = root / "source.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            info = tarfile.TarInfo("Project/Artifacts/forced-controller")
            info.size = len(MACHO)
            archive.addfile(info, io.BytesIO(MACHO))
        if run("--tar", str(archive_path)).returncode == 0:
            raise SystemExit("archived Mach-O bypassed the source-release gate")

        package_archive = root / "package-source.tar.gz"
        with tarfile.open(package_archive, "w:gz") as archive:
            payload = b"not-even-a-package"
            info = tarfile.TarInfo("Project/Artifacts/forced.pkg")
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        if run("--tar", str(package_archive)).returncode == 0:
            raise SystemExit("archived package bypassed the source-release gate")

    print("Release binary exclusion tests passed.")


if __name__ == "__main__":
    main()
