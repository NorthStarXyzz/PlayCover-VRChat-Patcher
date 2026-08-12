#!/bin/zsh -p

set -eu
setopt NO_RCS PIPE_FAIL
umask 077

package_id=io.github.northstarxyzz.pcvrpatcher.memory-policy
package_version=0.1.0
package_dir=/usr/local/libexec/playcover-vrchat-memory-policy
controller="$package_dir/controller"
attestation="$package_dir/installation.json"
runner=/usr/local/bin/playcover-vrchat-memory-policy
runner_quarantine=/usr/local/bin/.playcover-vrchat-memory-policy.pcvr-install
controller_quarantine="$package_dir/.controller.pcvr-install"
runtime_dir=/private/var/run/io.github.northstarxyzz.pcvrpatcher
lock_file="$runtime_dir/controller.lock"
session_socket="$runtime_dir/session.sock"
uninstall_journal=/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.uninstall
install_journal=/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.install
operation_claim=/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.operation

current_controller_sha=24ac15360261a96542de5348e789155a90f53c7132674a74ed24b54048005d73
current_runner_sha=49f7cc361b072891182144e0f8141412b192c2647c0740c7febc5483b01337dd
current_attestation_sha=45b471725262b670ede72a398bc8b6c34b9ea21eac1859ad9e7c849248b66d9b
install_journal_sha=2c4dcac138decf2d452fa661cf2542dc145451e01905cd7c05821fd0aec9dcd1
install_journal_contents=$'PCVR-INSTALL/1\npackageIdentifier=io.github.northstarxyzz.pcvrpatcher.memory-policy\npackageVersion=0.1.0\ncontrollerBuildID=capability-vrchat-2026.2.30300-1365-r7\n'
operation_claim_sha=7fbc5571dfedc9073d71607562a97c1ea0c0435e6783f1818dcdcc40e8f23eed
operation_claim_contents=$'PCVR-OPERATION-CLAIM/1\npackageIdentifier=io.github.northstarxyzz.pcvrpatcher.memory-policy\ncontrollerBuildID=capability-vrchat-2026.2.30300-1365-r7\n'
operation_claim_temp=''
operation_claim_fd=''
fixed_operation_claim_fd=''
owned_operation_claim_identity=''
r5_controller_sha=7db6d5e7cb4ae7217878290ca754183249a3069b6d4bb4e8077a3f911b578d52
r5_runner_sha=06baf9056317307db302f65b4d12c453fab752dbe8bd81c00113d26ceb912f40
r3_controller_sha=1f1aa8afdf447b31d97336bc264928ce6ce2c2324d3603e7e41f72d93281e49d
r3_runner_sha=73f2587e1793ad89697f879d1711481df677f069284cf55751649b8d674321ca
# The immediately preceding local r6 package used the reviewed controller and
# attestation but the pre-retry runner. Keep this exact pair as a one-time,
# narrow upgrade path; no other r6 or mixed pair is accepted.
r6_previous_controller_sha=b8c28482f675761b8c6ae3422c87b01f58c1356ae56b5556dec2d1eec825e67f
r6_previous_runner_sha=5a712cf92c7c54cf70f554b0804bab28923edf911db82edd1b65b7e010998a87
# An earlier local r6 package used the same reviewed controller and
# attestation, but its runner rejected macOS's com.apple.provenance xattr on
# operation-claim temporaries. It is a reviewed, one-time upgrade predecessor.
r6_pre_provenance_controller_sha=b8c28482f675761b8c6ae3422c87b01f58c1356ae56b5556dec2d1eec825e67f
r6_pre_provenance_runner_sha=039047ea409a4cd5b27f142b657f239ec99bbed6e2ee1a866bf031a81973f558
# The r6 package actually installed on this machine used this exact reviewed
# controller/runner/attestation trio. Keep it as a narrow one-time upgrade
# predecessor so an interrupted repair can resume instead of being classified
# as an unknown mixed installation.
r6_installed_controller_sha=824c993abf60879472aa448ac89b59816ea232ef81d17850887aaa151aa7254c
r6_installed_runner_sha=26d2e2776f17707d7ca15469bf00890b547210b8416a9b9ef39144032764e9af
r6_installed_attestation_sha=4623932fdd80005cc436c9a02f55cd6d2e7186294ce7afc645338460c7dc7bc5

fail() {
    print -u2 -- "$1"
    exit "${2:-79}"
}

validate_installer_context() {
    # macOS Installer passes: package path, install destination, volume mount,
    # and the root of the current System directory.
    (( $# == 4 )) || fail "Installer supplied an unexpected argument count."
    [[ "$1" == /* && "$2" == / && "$3" == / && "$4" == / ]] || \
        fail "This package may target only install-location / on volume /."
}

verify_no_acl() {
    local target=$1
    local listing
    local acl_count

    listing=$(/bin/ls -lde "$target" 2>/dev/null) || \
        fail "Could not inspect ACLs: $target"
    acl_count=$(print -r -- "$listing" | /usr/bin/awk \
        'NR > 1 && $1 ~ /^[0-9]+:$/ { count++ } END { print count + 0 }')
    [[ "$acl_count" == 0 ]] || fail "Refusing extended ACL: $target"
}

verify_directory() {
    local target=$1
    local expected=$2
    local metadata

    metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf' "$target" 2>/dev/null || true)
    [[ "$metadata" == "$expected" ]] || \
        fail "Unsafe directory metadata: $target ($metadata)"
    verify_no_acl "$target"
}

verify_file_metadata() {
    local target=$1
    local expected_mode=$2
    local metadata

    metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' "$target" 2>/dev/null || true)
    [[ "$metadata" == "0:0:${expected_mode}:Regular File:-:1" ]] || \
        fail "Unsafe file metadata: $target ($metadata)"
    verify_no_acl "$target"
}

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_file() {
    local target=$1
    local expected_mode=$2
    local expected_sha=$3

    verify_file_metadata "$target" "$expected_mode"
    [[ $(sha256 "$target") == "$expected_sha" ]] || \
        fail "SHA-256 mismatch: $target"
}

require_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "Expected absent object: $1"
}

receipt_state() {
    local receipts
    local receipt_plist
    local installed_version

    receipts=$(/usr/sbin/pkgutil --pkgs 2>/dev/null) || \
        fail "Could not inspect Installer receipts." 74
    if ! print -r -- "$receipts" | /usr/bin/grep -F -x -q "$package_id"; then
        print -- absent
        return
    fi
    receipt_plist=$(/usr/sbin/pkgutil --pkg-info-plist "$package_id" 2>/dev/null) || \
        fail "Could not read the existing package receipt."
    installed_version=$(print -rn -- "$receipt_plist" | \
        /usr/bin/plutil -extract pkg-version raw -o - - 2>/dev/null) || \
        fail "Could not parse the existing package receipt."
    [[ "$installed_version" == "$package_version" ]] || \
        fail "Refusing unknown package receipt version: $installed_version"
    print -- current
}

verify_package_entries() {
    local entry
    local name

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name=${entry:t}
        case "$name" in
            controller|installation.json|.controller.pcvr-install)
                ;;
            *)
                fail "Refusing unexpected package object: $entry"
                ;;
        esac
    done < <(/usr/bin/find "$package_dir" -mindepth 1 -maxdepth 1 -print | \
        LC_ALL=C /usr/bin/sort)
}

require_supported_host() {
    (( EUID == 0 )) || fail "Installer scripts require root." 77
    [[ $(/usr/bin/uname -m) == arm64 ]] || \
        fail "This package requires an arm64 Mac."
    # The controller performs live capability and policy readback checks.  Do
    # not reject point releases merely because they have a new build/XNU
    # string; the old exact build gate made the package unusable after a point
    # release update.
    verify_directory /private '0:0:755:Directory:sunlnk,hidden'
    verify_directory /private/var '0:0:755:Directory:sunlnk'
    verify_directory /private/var/db '0:0:755:Directory:sunlnk'
    verify_directory /usr/local '0:0:755:Directory:sunlnk'
    if [[ -e /usr/local/bin || -L /usr/local/bin ]]; then
        verify_directory /usr/local/bin '0:0:755:Directory:-'
    fi
    if [[ -e /usr/local/libexec || -L /usr/local/libexec ]]; then
        verify_directory /usr/local/libexec '0:0:755:Directory:-'
    fi
}

require_no_transition_objects() {
    require_absent "$uninstall_journal"
    require_absent "$operation_claim"
}

operation_claim_temporaries() {
    setopt local_options null_glob
    local candidate
    for candidate in /private/var/db/.io.github.northstarxyzz.pcvrpatcher.memory-policy.operation.new.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        print -r -- "$candidate"
    done | LC_ALL=C /usr/bin/sort
}

verify_operation_claim() {
    verify_file "$operation_claim" 400 "$operation_claim_sha"
    verify_no_xattrs "$operation_claim"
}

remove_exact_stale_operation_claim() {
    local stale_identity
    local current_identity

    # Repair an exact, inactive claim whose only drift is macOS-added xattrs.
    # Never mutate an active claim or one whose content/metadata is unknown.
    verify_file "$operation_claim" 400 "$operation_claim_sha"
    [[ $(holder_state "$operation_claim") == inactive ]] || return 1
    clear_and_verify_no_xattrs "$operation_claim"
    stale_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim")
    verify_file "$operation_claim" 400 "$operation_claim_sha"
    clear_and_verify_no_xattrs "$operation_claim"
    [[ $(holder_state "$operation_claim") == inactive ]] || return 1
    current_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim")
    [[ "$current_identity" == "$stale_identity" ]] || \
        fail "Operation claim identity changed during stale recovery."
    /bin/unlink "$operation_claim"
    require_absent "$operation_claim"
}

repair_operation_claim_temp() {
    local candidates=()
    local candidate
    local metadata
    local candidate_identity
    local claim_identity

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && candidates+=("$candidate")
    done < <(operation_claim_temporaries)
    (( ${#candidates} <= 1 )) || \
        fail "Multiple operation-claim temporaries are untrusted."
    (( ${#candidates} == 1 )) || return 0
    candidate=${candidates[1]}

    [[ $(holder_state "$candidate") == inactive ]] || \
        fail "Another operation is publishing its ownership claim." 75
    if [[ -e "$operation_claim" || -L "$operation_claim" ]]; then
        metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' \
            "$candidate" 2>/dev/null || true)
        [[ "$metadata" == '0:0:400:Regular File:-:2' ]] || \
            fail "Unsafe linked operation-claim temporary: $metadata"
        verify_no_acl "$candidate"
        verify_no_xattrs "$candidate"
        [[ $(sha256 "$candidate") == "$operation_claim_sha" ]] || \
            fail "Operation-claim temporary hash mismatch."
        metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' \
            "$operation_claim" 2>/dev/null || true)
        [[ "$metadata" == '0:0:400:Regular File:-:2' ]] || \
            fail "Unsafe linked operation claim: $metadata"
        verify_no_acl "$operation_claim"
        verify_no_xattrs "$operation_claim"
        [[ $(sha256 "$operation_claim") == "$operation_claim_sha" ]] || \
            fail "Operation claim hash mismatch."
        candidate_identity=$(/usr/bin/stat -f '%d:%i' "$candidate")
        claim_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim")
        [[ "$candidate_identity" == "$claim_identity" ]] || \
            fail "Operation claim temporary identifies another inode."
        [[ $(holder_state "$operation_claim") == inactive ]] || \
            fail "Another operation owns the published claim." 75
        /bin/unlink "$candidate"
        verify_operation_claim
        return
    fi

    metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' \
        "$candidate" 2>/dev/null || true)
    case "$metadata" in
        0:0:400:'Regular File':-:1|0:0:600:'Regular File':-:1)
            verify_no_acl "$candidate"
            verify_no_xattrs "$candidate"
            /bin/unlink "$candidate"
            ;;
        *) fail "Unsafe orphaned operation-claim temporary: $metadata" ;;
    esac
}

verify_owned_operation_claim() {
    local current_identity
    local holders
    local result

    [[ -n "$owned_operation_claim_identity" &&
       -n "$operation_claim_fd" &&
       -n "$fixed_operation_claim_fd" ]] || \
        fail "This Installer process does not own the operation claim."
    verify_operation_claim
    current_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim")
    [[ "$current_identity" == "$owned_operation_claim_identity" ]] || \
        fail "Operation claim inode changed while owned."
    set +e
    holders=$(/usr/sbin/lsof -t "$operation_claim" 2>&1)
    result=$?
    set -e
    (( result == 0 )) && [[ "$holders" == "$$" ]] || \
        fail "Operation claim is not held exclusively by this process."
}

acquire_operation_claim_for_install() {
    local candidate_identity

    repair_operation_claim_temp
    if [[ -e "$operation_claim" || -L "$operation_claim" ]]; then
        remove_exact_stale_operation_claim || \
            fail "Another live controller operation owns the gate." 75
    fi
    operation_claim_temp=$(/usr/bin/mktemp \
        /private/var/db/.io.github.northstarxyzz.pcvrpatcher.memory-policy.operation.new.XXXXXX)
    print -rn -- "$operation_claim_contents" > "$operation_claim_temp"
    /usr/sbin/chown root:wheel "$operation_claim_temp"
    /bin/chmod 0400 "$operation_claim_temp"
    /usr/bin/chflags 0 "$operation_claim_temp"
    /bin/chmod -N "$operation_claim_temp"
    clear_and_verify_no_xattrs "$operation_claim_temp"
    verify_file "$operation_claim_temp" 400 "$operation_claim_sha"
    exec {operation_claim_fd}< "$operation_claim_temp"
    candidate_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim_temp")
    /bin/ln "$operation_claim_temp" "$operation_claim" || \
        fail "Another operation won the ownership claim." 75
    # Sanitize the published inode as macOS can add provenance metadata at
    # hard-link publication time.
    clear_and_verify_no_xattrs "$operation_claim"
    owned_operation_claim_identity=$candidate_identity
    exec {fixed_operation_claim_fd}< "$operation_claim"
    [[ $(/usr/bin/stat -f '%d:%i' "$operation_claim") ==
       "$owned_operation_claim_identity" ]] || \
        fail "Fixed operation claim does not bind the published inode."
    /bin/unlink "$operation_claim_temp"
    operation_claim_temp=''
    verify_owned_operation_claim
    require_absent "$uninstall_journal"
}

release_owned_operation_claim() {
    local current_identity

    if [[ -n "$owned_operation_claim_identity" ]]; then
        current_identity=$(/usr/bin/stat -f '%d:%i' "$operation_claim" \
            2>/dev/null || true)
        if [[ "$current_identity" == "$owned_operation_claim_identity" ]]; then
            verify_owned_operation_claim
            /bin/unlink "$operation_claim"
        fi
        owned_operation_claim_identity=''
    fi
    if [[ -n "$operation_claim_fd" ]]; then
        exec {operation_claim_fd}<&-
        operation_claim_fd=''
    fi
    if [[ -n "$fixed_operation_claim_fd" ]]; then
        exec {fixed_operation_claim_fd}<&-
        fixed_operation_claim_fd=''
    fi
}

verify_owned_install_transition() {
    verify_owned_operation_claim
    verify_file "$install_journal" 400 "$install_journal_sha"
    require_absent "$uninstall_journal"
}

# Pure closed-table classifier for recovery while the exact install journal is
# present.  The reviewed payload order is runner -> controller -> attestation;
# predecessor quarantine is controller -> runner; postinstall cleanup is
# runner-quarantine -> controller-quarantine -> journal.  Callers must treat
# "reject" as terminal and must never infer another combination.
classify_new_journal_quarantine_state() {
    case "$1:$2" in
        0:0) print -- fresh ;;
        *) print -- reject ;;
    esac
}

classify_journaled_install_state() {
    local controller_present=$1
    local runner_present=$2
    local attestation_present=$3
    local installed_receipt=$4
    local controller_sha=$5
    local runner_sha=$6
    local quarantined_controller_present=$7
    local quarantined_runner_present=$8
    local quarantined_controller_sha=$9
    local quarantined_runner_sha=${10}
    local final_state

    final_state="$controller_present:$runner_present:$attestation_present:$installed_receipt:$controller_sha:$runner_sha"

    if (( quarantined_runner_present && ! quarantined_controller_present )); then
        print -- reject
        return
    fi
    if (( quarantined_controller_present && quarantined_runner_present )); then
        case "$quarantined_controller_sha:$quarantined_runner_sha" in
            "$r5_controller_sha:$r5_runner_sha"|"$r3_controller_sha:$r3_runner_sha"|\
            "$r6_previous_controller_sha:$r6_previous_runner_sha"|\
            "$r6_pre_provenance_controller_sha:$r6_pre_provenance_runner_sha"|\
            "$r6_installed_controller_sha:$r6_installed_runner_sha") ;;
            *) print -- reject; return ;;
        esac
        if [[ "$quarantined_controller_sha:$quarantined_runner_sha" == \
              "$r6_previous_controller_sha:$r6_previous_runner_sha" || \
              "$quarantined_controller_sha:$quarantined_runner_sha" == \
              "$r6_pre_provenance_controller_sha:$r6_pre_provenance_runner_sha" || \
              "$quarantined_controller_sha:$quarantined_runner_sha" == \
              "$r6_installed_controller_sha:$r6_installed_runner_sha" ]]; then
            case "$final_state" in
                0:0:1:absent::|0:0:1:current::)
                    print -- resume
                    return
                    ;;
            esac
        fi
        case "$final_state" in
            0:0:0:absent::|\
            0:1:0:absent::"$current_runner_sha"|\
            1:1:0:absent:"$current_controller_sha":"$current_runner_sha"|\
            1:1:1:absent:"$current_controller_sha":"$current_runner_sha")
                print -- resume
                ;;
            *) print -- reject ;;
        esac
        return
    fi
    if (( quarantined_controller_present )); then
        case "$quarantined_controller_sha:$runner_sha:$final_state" in
            "$r5_controller_sha:$r5_runner_sha:0:1:0:absent::${r5_runner_sha}")
                print -- complete-quarantine-r5
                ;;
            "$r3_controller_sha:$r3_runner_sha:0:1:0:absent::${r3_runner_sha}")
                print -- complete-quarantine-r3
                ;;
            "$r6_previous_controller_sha:$r6_previous_runner_sha:0:1:1:current::${r6_previous_runner_sha}"|\
            "$r6_previous_controller_sha:$r6_previous_runner_sha:0:1:0:absent::${r6_previous_runner_sha}"|\
            "$r6_pre_provenance_controller_sha:$r6_pre_provenance_runner_sha:0:1:1:current::${r6_pre_provenance_runner_sha}"|\
            "$r6_pre_provenance_controller_sha:$r6_pre_provenance_runner_sha:0:1:0:absent::${r6_pre_provenance_runner_sha}"|\
            "$r6_installed_controller_sha:$r6_installed_runner_sha:0:1:1:current::${r6_installed_runner_sha}"|\
            "$r6_installed_controller_sha:$r6_installed_runner_sha:0:1:0:absent::${r6_installed_runner_sha}")
                print -- complete-quarantine-r6-previous
                ;;
            "$r5_controller_sha:$current_runner_sha:1:1:1:absent:${current_controller_sha}:${current_runner_sha}"|\
            "$r3_controller_sha:$current_runner_sha:1:1:1:absent:${current_controller_sha}:${current_runner_sha}"|\
            "$r6_previous_controller_sha:$current_runner_sha:1:1:1:absent:${current_controller_sha}:${current_runner_sha}"|\
            "$r6_pre_provenance_controller_sha:$current_runner_sha:1:1:1:absent:${current_controller_sha}:${current_runner_sha}"|\
            "$r6_installed_controller_sha:$current_runner_sha:1:1:1:absent:${current_controller_sha}:${current_runner_sha}")
                print -- resume
                ;;
            *) print -- reject ;;
        esac
        return
    fi

    case "$final_state" in
        1:1:0:absent:"$r5_controller_sha":"$r5_runner_sha")
            print -- quarantine-r5
            ;;
        1:1:0:absent:"$r3_controller_sha":"$r3_runner_sha")
            print -- quarantine-r3
            ;;
        1:1:1:current:"$r6_previous_controller_sha":"$r6_previous_runner_sha"|\
        1:1:1:absent:"$r6_previous_controller_sha":"$r6_previous_runner_sha"|\
        1:1:0:absent:"$r6_previous_controller_sha":"$r6_previous_runner_sha"|\
        1:1:1:current:"$r6_pre_provenance_controller_sha":"$r6_pre_provenance_runner_sha"|\
        1:1:1:absent:"$r6_pre_provenance_controller_sha":"$r6_pre_provenance_runner_sha"|\
        1:1:0:absent:"$r6_pre_provenance_controller_sha":"$r6_pre_provenance_runner_sha"|\
        1:1:1:current:"$r6_installed_controller_sha":"$r6_installed_runner_sha"|\
        1:1:1:absent:"$r6_installed_controller_sha":"$r6_installed_runner_sha")
            if [[ "$controller_sha" == "$r6_installed_controller_sha" ]]; then
                print -- quarantine-r6-installed
            else
                print -- quarantine-r6-previous
            fi
            ;;
        0:0:0:absent::|\
        0:1:0:absent::"$current_runner_sha"|\
        1:1:0:absent:"$current_controller_sha":"$current_runner_sha"|\
        1:1:1:absent:"$current_controller_sha":"$current_runner_sha"|\
        1:1:1:current:"$current_controller_sha":"$current_runner_sha")
            print -- resume
            ;;
        *) print -- reject ;;
    esac
}

require_inactive_after_quarantine() {
    local executable
    for executable in \
        "$controller" "$controller_quarantine" \
        "$runner" "$runner_quarantine"; do
        if [[ -e "$executable" && ! -L "$executable" ]]; then
            if [[ $(holder_state "$executable") == active ]]; then
                fail "Refusing installation while a reviewed executable inode is active." 75
            fi
        fi
    done

    # Bind the lsof observations to the same exact identities before allowing
    # Installer to publish payload bytes.  The capability-gated controller independently
    # refuses to start while the install journal exists, closing the residual
    # script-interpreter window where an older runner no longer holds its own
    # source inode but has not yet attempted its fixed controller exec.
    if [[ -e "$controller" || -L "$controller" ]]; then
        verify_file "$controller" 500 "$current_controller_sha"
        /usr/bin/codesign --verify --strict "$controller"
    fi
    if [[ -e "$runner" || -L "$runner" ]]; then
        verify_file "$runner" 555 "$current_runner_sha"
    fi
    if [[ -e "$controller_quarantine" || -L "$controller_quarantine" ]]; then
        verify_predecessor_controller "$controller_quarantine"
    fi
    if [[ -e "$runner_quarantine" || -L "$runner_quarantine" ]]; then
        verify_predecessor_runner "$runner_quarantine"
    fi
    clear_exact_stale_runtime
}

verify_predecessor_controller() {
    verify_file_metadata "$1" 500
    case $(sha256 "$1") in
        "$r5_controller_sha"|"$r3_controller_sha"|"$r6_previous_controller_sha"|\
        "$r6_installed_controller_sha") ;;
        *) fail "Unknown predecessor controller quarantine." ;;
    esac
    /usr/bin/codesign --verify --strict "$1"
}

verify_predecessor_runner() {
    verify_file_metadata "$1" 555
    case $(sha256 "$1") in
        "$r5_runner_sha"|"$r3_runner_sha"|"$r6_previous_runner_sha"|\
        "$r6_pre_provenance_runner_sha"|"$r6_installed_runner_sha") ;;
        *) fail "Unknown predecessor runner quarantine." ;;
    esac
}

quarantine_predecessor_pair() {
    local expected_controller=$1
    local expected_runner=$2

    require_absent "$controller_quarantine"
    require_absent "$runner_quarantine"
    verify_file "$controller" 500 "$expected_controller"
    verify_file "$runner" 555 "$expected_runner"
    verify_owned_install_transition
    /bin/mv "$controller" "$controller_quarantine"
    verify_file "$controller_quarantine" 500 "$expected_controller"
    verify_owned_install_transition
    /bin/mv "$runner" "$runner_quarantine"
    verify_file "$runner_quarantine" 555 "$expected_runner"
}

holder_state() {
    local target=$1
    local holders
    local result

    set +e
    holders=$(/usr/sbin/lsof -t "$target" 2>&1)
    result=$?
    set -e
    if (( result == 0 )) && [[ -n "$holders" ]]; then
        print -- active
        return
    fi
    if (( result == 1 )) && [[ -z "$holders" ]]; then
        print -- inactive
        return
    fi
    fail "Could not safely inspect active holders: $target" 74
}

resolve_console_identity() {
    local device_metadata
    local console_uid
    local console_gid

    device_metadata=$(/usr/bin/stat -f '%OLp:%HT:%Sf:%l' /dev/console 2>/dev/null || true)
    [[ "$device_metadata" == '622:Character Device:-:1' ]] || \
        fail "Could not bind the active console identity to /dev/console."
    verify_no_acl /dev/console
    console_uid=$(/usr/bin/stat -f '%u' /dev/console)
    console_gid=$(/usr/bin/stat -f '%g' /dev/console)
    [[ "$console_uid" == <-> && "$console_gid" == <-> && "$console_uid" != 0 ]] || \
        fail "Installer requires a non-root active console user."
    print -- "$console_uid:$console_gid"
}

verify_inactive_stale_socket() {
    local target=$1
    local expected_uid=$2
    local expected_gid=$3
    local socket_metadata

    socket_metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' \
        "$target" 2>/dev/null || true)
    [[ "$socket_metadata" == \
       "${expected_uid}:${expected_gid}:600:Socket:-:1" ]] || \
        fail "Refusing unexpected session socket metadata: $socket_metadata"
    verify_no_acl "$target"
    [[ $(holder_state "$target") == inactive ]] || \
        fail "A controller session still owns the status socket." 75
}

clear_exact_stale_runtime() {
    local entry
    local name
    local console_identity
    local console_uid
    local console_gid

    if [[ ! -e "$runtime_dir" && ! -L "$runtime_dir" ]]; then
        return
    fi
    verify_directory "$runtime_dir" '0:0:755:Directory:-'
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name=${entry:t}
        case "$name" in
            controller.lock|session.sock)
                ;;
            *)
                fail "Refusing unexpected runtime object: $entry"
                ;;
        esac
    done < <(/usr/bin/find "$runtime_dir" -mindepth 1 -maxdepth 1 -print | \
        LC_ALL=C /usr/bin/sort)

    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        verify_file "$lock_file" 600 \
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        [[ $(holder_state "$lock_file") == inactive ]] || \
            fail "A controller session still owns the runtime lock." 75
    fi
    if [[ -e "$session_socket" || -L "$session_socket" ]]; then
        console_identity=$(resolve_console_identity)
        console_uid=${console_identity%%:*}
        console_gid=${console_identity##*:}
        verify_inactive_stale_socket "$session_socket" \
            "$console_uid" "$console_gid"
    fi
    if [[ -e "$session_socket" || -L "$session_socket" ]]; then
        /bin/unlink "$session_socket"
    fi
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        /bin/unlink "$lock_file"
    fi
    /bin/rmdir "$runtime_dir"
}

install_journal_temporaries() {
    setopt local_options null_glob
    local candidate
    for candidate in /private/var/db/.io.github.northstarxyzz.pcvrpatcher.memory-policy.install.new.*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        print -r -- "$candidate"
    done | LC_ALL=C /usr/bin/sort
}

repair_install_journal_temp() {
    local candidates=()
    local candidate
    local metadata
    local candidate_identity
    local journal_identity

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && candidates+=("$candidate")
    done < <(install_journal_temporaries)
    (( ${#candidates} <= 1 )) || fail "Multiple install journal temporaries exist."
    (( ${#candidates} == 1 )) || return 0
    candidate=${candidates[1]}
    if [[ -e "$install_journal" || -L "$install_journal" ]]; then
        metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' "$candidate" 2>/dev/null || true)
        [[ "$metadata" == '0:0:400:Regular File:-:2' ]] || \
            fail "Unsafe linked install-journal temporary: $metadata"
        verify_no_acl "$candidate"
        [[ $(sha256 "$candidate") == "$install_journal_sha" ]] || \
            fail "Install-journal temporary hash mismatch."
        metadata=$(/usr/bin/stat -f '%u:%g:%OLp:%HT:%Sf:%l' "$install_journal" 2>/dev/null || true)
        [[ "$metadata" == '0:0:400:Regular File:-:2' ]] || \
            fail "Unsafe linked install journal: $metadata"
        verify_no_acl "$install_journal"
        [[ $(sha256 "$install_journal") == "$install_journal_sha" ]] || \
            fail "Install journal hash mismatch."
        candidate_identity=$(/usr/bin/stat -f '%d:%i' "$candidate")
        journal_identity=$(/usr/bin/stat -f '%d:%i' "$install_journal")
        [[ "$candidate_identity" == "$journal_identity" ]] || \
            fail "Install journal and temporary identify different files."
        /bin/unlink "$candidate"
        verify_file "$install_journal" 400 "$install_journal_sha"
        return
    fi
    metadata=$(/usr/bin/stat -f '%u:%OLp:%HT:%Sf:%l' "$candidate" 2>/dev/null || true)
    case "$metadata" in
        0:400:'Regular File':-:1|0:600:'Regular File':-:1)
            verify_no_acl "$candidate"
            /bin/unlink "$candidate"
            ;;
        *)
            fail "Unsafe orphaned install-journal temporary: $metadata"
            ;;
    esac
}

ensure_install_journal() {
    install_journal_was_new=0
    install_journal_temp=''
    repair_install_journal_temp
    if [[ -e "$install_journal" || -L "$install_journal" ]]; then
        verify_file "$install_journal" 400 "$install_journal_sha"
        return
    fi
    install_journal_temp=$(/usr/bin/mktemp \
        /private/var/db/.io.github.northstarxyzz.pcvrpatcher.memory-policy.install.new.XXXXXX)
    print -rn -- "$install_journal_contents" > "$install_journal_temp"
    /usr/sbin/chown root:wheel "$install_journal_temp"
    /bin/chmod 0400 "$install_journal_temp"
    /usr/bin/chflags 0 "$install_journal_temp"
    /bin/chmod -N "$install_journal_temp"
    clear_and_verify_no_xattrs "$install_journal_temp"
    verify_file "$install_journal_temp" 400 "$install_journal_sha"
    /bin/ln "$install_journal_temp" "$install_journal" || \
        fail "Another installer owns the install journal." 75
    /bin/unlink "$install_journal_temp"
    install_journal_temp=''
    verify_file "$install_journal" 400 "$install_journal_sha"
    install_journal_was_new=1
}

verify_no_xattrs() {
    local attributes
    local unsafe_attribute
    attributes=$(/usr/bin/xattr "$1" 2>/dev/null) || \
        fail "Could not inspect extended attributes: $1"
    unsafe_attribute=$(print -r -- "$attributes" | /usr/bin/awk \
        '$0 != "" && $0 != "com.apple.provenance" { print; exit }')
    [[ -z "$unsafe_attribute" ]] || \
        fail "Unexpected extended attributes: $1 ($unsafe_attribute)"
}

clear_and_verify_no_xattrs() {
    local target=$1
    local attributes
    local unsafe_attribute
    local attempt

    # macOS may attach provenance metadata immediately after a hard-link is
    # published.  Retry only on the exact, already-validated root-owned
    # transaction object; keep the final check fail-closed.
    for attempt in 1 2 3 4 5 6 7 8; do
        /usr/bin/xattr -c "$target" 2>/dev/null || true
        if attributes=$(/usr/bin/xattr "$target" 2>/dev/null); then
            unsafe_attribute=$(print -r -- "$attributes" | /usr/bin/awk \
                '$0 != "" && $0 != "com.apple.provenance" { print; exit }')
            [[ -z "$unsafe_attribute" ]] && return 0
        fi
        (( attempt < 8 )) && /bin/sleep 0.1
    done
    fail "Unexpected extended attributes: $target"
}
