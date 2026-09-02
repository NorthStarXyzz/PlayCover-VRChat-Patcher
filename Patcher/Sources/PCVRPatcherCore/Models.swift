import Foundation

public struct CompatibilityManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let patchID: String
    public let supportState: String
    public let architecture: String
    public let playCover: AppIdentity
    public let patchedPlayCover: AppIdentity?
    public let host: HostRequirement
    public let policy: MemoryPolicy
    public let ipc: IPCRequirement
    public let controllerPackage: ControllerPackageRequirement?

    public init(
        schemaVersion: Int = 2,
        patchID: String,
        supportState: String = "experimental",
        architecture: String,
        playCover: AppIdentity,
        patchedPlayCover: AppIdentity?,
        host: HostRequirement,
        policy: MemoryPolicy,
        ipc: IPCRequirement,
        controllerPackage: ControllerPackageRequirement? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.patchID = patchID
        self.supportState = supportState
        self.architecture = architecture
        self.playCover = playCover
        self.patchedPlayCover = patchedPlayCover
        self.host = host
        self.policy = policy
        self.ipc = ipc
        self.controllerPackage = controllerPackage
    }

    public func validateShape() throws {
        guard schemaVersion == 2 else {
            throw PatcherError.unsupportedManifestSchema(schemaVersion)
        }
        guard !patchID.isEmpty,
              patchID.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
              ) != nil else {
            throw PatcherError.invalidManifest(
                "patchID must contain only A-Z, a-z, 0-9, '.', '_' or '-'"
            )
        }
        guard ["experimental", "supported"].contains(supportState) else {
            throw PatcherError.invalidManifest(
                "compatibility entry is revoked or unknown"
            )
        }

        try playCover.validateShape(label: "playCover")
        try patchedPlayCover?.validateShape(label: "patchedPlayCover")
        try controllerPackage?.validateShape()

        guard playCover.bundleIdentifier == "io.playcover.PlayCover" else {
            throw PatcherError.invalidManifest(
                "the original PlayCover identity must be io.playcover.PlayCover"
            )
        }
        guard let patchedPlayCover else { return try validateSourceOnlyShape() }
        guard controllerPackage != nil else {
            throw PatcherError.invalidManifest(
                "a payload-bearing manifest must include controllerPackage"
            )
        }
        guard patchedPlayCover.bundleIdentifier ==
                "io.github.northstarxyzz.PlayCoverVRChat",
              patchedPlayCover.shortVersion == playCover.shortVersion,
              patchedPlayCover.buildVersion == playCover.buildVersion,
              patchedPlayCover.executableName == "PlayCover VRChat",
              let patchedInfoPlistSHA256 = patchedPlayCover.infoPlistSHA256,
              let patchedCodeResourcesSHA256 = patchedPlayCover.codeResourcesSHA256,
              AppIdentity.isSHA256(patchedInfoPlistSHA256),
              AppIdentity.isSHA256(patchedCodeResourcesSHA256) else {
            throw PatcherError.invalidManifest(
                "the patched PlayCover identity must use the reviewed parallel bundle metadata"
            )
        }
        try validateLockedShape()
    }

    private func validateSourceOnlyShape() throws {
        guard controllerPackage == nil else {
            throw PatcherError.invalidManifest(
                "a source-only manifest must not include controllerPackage"
            )
        }
        try validateLockedShape()
    }

    private func validateLockedShape() throws {
        guard playCover.shortVersion == "3.1.0",
              playCover.buildVersion == "856",
              playCover.executableName == "PlayCover",
              playCover.repository == "https://github.com/PlayCover/PlayCover.git",
              playCover.commit == "55638e98f36eac1f3d09803799480e9d83f663f8",
              let infoPlistSHA256 = playCover.infoPlistSHA256,
              let codeResourcesSHA256 = playCover.codeResourcesSHA256,
              AppIdentity.isSHA256(infoPlistSHA256),
              AppIdentity.isSHA256(codeResourcesSHA256) else {
            throw PatcherError.invalidManifest(
                "unexpected PlayCover v0.1 source identity"
            )
        }
        guard architecture == "arm64",
              !host.productVersion.isEmpty,
              !host.buildVersion.isEmpty,
              !host.xnuVersion.isEmpty else {
            throw PatcherError.invalidManifest(
                "the manifest must describe a non-empty tested arm64 host"
            )
        }
        guard policy.mode == .automatic75Percent,
              policy.minGiB == 4,
              policy.maxPhysicalPercent == 75,
              policy.stepGiB == 1,
              policy.waitSeconds == 300,
              policy.fatal == false else {
            throw PatcherError.invalidManifest(
                "unexpected dynamic memory-policy bounds"
            )
        }
        guard ipc.protocolVersion == 2,
              ipc.socketPath ==
                "/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock" else {
            throw PatcherError.invalidManifest("unexpected IPC requirement")
        }
    }
}

public struct ControllerPackageRequirement: Codable, Sendable, Equatable {
    public let relativePath: String
    public let identifier: String
    public let version: String
    public let sha256: String
    public let controllerBuildID: String
    public let controllerQuarantinePath: String
    public let runnerQuarantinePath: String
    public let runner: RootArtifactRequirement
    public let controller: RootArtifactRequirement
    public let attestation: RootArtifactRequirement
    public let installJournal: RootArtifactRequirement
    public let uninstallJournal: RootArtifactRequirement
    public let operationClaim: RootArtifactRequirement
    public let timeoutSeconds: Int
    public let pollMilliseconds: Int

    public init(
        relativePath: String,
        identifier: String,
        version: String,
        sha256: String,
        controllerBuildID: String,
        controllerQuarantinePath: String,
        runnerQuarantinePath: String,
        runner: RootArtifactRequirement,
        controller: RootArtifactRequirement,
        attestation: RootArtifactRequirement,
        installJournal: RootArtifactRequirement,
        uninstallJournal: RootArtifactRequirement,
        operationClaim: RootArtifactRequirement,
        timeoutSeconds: Int,
        pollMilliseconds: Int
    ) {
        self.relativePath = relativePath
        self.identifier = identifier
        self.version = version
        self.sha256 = sha256.lowercased()
        self.controllerBuildID = controllerBuildID
        self.controllerQuarantinePath = controllerQuarantinePath
        self.runnerQuarantinePath = runnerQuarantinePath
        self.runner = runner
        self.controller = controller
        self.attestation = attestation
        self.installJournal = installJournal
        self.uninstallJournal = uninstallJournal
        self.operationClaim = operationClaim
        self.timeoutSeconds = timeoutSeconds
        self.pollMilliseconds = pollMilliseconds
    }

    fileprivate func validateShape() throws {
        guard relativePath == "Controller/PlayCoverVRChatMemoryPolicy.pkg",
              identifier ==
                "io.github.northstarxyzz.pcvrpatcher.memory-policy",
              version == "0.1.0",
              AppIdentity.isSHA256(sha256),
              controllerBuildID ==
                "capability-vrchat-2026.2.30300-1365-r7",
              controllerQuarantinePath ==
                "/usr/local/libexec/playcover-vrchat-memory-policy/.controller.pcvr-install",
              runnerQuarantinePath ==
                "/usr/local/bin/.playcover-vrchat-memory-policy.pcvr-install",
              timeoutSeconds == 900,
              pollMilliseconds == 500 else {
            throw PatcherError.invalidManifest(
                "unexpected controller package identity or timing bounds"
            )
        }
        try runner.validateShape(
            label: "controllerPackage.runner",
            requiredPath: "/usr/local/bin/playcover-vrchat-memory-policy",
            requiredMode: "0555"
        )
        try controller.validateShape(
            label: "controllerPackage.controller",
            requiredPath:
                "/usr/local/libexec/playcover-vrchat-memory-policy/controller",
            requiredMode: "0500"
        )
        try attestation.validateShape(
            label: "controllerPackage.attestation",
            requiredPath:
                "/usr/local/libexec/playcover-vrchat-memory-policy/installation.json",
            requiredMode: "0444"
        )
        try uninstallJournal.validateShape(
            label: "controllerPackage.uninstallJournal",
            requiredPath:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.uninstall",
            requiredMode: "0400"
        )
        try installJournal.validateShape(
            label: "controllerPackage.installJournal",
            requiredPath:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.install",
            requiredMode: "0400"
        )
        try operationClaim.validateShape(
            label: "controllerPackage.operationClaim",
            requiredPath:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.operation",
            requiredMode: "0400"
        )
    }
}

public struct RootArtifactRequirement: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let uid: UInt32
    public let gid: UInt32
    public let mode: String
    public let linkCount: UInt32

    public init(
        path: String,
        sha256: String,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mode: String,
        linkCount: UInt32 = 1
    ) {
        self.path = path
        self.sha256 = sha256.lowercased()
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.linkCount = linkCount
    }

    public var numericMode: UInt16? {
        UInt16(mode, radix: 8)
    }

    fileprivate func validateShape(
        label: String,
        requiredPath: String,
        requiredMode: String
    ) throws {
        guard path == requiredPath,
              AppIdentity.isSHA256(sha256),
              uid == 0,
              gid == 0,
              mode == requiredMode,
              numericMode != nil,
              linkCount == 1 else {
            throw PatcherError.invalidManifest("invalid \(label)")
        }
    }
}

public struct AppIdentity: Codable, Sendable, Equatable {
    public let repository: String?
    public let commit: String?
    public let bundleIdentifier: String
    public let shortVersion: String
    public let buildVersion: String
    public let executableName: String
    public let executableSHA256: String
    public let executableUUID: String
    public let treeSHA256: String
    public let infoPlistSHA256: String?
    public let codeResourcesSHA256: String?

    public init(
        bundleIdentifier: String,
        shortVersion: String,
        buildVersion: String,
        executableName: String,
        executableSHA256: String,
        executableUUID: String,
        treeSHA256: String,
        repository: String? = nil,
        commit: String? = nil,
        infoPlistSHA256: String? = nil,
        codeResourcesSHA256: String? = nil
    ) {
        self.repository = repository
        self.commit = commit
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.executableName = executableName
        self.executableSHA256 = executableSHA256.lowercased()
        self.executableUUID = executableUUID.uppercased()
        self.treeSHA256 = treeSHA256.lowercased()
        self.infoPlistSHA256 = infoPlistSHA256?.lowercased()
        self.codeResourcesSHA256 = codeResourcesSHA256?.lowercased()
    }

    fileprivate func validateShape(label: String) throws {
        guard !bundleIdentifier.isEmpty,
              !shortVersion.isEmpty,
              !buildVersion.isEmpty,
              !executableName.isEmpty,
              !executableName.contains("/") else {
            throw PatcherError.invalidManifest("invalid \(label) metadata")
        }
        guard Self.isSHA256(executableSHA256),
              Self.isSHA256(treeSHA256) else {
            throw PatcherError.invalidManifest("invalid \(label) SHA-256")
        }
        guard UUID(uuidString: executableUUID) != nil else {
            throw PatcherError.invalidManifest("invalid \(label) Mach-O UUID")
        }
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

public struct HostRequirement: Codable, Sendable, Equatable {
    public let productVersion: String
    public let buildVersion: String
    public let xnuVersion: String

    public init(productVersion: String, buildVersion: String, xnuVersion: String) {
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.xnuVersion = xnuVersion
    }
}

public enum MemoryPolicyMode: String, Codable, Sendable, Equatable {
    case automatic75Percent
}

public struct MemoryPolicy: Codable, Sendable, Equatable {
    public let mode: MemoryPolicyMode
    public let minGiB: UInt16
    public let maxPhysicalPercent: UInt8
    public let stepGiB: UInt16
    public let waitSeconds: UInt64
    public let fatal: Bool

    public init(
        mode: MemoryPolicyMode,
        minGiB: UInt16,
        maxPhysicalPercent: UInt8,
        stepGiB: UInt16,
        waitSeconds: UInt64,
        fatal: Bool
    ) {
        self.mode = mode
        self.minGiB = minGiB
        self.maxPhysicalPercent = maxPhysicalPercent
        self.stepGiB = stepGiB
        self.waitSeconds = waitSeconds
        self.fatal = fatal
    }

    private enum CodingKeys: String, CodingKey {
        case mode = "defaultMode"
        case minGiB = "minimumGiB"
        case maxPhysicalPercent = "maximumPhysicalMemoryPercent"
        case stepGiB
        case waitSeconds
        case fatal
    }
}

public struct IPCRequirement: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let socketPath: String

    public init(protocolVersion: Int, socketPath: String) {
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
    }
}

public struct RuntimeSnapshot: Sendable, Equatable {
    public let macOSVersion: String
    public let macOSBuild: String
    public let xnuVersion: String
    public let architecture: String
    public let physicalMemoryBytes: UInt64

    public init(
        macOSVersion: String,
        macOSBuild: String,
        xnuVersion: String,
        architecture: String,
        physicalMemoryBytes: UInt64
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.xnuVersion = xnuVersion
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public enum InspectionState: Sendable, Equatable {
    case originalMissing
    case vrChatMissing(URL)
    case readyToCreate
    case controllerSetupRequired(ControllerSetupReason)
    case fullyPatched
    case repairRequired(TransactionPhase)
    case unsupportedRuntime([String])
    case busy([String])
    case unknownModification(String)
    case payloadUnavailable
}

public struct Inspection: Sendable, Equatable {
    public let state: InspectionState
    public let originalApp: URL
    public let patchedApp: URL
    public let patchID: String

    public init(
        state: InspectionState,
        originalApp: URL,
        patchedApp: URL,
        patchID: String
    ) {
        self.state = state
        self.originalApp = originalApp
        self.patchedApp = patchedApp
        self.patchID = patchID
    }
}

public enum TransactionPhase: String, Codable, Sendable, Equatable {
    case preparing
    case importingVRChat
    case vrChatImported
    case migratingConfiguration
    case configurationMigrated
    case appStaged
    case appPublished
    case controllerSetupRequired
    case installingController
    case controllerSetupVerified
    case uninstallingController
    case removalStaged
    case verified
}

public enum ControllerSetupReason: String, Codable, Sendable, Equatable {
    case notInstalled
    case knownUpgradeRequired
    case installationCancelled
    case installationFailed
    case installationTimedOut
    case verificationRequired
}

public struct ControllerInstallationEvidence: Codable, Sendable, Equatable {
    public let controllerBuildID: String
    public let packageIdentifier: String
    public let packageVersion: String
    public let runnerSHA256: String
    public let attestationSHA256: String

    public init(
        controllerBuildID: String,
        packageIdentifier: String,
        packageVersion: String,
        runnerSHA256: String,
        attestationSHA256: String
    ) {
        self.controllerBuildID = controllerBuildID
        self.packageIdentifier = packageIdentifier
        self.packageVersion = packageVersion
        self.runnerSHA256 = runnerSHA256.lowercased()
        self.attestationSHA256 = attestationSHA256.lowercased()
    }

    public func matches(_ requirement: ControllerPackageRequirement) -> Bool {
        controllerBuildID == requirement.controllerBuildID &&
            packageIdentifier == requirement.identifier &&
            packageVersion == requirement.version &&
            runnerSHA256.caseInsensitiveCompare(
                requirement.runner.sha256
            ) == .orderedSame &&
            attestationSHA256.caseInsensitiveCompare(
                requirement.attestation.sha256
            ) == .orderedSame
    }
}

public enum VRChatImportStrategy: String, Codable, Sendable, Equatable {
    case clone
    case copyFallback
    case existingVerified
}

public struct PatchReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let patchID: String
    public let installedAt: Date
    public let originalTreeSHA256: String
    public let patchedTreeSHA256: String
    public let importStrategy: VRChatImportStrategy
    public let controllerInstallation: ControllerInstallationEvidence

    public init(
        patchID: String,
        installedAt: Date,
        originalTreeSHA256: String,
        patchedTreeSHA256: String,
        importStrategy: VRChatImportStrategy,
        controllerInstallation: ControllerInstallationEvidence
    ) {
        schemaVersion = 4
        self.patchID = patchID
        self.installedAt = installedAt
        self.originalTreeSHA256 = originalTreeSHA256.lowercased()
        self.patchedTreeSHA256 = patchedTreeSHA256.lowercased()
        self.importStrategy = importStrategy
        self.controllerInstallation = controllerInstallation
    }
}

public enum PatcherOperation: String, Codable, Sendable {
    case inspect
    case createPatchedCopy
    case repair
    case removePatchedCopy
}

public struct OperationResult: Sendable, Equatable {
    public let operation: PatcherOperation
    public let inspection: Inspection
    public let importedVRChatURL: URL?
    public let importStrategy: VRChatImportStrategy?

    public init(
        operation: PatcherOperation,
        inspection: Inspection,
        importedVRChatURL: URL? = nil,
        importStrategy: VRChatImportStrategy? = nil
    ) {
        self.operation = operation
        self.inspection = inspection
        self.importedVRChatURL = importedVRChatURL
        self.importStrategy = importStrategy
    }
}

public enum PatcherError: LocalizedError, Sendable, Equatable {
    case unsupportedManifestSchema(Int)
    case invalidManifest(String)
    case unsupportedRuntime([String])
    case applicationsRunning([String])
    case targetMissing(URL)
    case payloadMissing(URL)
    case vrChatMissing(URL)
    case vrChatConfigurationMissing(URL)
    case identityMismatch(expected: String, actual: String)
    case unknownModification(String)
    case invalidOperation(String)
    case unsafePath(URL)
    case transactionFailed(String)
    case hardLinkDetected(String)
    case payloadUnavailable
    case controllerSetupRequired(ControllerSetupReason)
    case controllerSetupCancelled
    case controllerSetupTimedOut
    case controllerSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedManifestSchema(let version):
            "Unsupported manifest schema \(version)."
        case .invalidManifest(let reason):
            "Invalid compatibility manifest: \(reason)"
        case .unsupportedRuntime(let reasons):
            "Unsupported runtime: \(reasons.joined(separator: ", "))"
        case .applicationsRunning(let names):
            "Quit these applications before continuing: \(names.joined(separator: ", "))."
        case .targetMissing(let url):
            "The required application was not found at \(url.path)."
        case .payloadMissing(let url):
            "The patched PlayCover payload was not found at \(url.path)."
        case .vrChatMissing(let url):
            "VRChat was not found at \(url.path)."
        case .vrChatConfigurationMissing(let url):
            "Required VRChat configuration was not found at \(url.path)."
        case .identityMismatch(let expected, let actual):
            "Identity mismatch; expected \(expected), got \(actual)."
        case .unknownModification(let reason):
            "Unknown installation state: \(reason)"
        case .invalidOperation(let reason):
            "Operation is not allowed: \(reason)"
        case .unsafePath(let url):
            "Refusing unsafe path: \(url.path)"
        case .transactionFailed(let reason):
            "Patch transaction failed: \(reason)"
        case .hardLinkDetected(let relativePath):
            "The imported game contains a forbidden hard link at \(relativePath)."
        case .payloadUnavailable:
            "The reviewed patched PlayCover payload is not included in this build."
        case .controllerSetupRequired(let reason):
            "The memory-policy controller setup is required (\(reason.rawValue))."
        case .controllerSetupCancelled:
            "Controller setup was cancelled; Repair can resume it safely."
        case .controllerSetupTimedOut:
            "Controller setup did not verify within 900 seconds; Repair can retry it."
        case .controllerSetupFailed(let reason):
            "Controller setup failed safely: \(reason)"
        }
    }
}
