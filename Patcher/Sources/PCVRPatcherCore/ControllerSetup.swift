import CryptoKit
import Darwin
import Foundation

public enum ControllerInstallationState: Sendable, Equatable {
    case absent
    case knownUpgradeRequired
    case exact(ControllerInstallationEvidence)
    case installing
    case uninstalling
    case uninstallingActive
    case uninstallFinalizationRepairRequired
    case unknown(String)
}

public struct ControllerOperationClaimIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// `live` means a process still holds the exact claim inode open. `stale`
/// means the exact path exists without a holder and may be recovered by one
/// newly authorized root operation. The root-tree verifier binds either
/// observation to the current dev/inode before using it.
public enum ControllerOperationClaimObservation: Sendable, Equatable {
    case absent
    case live(ControllerOperationClaimIdentity)
    case stale(ControllerOperationClaimIdentity)
    case unknown(String)
}

/// Pure parser for the fixed `/usr/sbin/lsof -t <claim>` observation. Keeping
/// it in Core makes malformed output, tool errors and inode-replacement races
/// directly testable without invoking or mocking a privileged operation.
public enum ControllerOperationClaimHolderClassifier {
    /// Avoid invoking `lsof` for a path that is strictly absent. On macOS,
    /// `lsof -t <absent-path>` writes a diagnostic to stderr, so parsing that
    /// command cannot prove absence. Two no-follow `lstat` observations are
    /// required to close the small creation race instead.
    public static func classifyAbsentWithoutHolderQuery(
        before: ControllerOperationClaimIdentity?,
        after: ControllerOperationClaimIdentity?
    ) -> ControllerOperationClaimObservation? {
        guard before == nil else { return nil }
        guard after == nil else {
            return .unknown(
                "the operation claim appeared while absence was inspected"
            )
        }
        return .absent
    }

    public static func classify(
        terminationStatus: Int32,
        stdout: Data,
        stderr: Data,
        before: ControllerOperationClaimIdentity?,
        after: ControllerOperationClaimIdentity?
    ) -> ControllerOperationClaimObservation {
        guard before == after else {
            return .unknown(
                "the operation claim changed while holders were inspected"
            )
        }
        guard stderr.isEmpty else {
            return .unknown("lsof could not prove the operation-claim owner")
        }
        guard let identity = after else {
            guard terminationStatus == 1, stdout.isEmpty else {
                return .unknown(
                    "lsof reported a holder for an absent operation claim"
                )
            }
            return .absent
        }
        switch terminationStatus {
        case 0:
            let holders = stdout.split(whereSeparator: { byte in
                byte == 32 || (byte >= 9 && byte <= 13)
            })
            guard !holders.isEmpty,
                  holders.allSatisfy({ token in
                    !token.isEmpty && token.allSatisfy({ $0 >= 48 && $0 <= 57 })
                  }) else {
                return .unknown(
                    "lsof returned a non-canonical operation-claim holder"
                )
            }
            return .live(identity)
        case 1 where stdout.isEmpty:
            return .stale(identity)
        default:
            return .unknown(
                "lsof could not classify the operation claim (status \(terminationStatus))"
            )
        }
    }
}

public enum ControllerUninstallPollAction: Sendable, Equatable {
    case complete
    case observe
    case authorize
    case reject
}

/// Tracks whether this Patcher invocation has actually launched the reviewed
/// root runner. Merely reaching an authorization checkpoint is not enough:
/// an active owner may win the claim during either identity recheck, in which
/// case the sole launch opportunity remains available after that owner exits.
public struct ControllerUninstallAuthorizationTracker: Sendable {
    public private(set) var launchedReviewedRunner = false

    public init() {}

    public func action(
        for state: ControllerInstallationState
    ) -> ControllerUninstallPollAction {
        switch state {
        case .absent:
            return .complete
        case .uninstallingActive:
            return .observe
        case .exact, .uninstalling:
            return launchedReviewedRunner ? .observe : .authorize
        case .knownUpgradeRequired, .installing,
             .uninstallFinalizationRepairRequired, .unknown:
            return .reject
        }
    }

    public mutating func recordAuthorizationAttempt(
        launchedReviewedRunner launched: Bool
    ) {
        if launched { launchedReviewedRunner = true }
    }
}

public struct ControllerSetupRequest: Sendable, Equatable {
    public let requirement: ControllerPackageRequirement
    public let packageURL: URL

    public init(
        requirement: ControllerPackageRequirement,
        packageURL: URL
    ) {
        self.requirement = requirement
        self.packageURL = packageURL
    }
}

/// The UI target owns all authorization and Installer interaction. The engine
/// only supplies the fixed, manifest-derived request and independently asks
/// this provider for a post-operation identity proof.
public protocol ControllerSetupProviding: Sendable {
    func inspect(
        requirement: ControllerPackageRequirement
    ) async throws -> ControllerInstallationState

    func install(_ request: ControllerSetupRequest) async throws

    func uninstall(
        requirement: ControllerPackageRequirement
    ) async throws
}

public struct UnavailableControllerSetupProvider: ControllerSetupProviding {
    public init() {}

    public func inspect(
        requirement: ControllerPackageRequirement
    ) async throws -> ControllerInstallationState {
        .unknown("the controller setup provider is unavailable")
    }

    public func install(_ request: ControllerSetupRequest) async throws {
        throw PatcherError.controllerSetupFailed(
            "the controller setup provider is unavailable"
        )
    }

    public func uninstall(
        requirement: ControllerPackageRequirement
    ) async throws {
        throw PatcherError.controllerSetupFailed(
            "the controller uninstall provider is unavailable"
        )
    }
}

public struct ControllerPackageFileIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let sha256: String
}

public enum ControllerPackageVerifier {
    /// Verifies the exact embedded package without following its leaf or any
    /// ancestor symlink. This is repeated immediately before Installer handoff.
    @discardableResult
    public static func verify(
        _ packageURL: URL,
        requirement: ControllerPackageRequirement,
        expectedOwnerUID: uid_t? = nil
    ) throws -> ControllerPackageFileIdentity {
        try SecureFileSystem.requireNoSymlinkComponents(
            packageURL,
            allowMissingSuffix: false
        )
        let status = try SecureFileSystem.status(of: packageURL)
        let dangerousFlags = UInt32(
            UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
        )
        guard (status.st_mode & S_IFMT) == S_IFREG,
              expectedOwnerUID.map({ status.st_uid == $0 }) ??
                (status.st_uid == getuid() || status.st_uid == 0),
              status.st_mode & 0o022 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_flags & dangerousFlags == 0 else {
            throw PatcherError.unknownModification(
                "the embedded controller package has unsafe metadata"
            )
        }
        try SecureFileSystem.requireNoExtendedACL(packageURL)
        let sha256 = try AppTreeVerifier.fileSHA256(packageURL)
        guard sha256.caseInsensitiveCompare(requirement.sha256) == .orderedSame
        else {
            throw PatcherError.identityMismatch(
                expected: "controller package \(requirement.sha256)",
                actual: sha256
            )
        }
        let after = try SecureFileSystem.status(of: packageURL)
        guard status.st_dev == after.st_dev,
              status.st_ino == after.st_ino,
              status.st_size == after.st_size,
              status.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              status.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw PatcherError.unknownModification(
                "the embedded controller package changed while verified"
            )
        }
        return ControllerPackageFileIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            size: UInt64(status.st_size),
            sha256: sha256
        )
    }
}

public enum ControllerPackageReceiptState: Sendable, Equatable {
    case absent
    case exact
    case unknown(String)
}

/// Read-only proof of the installed root state. The controller executable is
/// intentionally mode 0500, so the unprivileged Patcher verifies its metadata
/// and relies on the exact, root-owned attestation for its reviewed hash. The
/// readable runner and attestation are both hashed directly.
public enum RootControllerInstallationVerifier {
    // These are the two exact local r6 runners that predate the current
    // provenance-compatible runner. Their controller and attestation are the
    // current reviewed r6 identities; only the runner changed. They are
    // accepted solely as a one-time upgrade path. No other unknown runner is
    // accepted here.
    private static let reviewedPreXattrFixR6RunnerSHA256 =
        "5a712cf92c7c54cf70f554b0804bab28923edf911db82edd1b65b7e010998a87"
    private static let reviewedPreProvenanceFixR6RunnerSHA256 =
        "039047ea409a4cd5b27f142b657f239ec99bbed6e2ee1a866bf031a81973f558"

    static func isReviewedPredecessorRunner(_ sha256: String) -> Bool {
        [
            reviewedPreXattrFixR6RunnerSHA256,
            reviewedPreProvenanceFixR6RunnerSHA256
        ].contains { predecessor in
            sha256.caseInsensitiveCompare(predecessor) == .orderedSame
        }
    }

    public static func inspect(
        requirement: ControllerPackageRequirement,
        receipt: ControllerPackageReceiptState,
        operationClaim: ControllerOperationClaimObservation
    ) throws -> ControllerInstallationState {
        try inspect(
            requirement: requirement,
            receipt: receipt,
            operationClaim: operationClaim,
            trustedTestRoot: nil
        )
    }

    static func inspectForTesting(
        requirement: ControllerPackageRequirement,
        receipt: ControllerPackageReceiptState,
        operationClaim: ControllerOperationClaimObservation = .absent,
        trustedRoot: URL
    ) throws -> ControllerInstallationState {
        try inspect(
            requirement: requirement,
            receipt: receipt,
            operationClaim: operationClaim,
            trustedTestRoot: trustedRoot
        )
    }

    private static func inspect(
        requirement: ControllerPackageRequirement,
        receipt: ControllerPackageReceiptState,
        operationClaim: ControllerOperationClaimObservation,
        trustedTestRoot: URL?
    ) throws -> ControllerInstallationState {
        let runnerURL = URL(fileURLWithPath: requirement.runner.path)
        let controllerURL = URL(fileURLWithPath: requirement.controller.path)
        let attestationURL = URL(fileURLWithPath: requirement.attestation.path)
        let controllerQuarantineURL = URL(
            fileURLWithPath: requirement.controllerQuarantinePath
        )
        let runnerQuarantineURL = URL(
            fileURLWithPath: requirement.runnerQuarantinePath
        )
        let journalURL = URL(
            fileURLWithPath: requirement.uninstallJournal.path
        )
        let installJournalURL = URL(
            fileURLWithPath: requirement.installJournal.path
        )
        let operationClaimURL = URL(
            fileURLWithPath: requirement.operationClaim.path
        )
        let packageDirectoryURL = controllerURL.deletingLastPathComponent()

        // The two journal leaves may legitimately be absent, but their fixed
        // /private/var/db chain is always security-critical. An unreadable or
        // unsafe chain must never be collapsed into an "absent" journal.
        try requireRootOwnedAncestors(
            journalURL,
            expectedOwnerUID: requirement.uninstallJournal.uid,
            expectedGroupID: requirement.uninstallJournal.gid,
            trustedTestRoot: trustedTestRoot
        )
        try requireRootOwnedAncestors(
            installJournalURL,
            expectedOwnerUID: requirement.installJournal.uid,
            expectedGroupID: requirement.installJournal.gid,
            trustedTestRoot: trustedTestRoot
        )
        try requireRootOwnedAncestors(
            operationClaimURL,
            expectedOwnerUID: requirement.operationClaim.uid,
            expectedGroupID: requirement.operationClaim.gid,
            trustedTestRoot: trustedTestRoot
        )

        let runnerExists = try SecureFileSystem.nodeExistsStrict(runnerURL)
        let controllerExists = try SecureFileSystem.nodeExistsStrict(
            controllerURL
        )
        let attestationExists = try SecureFileSystem.nodeExistsStrict(
            attestationURL
        )
        let controllerQuarantineExists = try SecureFileSystem.nodeExistsStrict(
            controllerQuarantineURL
        )
        let runnerQuarantineExists = try SecureFileSystem.nodeExistsStrict(
            runnerQuarantineURL
        )
        let journalExists = try SecureFileSystem.nodeExistsStrict(journalURL)
        let installJournalExists = try SecureFileSystem.nodeExistsStrict(
            installJournalURL
        )
        let operationClaimExists = try SecureFileSystem.nodeExistsStrict(
            operationClaimURL
        )
        let packageDirectoryExists = try SecureFileSystem.nodeExistsStrict(
            packageDirectoryURL
        )

        let claimIsLive: Bool
        let claimIsStale: Bool
        if operationClaimExists {
            _ = try requireRootOwnedRegularFile(
                operationClaimURL,
                expected: requirement.operationClaim,
                shouldHash: false,
                trustedTestRoot: trustedTestRoot
            )
            let status = try SecureFileSystem.status(of: operationClaimURL)
            let identity = ControllerOperationClaimIdentity(
                device: UInt64(bitPattern: Int64(status.st_dev)),
                inode: UInt64(status.st_ino)
            )
            switch operationClaim {
            case .live(let observed) where observed == identity:
                claimIsLive = true
                claimIsStale = false
            case .stale(let observed) where observed == identity:
                claimIsLive = false
                claimIsStale = true
            case .unknown(let reason):
                return .unknown(reason)
            default:
                return .unknown(
                    "the operation-claim observation does not match its exact inode"
                )
            }
        } else {
            switch operationClaim {
            case .absent:
                claimIsLive = false
                claimIsStale = false
            case .unknown(let reason):
                return .unknown(reason)
            case .live, .stale:
                return .unknown(
                    "the observed operation claim disappeared before verification"
                )
            }
        }

        let packageEntries: Set<String>
        if packageDirectoryExists {
            try requireTrustedDirectory(
                packageDirectoryURL,
                expectedOwnerUID: requirement.controller.uid,
                expectedGroupID: requirement.controller.gid,
                expectedMode: 0o755
            )
            packageEntries = try SecureFileSystem.directEntryNames(
                in: packageDirectoryURL
            )
        } else {
            packageEntries = []
        }

        if installJournalExists {
            guard !journalExists else {
                return .unknown(
                    "install and uninstall journals exist simultaneously"
                )
            }
            _ = try requireRootOwnedRegularFile(
                installJournalURL,
                expected: requirement.installJournal,
                shouldHash: false,
                trustedTestRoot: trustedTestRoot
            )
            let reviewedInstallerEntries: Set<String> = [
                "controller", "installation.json", ".controller.pcvr-install"
            ]
            guard packageEntries.isSubset(of: reviewedInstallerEntries) else {
                return .unknown(
                    "the journaled install has an unexpected package object"
                )
            }
            // Its canonical 0400 bytes are revalidated by the privileged
            // package scripts, including any reviewed predecessor quarantine.
            // The GUI never treats this state as complete.
            return .installing
        }

        if case .unknown(let reason) = receipt { return .unknown(reason) }

        if journalExists {
            _ = try requireRootOwnedRegularFile(
                journalURL,
                expected: requirement.uninstallJournal,
                shouldHash: false,
                trustedTestRoot: trustedTestRoot
            )
            guard runnerExists,
                  try exactReadableArtifact(
                    runnerURL,
                    requirement.runner,
                    trustedTestRoot: trustedTestRoot
                  ) else {
                return .unknown(
                    "the uninstall journal does not have the exact runner"
                )
            }
            guard !runnerQuarantineExists,
                  !controllerQuarantineExists else {
                return .unknown(
                    "an install quarantine exists during root uninstall"
                )
            }

            if !packageDirectoryExists {
                guard !controllerExists,
                      !attestationExists,
                      receipt == .absent else {
                    return .unknown(
                        "uninstall removed its package directory out of order"
                    )
                }
                return claimIsLive ? .uninstallingActive : .uninstalling
            }

            let controllerIsExact: Bool
            if controllerExists {
                _ = try requireRootOwnedRegularFile(
                    controllerURL,
                    expected: requirement.controller,
                    shouldHash: false,
                    trustedTestRoot: trustedTestRoot
                )
                controllerIsExact = true
            } else {
                controllerIsExact = false
            }
            let attestationIsExact: Bool
            if attestationExists {
                attestationIsExact = try exactReadableArtifact(
                    attestationURL,
                    requirement.attestation,
                    trustedTestRoot: trustedTestRoot
                )
            } else {
                attestationIsExact = false
            }

            var expectedEntries = Set<String>()
            if controllerExists { expectedEntries.insert("controller") }
            if attestationExists { expectedEntries.insert("installation.json") }
            guard packageEntries == expectedEntries else {
                return .unknown(
                    "root uninstall package entries are not an exact reviewed subset"
                )
            }

            let reviewedOrderedSubset =
                (controllerIsExact && attestationIsExact &&
                    receipt == .exact) ||
                (!controllerIsExact && attestationIsExact &&
                    receipt == .exact) ||
                (!controllerIsExact && attestationIsExact &&
                    receipt == .absent) ||
                (!controllerIsExact && !attestationExists &&
                    receipt == .absent)
            guard reviewedOrderedSubset else {
                return .unknown(
                    "root uninstall artifacts are not in a reviewed ordered subset"
                )
            }
            return claimIsLive ? .uninstallingActive : .uninstalling
        }

        guard !controllerQuarantineExists, !runnerQuarantineExists else {
            return .unknown(
                "an unjournaled controller installation quarantine remains"
            )
        }

        var expectedEntries = Set<String>()
        if controllerExists { expectedEntries.insert("controller") }
        if attestationExists { expectedEntries.insert("installation.json") }
        guard packageEntries == expectedEntries else {
            return .unknown(
                "the root controller package contains an unexpected object"
            )
        }

        if !runnerExists && !controllerExists && !attestationExists &&
            !journalExists && !installJournalExists &&
            !packageDirectoryExists {
            if claimIsLive {
                guard receipt == .absent else {
                    return .unknown(
                        "an active final uninstall retains a package receipt"
                    )
                }
                return .uninstallingActive
            }
            if claimIsStale {
                guard receipt == .absent else {
                    return .unknown(
                        "a stale final operation claim retains a package receipt"
                    )
                }
                return .uninstallFinalizationRepairRequired
            }
            switch receipt {
            case .absent: return .absent
            case .exact:
                return .unknown(
                    "the package receipt remains without installed controller files"
                )
            case .unknown(let reason): return .unknown(reason)
            }
        }

        if runnerExists && !controllerExists && !attestationExists &&
            !packageDirectoryExists && receipt == .absent {
            guard try exactReadableArtifact(
                runnerURL,
                requirement.runner,
                trustedTestRoot: trustedTestRoot
            ) else {
                return .unknown("uninstall recovery runner is not exact")
            }
            return claimIsLive ? .uninstallingActive : .uninstalling
        }

        guard runnerExists && controllerExists && packageDirectoryExists else {
            return .unknown("the root controller installation is partial")
        }

        let runnerHash = try requireRootOwnedRegularFile(
            runnerURL,
            expected: requirement.runner,
            shouldHash: true,
            trustedTestRoot: trustedTestRoot
        )
        _ = try requireRootOwnedRegularFile(
            controllerURL,
            expected: requirement.controller,
            shouldHash: false,
            trustedTestRoot: trustedTestRoot
        )

        guard attestationExists else {
            // A complete, safe pre-attestation pair is eligible for the
            // package's own strict predecessor allowlist. It is never ready.
            return .knownUpgradeRequired
        }
        let attestationHash = try requireRootOwnedRegularFile(
            attestationURL,
            expected: requirement.attestation,
            shouldHash: true,
            trustedTestRoot: trustedTestRoot
        )

        let runnerMatches = runnerHash.caseInsensitiveCompare(
            requirement.runner.sha256
        ) == .orderedSame
        let attestationMatches = attestationHash.caseInsensitiveCompare(
            requirement.attestation.sha256
        ) == .orderedSame
        guard runnerMatches, attestationMatches else {
            if !runnerMatches,
               attestationMatches,
               Self.isReviewedPredecessorRunner(runnerHash),
               receipt == .exact || receipt == .absent {
                return .knownUpgradeRequired
            }
            return .unknown("the installed r6 root artifacts are not exact")
        }
        if receipt == .absent {
            // Narrow postinstall crash window: exact r6 artifacts and
            // attestation committed, install journal removed, but Installer
            // did not publish its receipt. Reopening the exact package is the
            // only permitted repair; this is never considered ready.
            return .knownUpgradeRequired
        }
        guard receipt == .exact else {
            return .unknown("the package receipt is not exact")
        }
        guard !claimIsLive else {
            return .unknown("a root controller operation is active")
        }
        // Close the enumeration/status race before publishing ready evidence.
        // A later root-runner invocation repeats its own identical allowlist.
        guard try SecureFileSystem.directEntryNames(
            in: packageDirectoryURL
        ) == ["controller", "installation.json"],
              !(try SecureFileSystem.nodeExistsStrict(
                controllerQuarantineURL
              )),
              !(try SecureFileSystem.nodeExistsStrict(runnerQuarantineURL)) else {
            return .unknown(
                "the root controller package changed during verification"
            )
        }
        return .exact(ControllerInstallationEvidence(
            controllerBuildID: requirement.controllerBuildID,
            packageIdentifier: requirement.identifier,
            packageVersion: requirement.version,
            runnerSHA256: runnerHash,
            attestationSHA256: attestationHash
        ))
    }

    private static func exactReadableArtifact(
        _ url: URL,
        _ requirement: RootArtifactRequirement,
        trustedTestRoot: URL?
    ) throws -> Bool {
        let hash = try requireRootOwnedRegularFile(
            url,
            expected: requirement,
            shouldHash: true,
            trustedTestRoot: trustedTestRoot
        )
        return hash.caseInsensitiveCompare(requirement.sha256) == .orderedSame
    }

    private static func requireRootOwnedRegularFile(
        _ url: URL,
        expected: RootArtifactRequirement?,
        shouldHash: Bool,
        trustedTestRoot: URL?
    ) throws -> String {
        try requireRootOwnedAncestors(
            url,
            expectedOwnerUID: expected?.uid ?? 0,
            expectedGroupID: expected?.gid ?? 0,
            trustedTestRoot: trustedTestRoot
        )
        let status = try SecureFileSystem.status(of: url)
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == expected?.uid ?? 0,
              status.st_gid == expected?.gid ?? 0,
              status.st_nlink == 1,
              status.st_mode & 0o022 == 0,
              status.st_flags == 0 else {
            throw PatcherError.unknownModification(
                "unsafe root controller metadata at \(url.path)"
            )
        }
        if let expected {
            guard status.st_uid == expected.uid,
                  status.st_gid == expected.gid,
                  UInt16(status.st_mode & 0o7777) == expected.numericMode,
                  UInt32(status.st_nlink) == expected.linkCount else {
                throw PatcherError.unknownModification(
                    "root controller metadata does not match the manifest at \(url.path)"
                )
            }
        }
        try SecureFileSystem.requireNoExtendedACL(url)
        guard shouldHash else { return "" }
        let actual = try AppTreeVerifier.fileSHA256(url)
        if let expected,
           actual.caseInsensitiveCompare(expected.sha256) != .orderedSame {
            return actual
        }
        return actual
    }

    private static func requireRootOwnedAncestors(
        _ url: URL,
        expectedOwnerUID: uid_t,
        expectedGroupID: gid_t,
        trustedTestRoot: URL?
    ) throws {
        let parentURL = url.deletingLastPathComponent()
        try SecureFileSystem.requireNoSymlinkComponents(
            parentURL,
            allowMissingSuffix: false
        )
        let currentStart: URL
        let components: ArraySlice<String>
        if let trustedTestRoot {
            let rootPath = trustedTestRoot.path
            guard url.path.hasPrefix(rootPath + "/") else {
                throw PatcherError.unsafePath(url)
            }
            currentStart = trustedTestRoot
            components = url.pathComponents
                .dropFirst(trustedTestRoot.pathComponents.count)
                .dropLast()
        } else {
            currentStart = URL(fileURLWithPath: "/", isDirectory: true)
            components = url.pathComponents.dropFirst().dropLast()
        }
        var current = currentStart
        if trustedTestRoot != nil {
            try requireTrustedDirectory(
                current,
                expectedOwnerUID: expectedOwnerUID,
                expectedGroupID: expectedGroupID,
                expectedMode: 0o755,
                expectedFlags: 0
            )
        }
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            try requireTrustedDirectory(
                current,
                expectedOwnerUID: expectedOwnerUID,
                expectedGroupID: expectedGroupID,
                expectedMode: 0o755,
                expectedFlags: reviewedDirectoryFlags(
                    for: current,
                    trustedTestRoot: trustedTestRoot
                )
            )
        }
    }

    private static func reviewedDirectoryFlags(
        for url: URL,
        trustedTestRoot: URL?
    ) -> UInt32 {
        guard trustedTestRoot == nil else { return 0 }
        switch url.path {
        case "/private":
            return UInt32(SF_NOUNLINK | UF_HIDDEN)
        case "/private/var", "/private/var/db", "/usr/local":
            return UInt32(SF_NOUNLINK)
        case "/usr":
            return UInt32(SF_RESTRICTED | UF_HIDDEN)
        default:
            // /usr/local/bin, /usr/local/libexec and the package directory
            // are required as the exact unflagged (`%Sf == -`) state used by
            // the privileged package and runner scripts.
            return 0
        }
    }

    static func requireTrustedDirectory(
        _ url: URL,
        expectedOwnerUID: uid_t,
        expectedGroupID: gid_t,
        expectedMode: mode_t,
        expectedFlags: UInt32 = 0
    ) throws {
        let status = try SecureFileSystem.status(of: url)
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == expectedOwnerUID,
              status.st_gid == expectedGroupID,
              status.st_mode & 0o7777 == expectedMode,
              status.st_flags == expectedFlags else {
            throw PatcherError.unknownModification(
                "unsafe root controller ancestor at \(url.path)"
            )
        }
        try SecureFileSystem.requireNoExtendedACL(url)
    }
}
