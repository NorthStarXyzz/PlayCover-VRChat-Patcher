#!/usr/bin/python3
"""Exhaustive closed-table and transition-order tests for the r6 package."""

from __future__ import annotations

import itertools
import json
import os
import pathlib
import shlex
import socket
import subprocess
import sys
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
COMMON = REPO / "Controller/package/scripts/common.zsh"
PREINSTALL = REPO / "Controller/package/scripts/preinstall"
POSTINSTALL = REPO / "Controller/package/scripts/postinstall"
RUNNER = REPO / "Controller/root-runner"
CONTROLLER = REPO / "Controller/vrchat-memory-policy-controller.c"
MANIFEST = json.loads(
    (REPO / "Controller/package/ControllerPackageManifest.json").read_text()
)

CURRENT_C = MANIFEST["controllerPackage"]["controller"]["sha256"]
CURRENT_R = MANIFEST["controllerPackage"]["runner"]["sha256"]
PREDECESSORS = {
    item["name"]: (item["controllerSHA256"], item["runnerSHA256"])
    for item in MANIFEST["reviewedPredecessors"]
}
R5_C, R5_R = PREDECESSORS["r5"]
R3_C, R3_R = PREDECESSORS["observed-r3"]


def expected_install_action(state: tuple[str, ...]) -> str:
    c, r, a, receipt, qc, qr = state
    final = (c, r, a, receipt)
    ordered = {
        ("none", "none", "none", "absent"),
        ("none", "current", "none", "absent"),
        ("current", "current", "none", "absent"),
        ("current", "current", "current", "absent"),
    }
    if qr != "none" and qc == "none":
        return "reject"
    if qc != "none" and qr != "none":
        if qc != qr or qc not in {"r5", "r3"}:
            return "reject"
        return "resume" if final in ordered else "reject"
    if qc != "none":
        if qc in {"r5", "r3"} and final == (
            "none", qc, "none", "absent"
        ):
            return f"complete-quarantine-{qc}"
        if qc in {"r5", "r3"} and final == (
            "current", "current", "current", "absent"
        ):
            return "resume"
        return "reject"
    if final == ("r5", "r5", "none", "absent"):
        return "quarantine-r5"
    if final == ("r3", "r3", "none", "absent"):
        return "quarantine-r3"
    if final in ordered or final == (
        "current", "current", "current", "current"
    ):
        return "resume"
    return "reject"


def shell_arguments(state: tuple[str, ...]) -> list[str]:
    c, r, a, receipt, qc, qr = state
    c_hashes = {"none": "", "current": CURRENT_C, "r5": R5_C, "r3": R3_C}
    r_hashes = {"none": "", "current": CURRENT_R, "r5": R5_R, "r3": R3_R}
    q_c_hashes = {"none": "", "r5": R5_C, "r3": R3_C}
    q_r_hashes = {"none": "", "r5": R5_R, "r3": R3_R}
    return [
        "0" if c == "none" else "1",
        "0" if r == "none" else "1",
        "0" if a == "none" else "1",
        receipt,
        c_hashes[c],
        r_hashes[r],
        "0" if qc == "none" else "1",
        "0" if qr == "none" else "1",
        q_c_hashes[qc],
        q_r_hashes[qr],
    ]


def test_real_shell_classifier() -> None:
    states = list(
        itertools.product(
            ("none", "current", "r5", "r3"),
            ("none", "current", "r5", "r3"),
            ("none", "current"),
            ("absent", "current"),
            ("none", "r5", "r3"),
            ("none", "r5", "r3"),
        )
    )
    commands = [f"source {shlex.quote(str(COMMON))}"]
    for state in states:
        arguments = " ".join(shlex.quote(value) for value in shell_arguments(state))
        commands.append(f"classify_journaled_install_state {arguments}")
    result = subprocess.run(
        ["/bin/zsh", "-f"],
        input="\n".join(commands) + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    actual = result.stdout.splitlines()
    expected = [expected_install_action(state) for state in states]
    if actual != expected:
        for state, wanted, found in zip(states, expected, actual):
            if wanted != found:
                raise AssertionError(
                    f"classifier mismatch for {state}: expected {wanted}, found {found}"
                )
        raise AssertionError("classifier returned an unexpected number of lines")
    assert sum(item != "reject" for item in actual) == 19

    new_journal_script = [f"source {shlex.quote(str(COMMON))}"]
    new_journal_expected = []
    for controller_quarantine, runner_quarantine in itertools.product((0, 1), repeat=2):
        new_journal_script.append(
            "classify_new_journal_quarantine_state "
            f"{controller_quarantine} {runner_quarantine}"
        )
        new_journal_expected.append(
            "fresh" if (controller_quarantine, runner_quarantine) == (0, 0)
            else "reject"
        )
    new_journal_result = subprocess.run(
        ["/bin/zsh", "-f"],
        input="\n".join(new_journal_script) + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    assert new_journal_result.stdout.splitlines() == new_journal_expected


def uninstall_recovery_accepts(
    *, runner: bool, package_dir: bool, controller: bool,
    attestation: bool, receipt: bool, journal: bool,
) -> bool:
    if not runner:
        return not any((package_dir, controller, attestation, receipt, journal))
    if not journal:
        return (package_dir and controller and attestation and receipt) or (
            not package_dir and not controller and not attestation and not receipt
        )
    if not package_dir:
        return not any((controller, attestation, receipt))
    return (controller, attestation, receipt) in {
        (True, True, True),
        (False, True, True),
        (False, True, False),
        (False, False, False),
    }


def test_uninstall_crash_prefixes_and_closed_table() -> None:
    # Prefixes of J -> C -> receipt -> A -> D -> J -> R removal.
    prefixes = [
        (True, True, True, True, True, False),
        (True, True, True, True, True, True),
        (True, True, False, True, True, True),
        (True, True, False, True, False, True),
        (True, True, False, False, False, True),
        (True, False, False, False, False, True),
        (True, False, False, False, False, False),
        (False, False, False, False, False, False),
    ]
    for runner, directory, controller, attestation, receipt, journal in prefixes:
        assert uninstall_recovery_accepts(
            runner=runner,
            package_dir=directory,
            controller=controller,
            attestation=attestation,
            receipt=receipt,
            journal=journal,
        )
    accepted = set(prefixes)
    for state in itertools.product((False, True), repeat=6):
        observed = uninstall_recovery_accepts(
            runner=state[0],
            package_dir=state[1],
            controller=state[2],
            attestation=state[3],
            receipt=state[4],
            journal=state[5],
        )
        assert observed == (state in accepted), f"unexpected uninstall subset: {state}"


def test_transition_source_order_and_gates() -> None:
    common = COMMON.read_text()
    preinstall = PREINSTALL.read_text()
    postinstall = POSTINSTALL.read_text()
    runner = RUNNER.read_text()
    controller = CONTROLLER.read_text()

    assert common.index('/bin/mv "$controller" "$controller_quarantine"') < common.index(
        '/bin/mv "$runner" "$runner_quarantine"'
    )
    assert postinstall.index('/bin/unlink "$runner_quarantine"') < postinstall.index(
        '/bin/unlink "$controller_quarantine"'
    ) < postinstall.index('/bin/unlink "$install_journal"')
    for executable in (
        '"$controller" "$controller_quarantine"',
        '"$runner" "$runner_quarantine"',
    ):
        assert executable in common
    assert preinstall.count("classify_journaled_install_state") == 1
    quarantine_gate = preinstall.index("classify_new_journal_quarantine_state")
    normal_case = preinstall.index('case "$controller_present:$runner_present')
    assert quarantine_gate < normal_case

    finish_start = runner.index("finish_uninstall()")
    finish_end = runner.index("\nuninstall_package()", finish_start)
    finish = runner[finish_start:finish_end]
    assert finish.index('/bin/rmdir "$package_dir"') < finish.index(
        '/bin/unlink "$uninstall_journal"'
    ) < finish.index('/bin/unlink "$runner"')
    create = runner.index("create_uninstall_journal", runner.index("uninstall_package()"))
    first_mutation = runner.index('/bin/unlink "$controller"', create)
    uninstall_start = runner.index("uninstall_package()")
    acquire = runner.index("acquire_operation_claim uninstall", uninstall_start)
    assert acquire < runner.index("repair_orphaned_journal_temp", acquire)
    assert acquire < runner.index("installed_receipt=$(receipt_state)", acquire)
    assert acquire < create < first_mutation
    assert "verify_owned_uninstall_transition" in runner[create:first_mutation]
    assert finish.index("verify_owned_uninstall_transition") < finish.index(
        '/bin/rmdir "$package_dir"'
    )
    assert finish.index("verify_owned_operation_claim", finish.index(
        '/bin/unlink "$uninstall_journal"'
    )) < finish.index('/bin/unlink "$runner"')
    release_start = runner.index("release_owned_operation_claim()")
    release_end = runner.index("\nacquire_operation_claim()", release_start)
    release = runner[release_start:release_end]
    assert release.index('/bin/unlink "$operation_claim"') < release.index(
        "exec {claim_fd}<&-"
    )
    acquire_body = runner[
        runner.index("acquire_operation_claim()"):
        runner.index("\nruntime_holder_state()")
    ]
    assert acquire_body.index('exec {claim_fd}< "$operation_claim_temp"') < \
        acquire_body.index('exec {fixed_claim_fd}< "$operation_claim"') < \
        acquire_body.index('/bin/unlink "$operation_claim_temp"')

    assert preinstall.index("acquire_operation_claim_for_install") < preinstall.index(
        "ensure_install_journal"
    )
    assert preinstall.index("ensure_install_journal") < preinstall.index(
        "installed_receipt=$(receipt_state)"
    )
    assert postinstall.index('require_absent "$operation_claim"') < postinstall.index(
        '/bin/unlink "$install_journal"'
    )

    gate = controller.index("pcvr_path_must_be_absent(PCVR_INSTALL_JOURNAL_PATH)")
    singleton = controller.index("acquire_singleton_lock()", gate)
    assert gate < singleton


def run_directory_gate(path: pathlib.Path, expected: str) -> subprocess.CompletedProcess[str]:
    command = (
        f"source {shlex.quote(str(COMMON))}\n"
        f"verify_directory {shlex.quote(str(path))} {shlex.quote(expected)}\n"
    )
    return subprocess.run(
        ["/bin/zsh", "-f"], input=command, text=True, capture_output=True
    )


def test_real_directory_metadata_acl_and_flag_gates() -> None:
    with tempfile.TemporaryDirectory(prefix="pcvr-package-dir-") as temporary:
        path = pathlib.Path(temporary)
        uid = path.stat().st_uid
        gid = path.stat().st_gid
        path.chmod(0o700)
        expected = f"{uid}:{gid}:700:Directory:-"
        assert run_directory_gate(path, expected).returncode == 0

        path.chmod(0o720)
        assert run_directory_gate(path, expected).returncode != 0
        path.chmod(0o700)

        owner = subprocess.run(
            ["/usr/bin/id", "-un"], text=True, capture_output=True, check=True
        ).stdout.strip()
        subprocess.run(
            ["/bin/chmod", "+a", f"{owner} allow read", str(path)], check=True
        )
        try:
            assert run_directory_gate(path, expected).returncode != 0
        finally:
            subprocess.run(["/bin/chmod", "-N", str(path)], check=True)

        subprocess.run(["/usr/bin/chflags", "uchg", str(path)], check=True)
        try:
            assert run_directory_gate(path, expected).returncode != 0
        finally:
            subprocess.run(["/usr/bin/chflags", "nouchg", str(path)], check=True)

    common = COMMON.read_text()
    private = common.index("verify_directory /private '")
    private_var = common.index("verify_directory /private/var '")
    private_db = common.index("verify_directory /private/var/db '")
    local = common.index("verify_directory /usr/local '")
    assert private < private_var < private_db < local


def run_stale_socket_gate(
    path: pathlib.Path, uid: int, gid: int
) -> subprocess.CompletedProcess[str]:
    command = (
        f"source {shlex.quote(str(COMMON))}\n"
        f"verify_inactive_stale_socket {shlex.quote(str(path))} {uid} {gid}\n"
    )
    return subprocess.run(
        ["/bin/zsh", "-f"], input=command, text=True, capture_output=True
    )


def test_real_console_owned_stale_socket_gate() -> None:
    with tempfile.TemporaryDirectory(prefix="pcvr-package-socket-") as temporary:
        path = pathlib.Path(temporary) / "session.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.close()
        path.chmod(0o600)
        metadata = path.lstat()
        assert run_stale_socket_gate(path, metadata.st_uid, metadata.st_gid).returncode == 0
        assert run_stale_socket_gate(path, metadata.st_uid + 1, metadata.st_gid).returncode != 0
        path.chmod(0o666)
        assert run_stale_socket_gate(path, metadata.st_uid, metadata.st_gid).returncode != 0


CLAIM_WORKER = r"""
import os, pathlib, sys, time
claim = pathlib.Path(sys.argv[1])
ready = pathlib.Path(sys.argv[2])
release = pathlib.Path(sys.argv[3])
payload = bytes.fromhex(sys.argv[4])
temp = claim.parent / ('.operation.new.' + str(os.getpid()))
fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
os.write(fd, payload)
os.fchmod(fd, 0o400)
os.link(temp, claim)
identity = os.fstat(fd).st_dev, os.fstat(fd).st_ino
fixed_fd = os.open(claim, os.O_RDONLY)
if (os.fstat(fixed_fd).st_dev, os.fstat(fixed_fd).st_ino) != identity:
    raise SystemExit(79)
os.unlink(temp)
ready.write_text('ready')
while not release.exists():
    time.sleep(0.01)
current = claim.stat().st_dev, claim.stat().st_ino
if current != identity:
    raise SystemExit(79)
os.unlink(claim)
os.close(fixed_fd)
os.close(fd)
"""


def claim_holders(path: pathlib.Path) -> list[int]:
    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", str(path)],
        text=True,
        capture_output=True,
    )
    if result.returncode == 1 and not result.stdout:
        return []
    assert result.returncode == 0, result.stderr
    return [int(value) for value in result.stdout.splitlines()]


def wait_for(path: pathlib.Path) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def test_real_operation_claim_exclusion_and_recovery() -> None:
    claim_bytes = (
        "PCVR-OPERATION-CLAIM/1\n"
        "packageIdentifier=io.github.northstarxyzz.pcvrpatcher.memory-policy\n"
        "controllerBuildID=25G70-vrchat-2026.2.30300-1365-r6\n"
    ).encode()
    with tempfile.TemporaryDirectory(prefix="pcvr-operation-claim-") as temporary:
        root = pathlib.Path(temporary)
        claim = root / "operation"
        ready = root / "ready"
        release = root / "release"
        old_runner = root / "runner"
        old_runner.write_text("old-r6")
        owner = subprocess.Popen(
            [
                sys.executable,
                "-c",
                CLAIM_WORKER,
                str(claim),
                str(ready),
                str(release),
                claim_bytes.hex(),
            ]
        )
        wait_for(ready)

        # lsof by the fixed linked pathname sees an FD opened on the temporary
        # inode before publication. A second uninstall must return busy before
        # caching or deleting any state.
        assert claim_holders(claim) == [owner.pid]
        cached_by_loser = False
        if claim_holders(claim):
            loser_status = 75
        else:  # pragma: no cover - would recreate the audited race
            cached_by_loser = old_runner.exists()
            loser_status = 0
        assert loser_status == 75
        assert not cached_by_loser
        assert old_runner.read_text() == "old-r6"

        # The winning uninstall finishes, then a new install publishes another
        # runner. The rejected slow invocation has no cached authority with
        # which it could remove this new inode.
        old_runner.unlink()
        release.write_text("go")
        assert owner.wait(timeout=5) == 0
        assert not claim.exists()
        old_runner.write_text("new-r6")
        assert old_runner.read_text() == "new-r6"

        # A SIGKILL-equivalent owner loss leaves an exact stale claim. With no
        # live holder it is recoverable by inode-bound unlink and a new owner.
        ready.unlink()
        release.unlink()
        owner = subprocess.Popen(
            [
                sys.executable,
                "-c",
                CLAIM_WORKER,
                str(claim),
                str(ready),
                str(release),
                claim_bytes.hex(),
            ]
        )
        wait_for(ready)
        owner.kill()
        owner.wait(timeout=5)
        assert claim.exists()
        assert claim.read_bytes() == claim_bytes
        assert claim_holders(claim) == []
        stale_identity = (claim.stat().st_dev, claim.stat().st_ino)
        assert stale_identity == (claim.stat().st_dev, claim.stat().st_ino)
        claim.unlink()
        assert not claim.exists()


def main() -> None:
    test_real_shell_classifier()
    test_uninstall_crash_prefixes_and_closed_table()
    test_transition_source_order_and_gates()
    test_real_directory_metadata_acl_and_flag_gates()
    test_real_console_owned_stale_socket_gate()
    test_real_operation_claim_exclusion_and_recovery()
    print("Controller package state-machine tests passed.")


if __name__ == "__main__":
    main()
