import Darwin
import Foundation

public struct PatcherPaths: Sendable, Equatable {
    public let originalApp: URL
    public let patchedApp: URL
    public let patchedPayload: URL
    public let controllerPackage: URL
    public let applicationSupport: URL
    public let originalLibrary: URL
    public let patchedLibrary: URL

    public init(
        originalApp: URL,
        patchedApp: URL,
        patchedPayload: URL,
        controllerPackage: URL,
        applicationSupport: URL,
        originalLibrary: URL,
        patchedLibrary: URL
    ) {
        self.originalApp = Self.lexicalURL(originalApp)
        self.patchedApp = Self.lexicalURL(patchedApp)
        self.patchedPayload = Self.lexicalURL(patchedPayload)
        self.controllerPackage = Self.lexicalURL(controllerPackage)
        self.applicationSupport = Self.lexicalURL(applicationSupport)
        self.originalLibrary = Self.lexicalURL(originalLibrary)
        self.patchedLibrary = Self.lexicalURL(patchedLibrary)
    }

    public static func defaults(
        originalApp: URL = URL(
            fileURLWithPath: "/Applications/PlayCover.app",
            isDirectory: true
        ),
        payload: URL,
        controllerPackage: URL
    ) -> PatcherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PatcherPaths(
            originalApp: originalApp,
            patchedApp: URL(
                fileURLWithPath: "/Applications/PlayCover VRChat.app",
                isDirectory: true
            ),
            patchedPayload: payload,
            controllerPackage: controllerPackage,
            applicationSupport: home.appendingPathComponent(
                "Library/Application Support/PlayCover VRChat Patcher",
                isDirectory: true
            ),
            originalLibrary: home.appendingPathComponent(
                "Library/Containers/io.playcover.PlayCover",
                isDirectory: true
            ),
            patchedLibrary: home.appendingPathComponent(
                "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat",
                isDirectory: true
            )
        )
    }

    private static func lexicalURL(_ input: URL) -> URL {
        URL(
            fileURLWithPath: input.path,
            isDirectory: input.hasDirectoryPath
        )
    }
}

private struct TransactionJournal: Codable, Sendable {
    let schemaVersion: Int
    let patchID: String
    let operation: PatcherOperation
    var phase: TransactionPhase
    let originalAppPath: String
    let patchedAppPath: String
    let payloadPath: String
    let appStagingPath: String
    let removalStagingPath: String
    let vrChatSourcePath: String
    let vrChatDestinationPath: String
    let vrChatStagingPath: String
    let configurationStagingPath: String
    var importStrategy: VRChatImportStrategy?
    var configurationSHA256: String?
    var controllerSetupReason: ControllerSetupReason?
    var controllerInstallation: ControllerInstallationEvidence?
    var appStagingBinding: SecureNodeBinding?
    var removalStagingBinding: SecureNodeBinding?
    var vrChatStagingBinding: SecureNodeBinding?
    var configurationStagingBinding: SecureNodeBinding?
}

private struct LegacyPatchReceiptV3: Codable, Sendable {
    let schemaVersion: Int
    let patchID: String
    let installedAt: Date
    let originalTreeSHA256: String
    let patchedTreeSHA256: String
    let importedVRChatTreeSHA256: String
    let configurationSHA256: String
    let importStrategy: VRChatImportStrategy
}

private enum StoredPatchReceipt: Sendable {
    case current(PatchReceipt)
    case legacyV3(LegacyPatchReceiptV3)

    var importStrategy: VRChatImportStrategy {
        switch self {
        case .current(let receipt): receipt.importStrategy
        case .legacyV3(let receipt): receipt.importStrategy
        }
    }
}

public actor PatcherEngine {
    private let manifest: CompatibilityManifest
    private let paths: PatcherPaths
    private let verifier: any TreeVerifying
    private let vrChatVerifier: any VRChatVerifying
    private let importer: any VRChatTreeImporting
    private let configurationMigrator: any VRChatConfigurationMigrating
    private let runtimeProvider: any RuntimeProviding
    private let processInspector: any ProcessInspecting
    private let controllerSetupProvider: any ControllerSetupProviding
    private let fileManager: FileManager

    public init(
        manifest: CompatibilityManifest,
        paths: PatcherPaths,
        verifier: any TreeVerifying = AppTreeVerifier(),
        vrChatVerifier: any VRChatVerifying = VRChatAppVerifier(),
        importer: any VRChatTreeImporting = CloneFirstVRChatImporter(),
        configurationMigrator: any VRChatConfigurationMigrating =
            SelectiveVRChatConfigurationMigrator(),
        runtimeProvider: any RuntimeProviding = SystemRuntimeProvider(),
        processInspector: any ProcessInspecting = WorkspaceProcessInspector(),
        controllerSetupProvider: any ControllerSetupProviding =
            UnavailableControllerSetupProvider(),
        fileManager: FileManager = .default
    ) throws {
        try manifest.validateShape()
        self.manifest = manifest
        self.paths = paths
        self.verifier = verifier
        self.vrChatVerifier = vrChatVerifier
        self.importer = importer
        self.configurationMigrator = configurationMigrator
        self.runtimeProvider = runtimeProvider
        self.processInspector = processInspector
        self.controllerSetupProvider = controllerSetupProvider
        self.fileManager = fileManager
    }

    public static func loadManifest(from url: URL) throws -> CompatibilityManifest {
        let manifest = try JSONDecoder().decode(
            CompatibilityManifest.self,
            from: Data(contentsOf: url)
        )
        try manifest.validateShape()
        return manifest
    }

    public func inspect() async throws -> Inspection {
        try validateSafePaths()
        return try await inspectIgnoringLock()
    }

    public func createPatchedCopy() async throws -> OperationResult {
        try requireEnvironmentReady()
        let source = try requireOriginalVRChat()
        _ = try requireOriginalConfiguration()
        _ = try requireOriginalPlayCover()
        let patchedIdentity = try requirePayload()
        let initial = try await inspectIgnoringLock()
        guard initial.state == .readyToCreate else {
            throw operationError("Create Patched Copy", state: initial.state)
        }

        return try await withExclusiveTransaction {
            try requireEnvironmentReady()
            let sourceAgain = try requireOriginalVRChat()
            guard sourceAgain.treeSHA256 == source.treeSHA256 else {
                throw PatcherError.unknownModification(
                    "the original VRChat tree changed during preflight"
                )
            }
            _ = try requireOriginalConfiguration()
            _ = try requireOriginalPlayCover()
            try requireIdentity(
                paths.patchedPayload,
                expected: patchedIdentity,
                label: "patched payload"
            )
            let before = try await self.inspectIgnoringLock()
            guard before.state == .readyToCreate else {
                throw operationError("Create Patched Copy", state: before.state)
            }

            var journal = makeJournal(
                operation: .createPatchedCopy,
                phase: .preparing
            )
            try writeJournal(journal)
            let result = try await self.completeCreate(
                journal: &journal,
                sourceIdentity: sourceAgain,
                patchedIdentity: patchedIdentity
            )
            return OperationResult(
                operation: .createPatchedCopy,
                inspection: try await self.inspectIgnoringLock(),
                importedVRChatURL: vrChatDestinationURL,
                importStrategy: result.strategy
            )
        }
    }

    public func repair() async throws -> OperationResult {
        try requireEnvironmentReady()
        _ = try requireOriginalPlayCover()
        return try await withExclusiveTransaction {
            try requireEnvironmentReady()
            _ = try requireOriginalPlayCover()
            if var journal = try readJournal() {
                try validate(journal: journal)
                if journal.operation == .removePatchedCopy {
                    try await self.recoverRemove(journal)
                } else if journal.operation == .createPatchedCopy ||
                            journal.operation == .repair {
                    let source = try requireOriginalVRChat()
                    _ = try requireOriginalConfiguration()
                    let patchedIdentity = try requirePayload()
                    _ = try await self.completeCreate(
                        journal: &journal,
                        sourceIdentity: source,
                        patchedIdentity: patchedIdentity
                    )
                } else {
                    throw PatcherError.unknownModification(
                        "unsupported operation in transaction journal"
                    )
                }
            } else {
                try await self.repairWithoutJournal()
            }
            let inspection = try await self.inspectIgnoringLock()
            return OperationResult(
                operation: .repair,
                inspection: inspection,
                importedVRChatURL: fileManager.fileExists(
                    atPath: vrChatDestinationURL.path
                ) ? vrChatDestinationURL : nil,
                importStrategy: try readReceipt()?.importStrategy
            )
        }
    }

    public func removePatchedCopy() async throws -> OperationResult {
        try requireEnvironmentReady()
        return try await withExclusiveTransaction {
            try requireEnvironmentReady()
            guard try readJournal() == nil else {
                throw PatcherError.invalidOperation(
                    "Repair the interrupted transaction before removing the patched copy."
                )
            }
            let before = try await self.inspectIgnoringLock()
            guard before.state == .fullyPatched else {
                throw operationError("Remove Patched Copy", state: before.state)
            }
            let patchedIdentity = try patchedIdentity()
            try requireIdentity(
                paths.patchedApp,
                expected: patchedIdentity,
                label: "installed patched copy"
            )
            let controllerRequirement = try controllerRequirement()
            let controllerState = try await controllerSetupProvider.inspect(
                requirement: controllerRequirement
            )
            guard case .exact(let controllerEvidence) = controllerState,
                  controllerEvidence.matches(controllerRequirement) else {
                throw PatcherError.controllerSetupFailed(
                    "the exact r6 controller must be active before Remove"
                )
            }
            try requireReceipt(
                controllerInstallation: controllerEvidence
            )
            try ensureAbsent(removalStagingURL)

            var journal = makeJournal(
                operation: .removePatchedCopy,
                phase: .preparing
            )
            journal.removalStagingBinding = try SecureTreeAuditor.binding(
                for: paths.patchedApp
            )
            try writeJournal(journal)
            journal.phase = .uninstallingController
            try writeJournal(journal)
            do {
                try await controllerSetupProvider.uninstall(
                    requirement: controllerRequirement
                )
            } catch {
                // The exact app and both libraries remain in place. Repair can
                // prove whether root uninstall committed and resume safely.
                throw error
            }
            let afterUninstall = try await controllerSetupProvider.inspect(
                requirement: controllerRequirement
            )
            guard afterUninstall == .absent else {
                throw PatcherError.controllerSetupFailed(
                    "root uninstall did not prove runner, controller, attestation, journal and receipt absent"
                )
            }
            try requireNoProtectedApplications()
            guard let preRenameBinding = journal.removalStagingBinding else {
                throw PatcherError.unknownModification(
                    "removal transaction lost its identity binding"
                )
            }
            try SecureTreeAuditor.requireBinding(
                preRenameBinding,
                for: paths.patchedApp
            )
            try atomicInstallNew(paths.patchedApp, removalStagingURL)
            guard let removalBinding = journal.removalStagingBinding else {
                throw PatcherError.unknownModification(
                    "removal staging lost its journal binding"
                )
            }
            try SecureTreeAuditor.requireBinding(
                removalBinding,
                for: removalStagingURL
            )
            journal.phase = .removalStaged
            try writeJournal(journal)
            try requireIdentity(
                removalStagingURL,
                expected: patchedIdentity,
                label: "removal staging"
            )
            try removeOwnedTemporaryIfPresent(
                removalStagingURL,
                binding: journal.removalStagingBinding
            )
            journal.removalStagingBinding = nil
            journal.phase = .verified
            try writeJournal(journal)
            try removeReceiptAndJournal()
            return OperationResult(
                operation: .removePatchedCopy,
                // The retained library is intentionally mutable user data.
                // Do not turn a successful Remove into an error by inspecting
                // or hashing it afterward.
                inspection: inspection(.readyToCreate),
                importedVRChatURL: vrChatDestinationURL,
                importStrategy: .existingVerified
            )
        }
    }

    private func inspectIgnoringLock() async throws -> Inspection {
        let runtimeProblems = try runtimeMismatches()
        if !runtimeProblems.isEmpty {
            return inspection(.unsupportedRuntime(runtimeProblems))
        }
        let running = processInspector.runningProtectedApplications()
        if !running.isEmpty { return inspection(.busy(running)) }
        if let journal = try readJournal() {
            try validate(journal: journal)
            if [
                .controllerSetupRequired,
                .installingController,
                .controllerSetupVerified
            ].contains(journal.phase) {
                return inspection(.controllerSetupRequired(
                    try await controllerSetupReason(for: journal)
                ))
            }
            return inspection(.repairRequired(journal.phase))
        }

        let targetExists = nodeExists(paths.patchedApp)
        if targetExists {
            if isSymbolicLink(paths.patchedApp) {
                return inspection(.unknownModification(
                    "the parallel patched app is a symlink"
                ))
            }
            guard let expectedPatched = manifest.patchedPlayCover else {
                return inspection(.payloadUnavailable)
            }
            let actual = try verifier.identity(of: paths.patchedApp)
            if let mismatch = actual.mismatch(from: expectedPatched) {
                return inspection(.unknownModification(
                    "the parallel app is not the exact reviewed payload: \(mismatch)"
                ))
            }
            let storedReceipt: StoredPatchReceipt?
            do {
                storedReceipt = try readReceipt()
            } catch {
                return inspection(.unknownModification(
                    "the patch receipt is unsafe or unrecognized: \(error.localizedDescription)"
                ))
            }
            if let storedReceipt {
                let baseMatches: Bool
                switch storedReceipt {
                case .current(let receipt):
                    baseMatches = currentReceiptOwnershipMatches(receipt)
                case .legacyV3(let receipt):
                    baseMatches = legacyReceiptOwnershipMatches(receipt)
                }
                guard baseMatches else {
                    return inspection(.unknownModification(
                        "the patch receipt does not match the exact parallel installation"
                    ))
                }
            }
            let requirement = try controllerRequirement()
            let controllerState = try await controllerSetupProvider.inspect(
                requirement: requirement
            )
            let evidence: ControllerInstallationEvidence
            switch controllerState {
            case .absent:
                return inspection(.controllerSetupRequired(.notInstalled))
            case .knownUpgradeRequired:
                return inspection(.controllerSetupRequired(
                    .knownUpgradeRequired
                ))
            case .uninstalling, .uninstallingActive:
                return inspection(.controllerSetupRequired(
                    .verificationRequired
                ))
            case .uninstallFinalizationRepairRequired:
                return inspection(.unknownModification(
                    "a stale final uninstall claim exists outside a recoverable Remove transaction"
                ))
            case .installing:
                return inspection(.controllerSetupRequired(
                    .verificationRequired
                ))
            case .unknown(let reason):
                return inspection(.unknownModification(
                    "the controller installation is unknown: \(reason)"
                ))
            case .exact(let installedEvidence):
                evidence = installedEvidence
            }
            guard let storedReceipt else {
                return inspection(.repairRequired(.verified))
            }
            switch storedReceipt {
            case .current(let receipt):
                guard receiptMatches(
                    receipt,
                    controllerInstallation: evidence
                ) else {
                    return inspection(.unknownModification(
                        "the patch receipt does not match the installed parallel copy"
                    ))
                }
            case .legacyV3(let receipt):
                _ = receipt
                return inspection(.controllerSetupRequired(
                    .verificationRequired
                ))
            }
            return inspection(.fullyPatched)
        }

        guard nodeExists(paths.originalApp) else {
            return inspection(.originalMissing)
        }
        if isSymbolicLink(paths.originalApp) {
            return inspection(.unknownModification("the original app is a symlink"))
        }
        let original = try verifier.identity(of: paths.originalApp)
        if let mismatch = original.mismatch(from: manifest.playCover) {
            return inspection(.unknownModification(
                "the original PlayCover is not the reviewed build: \(mismatch)"
            ))
        }

        if nodeExists(removalStagingURL) || nodeExists(appStagingURL) ||
            nodeExists(configurationStagingURL) {
            return inspection(.unknownModification(
                "an owned staging path exists without a matching transaction journal"
            ))
        }
        if nodeExists(receiptURL) {
            return inspection(.repairRequired(.verified))
        }
        guard nodeExists(vrChatSourceURL) else {
            return inspection(.vrChatMissing(vrChatSourceURL))
        }
        if isSymbolicLink(vrChatSourceURL) {
            return inspection(.unknownModification(
                "the original VRChat app is a symlink"
            ))
        }
        do {
            try VRChatArtifactScanner.verifyClean(vrChatSourceURL)
        } catch {
            return inspection(.unknownModification(error.localizedDescription))
        }
        let source = try vrChatVerifier.identity(
            of: vrChatSourceURL,
            expected: manifest.vrChat
        )
        if let mismatch = source.mismatch(from: manifest.vrChat) {
            return inspection(.unknownModification(
                "the original VRChat installation is unsupported: \(mismatch)"
            ))
        }
        do {
            _ = try requireOriginalConfiguration()
        } catch {
            return inspection(.unknownModification(error.localizedDescription))
        }
        if nodeExists(vrChatDestinationURL) {
            if isSymbolicLink(vrChatDestinationURL) {
                return inspection(.unknownModification(
                    "the independent VRChat copy is a symlink"
                ))
            }
            do {
                try VRChatArtifactScanner.verifyClean(vrChatDestinationURL)
            } catch {
                return inspection(.unknownModification(error.localizedDescription))
            }
            let imported = try vrChatVerifier.identity(
                of: vrChatDestinationURL,
                expected: manifest.vrChat
            )
            if let mismatch = imported.mismatch(from: manifest.vrChat) {
                return inspection(.unknownModification(
                    "the retained independent VRChat copy is unknown: \(mismatch)"
                ))
            }
            do {
                try requireIndependentTree(imported, matches: source)
            } catch {
                return inspection(.unknownModification(
                    "the retained independent VRChat copy differs from the original: \(error.localizedDescription)"
                ))
            }
        }
        do {
            switch try configurationMigrator.inspectConfiguration(
                at: paths.patchedLibrary,
                destinationLibrary: paths.patchedLibrary
            ) {
            case .absent, .complete:
                break
            case .partial:
                return inspection(.unknownModification(
                    "the retained independent VRChat configuration is incomplete"
                ))
            }
        } catch {
            return inspection(.unknownModification(
                "the retained independent VRChat configuration is unsafe: \(error.localizedDescription)"
            ))
        }
        guard manifest.patchedPlayCover != nil,
              manifest.controllerPackage != nil,
              nodeExists(paths.patchedPayload),
              nodeExists(paths.controllerPackage) else {
            return inspection(.payloadUnavailable)
        }
        let payload = try verifier.identity(of: paths.patchedPayload)
        if let mismatch = payload.mismatch(from: try patchedIdentity()) {
            return inspection(.unknownModification(
                "the embedded patched payload is unknown: \(mismatch)"
            ))
        }
        _ = try ControllerPackageVerifier.verify(
            paths.controllerPackage,
            requirement: try controllerRequirement()
        )
        return inspection(.readyToCreate)
    }

    private func completeCreate(
        journal: inout TransactionJournal,
        sourceIdentity: ObservedVRChatIdentity,
        patchedIdentity: AppIdentity
    ) async throws -> (
        strategy: VRChatImportStrategy,
        imported: ObservedVRChatIdentity
    ) {
        let importedResult = try ensureVRChatImported(
            journal: &journal,
            sourceIdentity: sourceIdentity
        )
        let strategy = importedResult.strategy
        let configuration = try ensureConfigurationMigrated(journal: &journal)

        if nodeExists(paths.patchedApp) {
            try requireIdentity(
                paths.patchedApp,
                expected: patchedIdentity,
                label: "installed parallel app"
            )
            try removeOwnedTemporaryIfPresent(
                appStagingURL,
                binding: journal.appStagingBinding
            )
            journal.appStagingBinding = nil
            try writeJournal(journal)
        } else {
            try prepareAppStaging(
                expected: patchedIdentity,
                journal: &journal
            )
            journal.phase = .appStaged
            journal.importStrategy = strategy
            try writeJournal(journal)
            try requireNoProtectedApplications()
            guard let appBinding = journal.appStagingBinding else {
                throw PatcherError.unknownModification(
                    "staged payload lost its journal binding"
                )
            }
            try SecureTreeAuditor.requireBinding(
                appBinding,
                for: appStagingURL
            )
            try atomicInstallNew(appStagingURL, paths.patchedApp)
            try SecureTreeAuditor.requireBinding(
                appBinding,
                for: paths.patchedApp
            )
            journal.appStagingBinding = nil
            journal.phase = .appPublished
            try writeJournal(journal)
            try requireIdentity(
                paths.patchedApp,
                expected: patchedIdentity,
                label: "installed parallel app"
            )
        }

        _ = try requireOriginalPlayCover()
        let sourceAfter = try requireOriginalVRChat()
        guard sourceAfter.treeSHA256 == sourceIdentity.treeSHA256 else {
            throw PatcherError.unknownModification(
                "the original VRChat tree changed during import"
            )
        }
        let importedAfter = try requireImportedVRChat()
        guard importedAfter.treeSHA256 == sourceIdentity.treeSHA256 else {
            throw PatcherError.identityMismatch(
                expected: "imported VRChat tree \(sourceIdentity.treeSHA256)",
                actual: importedAfter.treeSHA256
            )
        }
        try CloneFirstVRChatImporter.rejectHardLinks(
            from: vrChatSourceURL,
            to: vrChatDestinationURL
        )
        let controllerInstallation = try await ensureControllerInstalled(
            journal: &journal
        )
        journal.controllerInstallation = controllerInstallation
        journal.controllerSetupReason = nil
        journal.phase = .controllerSetupVerified
        try writeJournal(journal)
        journal.phase = .verified
        try writeJournal(journal)
        try writeReceipt(
            importedTreeSHA256: importedAfter.treeSHA256,
            configurationSHA256: configuration.sha256,
            strategy: strategy,
            controllerInstallation: controllerInstallation
        )
        try removeOwnedTemporaryIfPresent(
            appStagingURL,
            binding: journal.appStagingBinding
        )
        try removeOwnedTemporaryIfPresent(
            vrChatStagingURL,
            binding: journal.vrChatStagingBinding
        )
        try removeOwnedTemporaryIfPresent(
            configurationStagingURL,
            binding: journal.configurationStagingBinding
        )
        try SecureFileSystem.unlinkRegularFileIfPresent(journalURL)
        return (strategy, importedAfter)
    }

    private func ensureControllerInstalled(
        journal: inout TransactionJournal
    ) async throws -> ControllerInstallationEvidence {
        let requirement = try controllerRequirement()
        let request = ControllerSetupRequest(
            requirement: requirement,
            packageURL: paths.controllerPackage
        )
        _ = try ControllerPackageVerifier.verify(
            paths.controllerPackage,
            requirement: requirement
        )

        let initial = try await controllerSetupProvider.inspect(
            requirement: requirement
        )
        if case .exact(let evidence) = initial {
            guard evidence.matches(requirement) else {
                throw PatcherError.unknownModification(
                    "the controller provider returned mismatched evidence"
                )
            }
            return evidence
        }

        switch initial {
        case .absent:
            journal.controllerSetupReason = .notInstalled
        case .knownUpgradeRequired:
            journal.controllerSetupReason = .knownUpgradeRequired
        case .installing:
            journal.controllerSetupReason = .verificationRequired
        case .uninstalling, .uninstallingActive,
             .uninstallFinalizationRepairRequired:
            throw PatcherError.controllerSetupFailed(
                "a root controller uninstall transaction is still active"
            )
        case .unknown(let reason):
            throw PatcherError.unknownModification(
                "the root controller state is unknown: \(reason)"
            )
        case .exact:
            preconditionFailure("handled above")
        }

        journal.phase = .controllerSetupRequired
        try writeJournal(journal)
        journal.phase = .installingController
        try writeJournal(journal)
        do {
            try await controllerSetupProvider.install(request)
        } catch {
            journal.phase = .controllerSetupRequired
            switch error {
            case PatcherError.controllerSetupCancelled:
                journal.controllerSetupReason = .installationCancelled
            case PatcherError.controllerSetupTimedOut:
                journal.controllerSetupReason = .installationTimedOut
            default:
                journal.controllerSetupReason = .installationFailed
            }
            try writeJournal(journal)
            throw error
        }

        let verified = try await controllerSetupProvider.inspect(
            requirement: requirement
        )
        guard case .exact(let evidence) = verified,
              evidence.matches(requirement) else {
            journal.phase = .controllerSetupRequired
            journal.controllerSetupReason = .verificationRequired
            try writeJournal(journal)
            throw PatcherError.controllerSetupFailed(
                "Installer exited without an exact r6 postinstall proof"
            )
        }
        return evidence
    }

    private func ensureVRChatImported(
        journal: inout TransactionJournal,
        sourceIdentity: ObservedVRChatIdentity
    ) throws -> (strategy: VRChatImportStrategy, imported: ObservedVRChatIdentity) {
        if nodeExists(vrChatDestinationURL) {
            let imported = try requireImportedVRChat()
            guard imported.treeSHA256 == sourceIdentity.treeSHA256 else {
                throw PatcherError.unknownModification(
                    "the retained independent VRChat tree differs from the reviewed source"
                )
            }
            try CloneFirstVRChatImporter.rejectHardLinks(
                from: vrChatSourceURL,
                to: vrChatDestinationURL
            )
            try removeOwnedTemporaryIfPresent(
                vrChatStagingURL,
                binding: journal.vrChatStagingBinding
            )
            journal.vrChatStagingBinding = nil
            journal.phase = .vrChatImported
            journal.importStrategy = .existingVerified
            try writeJournal(journal)
            return (.existingVerified, imported)
        }

        try SecureFileSystem.createDirectories(
            vrChatDestinationURL.deletingLastPathComponent()
        )
        journal.phase = .importingVRChat
        try writeJournal(journal)

        var strategy = journal.importStrategy
        if nodeExists(vrChatStagingURL) {
            do {
                guard let binding = journal.vrChatStagingBinding else {
                    throw PatcherError.unknownModification(
                        "VRChat staging exists without a journal binding"
                    )
                }
                try SecureTreeAuditor.requireBinding(
                    binding,
                    for: vrChatStagingURL
                )
                let staged = try requireVRChat(
                    at: vrChatStagingURL,
                    label: "staged VRChat"
                )
                guard staged.treeSHA256 == sourceIdentity.treeSHA256 else {
                    throw PatcherError.identityMismatch(
                        expected: sourceIdentity.treeSHA256,
                        actual: staged.treeSHA256
                    )
                }
                try CloneFirstVRChatImporter.rejectHardLinks(
                    from: vrChatSourceURL,
                    to: vrChatStagingURL
                )
            } catch {
                try removeOwnedTemporaryIfPresent(
                    vrChatStagingURL,
                    binding: journal.vrChatStagingBinding
                )
                journal.vrChatStagingBinding = nil
                try writeJournal(journal)
                strategy = nil
            }
        }
        if !nodeExists(vrChatStagingURL) {
            do {
                strategy = try importer.copyTree(
                    from: vrChatSourceURL,
                    to: vrChatStagingURL
                )
            } catch {
                if nodeExists(vrChatStagingURL) {
                    journal.vrChatStagingBinding =
                        try SecureTreeAuditor.binding(for: vrChatStagingURL)
                    try writeJournal(journal)
                }
                throw error
            }
            journal.vrChatStagingBinding = try SecureTreeAuditor.binding(
                for: vrChatStagingURL
            )
            try writeJournal(journal)
            let staged = try requireVRChat(
                at: vrChatStagingURL,
                label: "staged VRChat"
            )
            guard staged.treeSHA256 == sourceIdentity.treeSHA256 else {
                throw PatcherError.identityMismatch(
                    expected: sourceIdentity.treeSHA256,
                    actual: staged.treeSHA256
                )
            }
            try CloneFirstVRChatImporter.rejectHardLinks(
                from: vrChatSourceURL,
                to: vrChatStagingURL
            )
        }
        try requireSameVolume(
            vrChatStagingURL,
            vrChatDestinationURL.deletingLastPathComponent()
        )
        try requireNoProtectedApplications()
        guard let stagingBinding = journal.vrChatStagingBinding else {
            throw PatcherError.unknownModification(
                "VRChat staging lost its journal binding"
            )
        }
        try SecureTreeAuditor.requireBinding(
            stagingBinding,
            for: vrChatStagingURL
        )
        try atomicInstallNew(vrChatStagingURL, vrChatDestinationURL)
        try SecureTreeAuditor.requireBinding(
            stagingBinding,
            for: vrChatDestinationURL
        )
        journal.vrChatStagingBinding = nil
        let imported = try requireImportedVRChat()
        guard imported.treeSHA256 == sourceIdentity.treeSHA256 else {
            throw PatcherError.identityMismatch(
                expected: sourceIdentity.treeSHA256,
                actual: imported.treeSHA256
            )
        }
        journal.phase = .vrChatImported
        journal.importStrategy = strategy ?? .copyFallback
        try writeJournal(journal)
        return (journal.importStrategy ?? .copyFallback, imported)
    }

    private func ensureConfigurationMigrated(
        journal: inout TransactionJournal
    ) throws -> VRChatConfigurationIdentity {
        switch try configurationMigrator.inspectConfiguration(
            at: paths.patchedLibrary,
            destinationLibrary: paths.patchedLibrary
        ) {
        case .complete(let identity):
            try removeOwnedTemporaryIfPresent(
                configurationStagingURL,
                binding: journal.configurationStagingBinding
            )
            journal.configurationStagingBinding = nil
            journal.phase = .configurationMigrated
            journal.configurationSHA256 = identity.sha256
            try writeJournal(journal)
            return identity
        case .absent, .partial:
            break
        }

        journal.phase = .migratingConfiguration
        journal.configurationSHA256 = nil
        try writeJournal(journal)
        try removeOwnedTemporaryIfPresent(
            configurationStagingURL,
            binding: journal.configurationStagingBinding
        )
        journal.configurationStagingBinding = nil
        try writeJournal(journal)
        let stagedIdentity: VRChatConfigurationIdentity
        do {
            stagedIdentity = try configurationMigrator.stageConfiguration(
                from: paths.originalLibrary,
                to: configurationStagingURL,
                destinationLibrary: paths.patchedLibrary
            )
        } catch {
            if nodeExists(configurationStagingURL) {
                journal.configurationStagingBinding =
                    try SecureTreeAuditor.binding(
                        for: configurationStagingURL
                    )
                try writeJournal(journal)
            }
            throw error
        }
        journal.configurationStagingBinding = try SecureTreeAuditor.binding(
            for: configurationStagingURL
        )
        try writeJournal(journal)

        for relativePath in
            SelectiveVRChatConfigurationMigrator.publishedRelativePaths {
            let staged = configurationStagingURL.appendingPathComponent(
                relativePath
            )
            let destination = paths.patchedLibrary.appendingPathComponent(
                relativePath
            )
            if nodeExists(destination) {
                guard try configurationNodesMatch(staged, destination) else {
                    throw PatcherError.unknownModification(
                        "an existing independent configuration unit differs from the interrupted migration: \(relativePath)"
                    )
                }
                continue
            }
            try SecureFileSystem.createDirectories(
                destination.deletingLastPathComponent()
            )
            try requireSameVolume(
                staged,
                destination.deletingLastPathComponent()
            )
            try requireNoProtectedApplications()
            guard let binding = journal.configurationStagingBinding else {
                throw PatcherError.unknownModification(
                    "configuration staging lost its journal binding"
                )
            }
            try SecureTreeAuditor.requireBinding(
                binding,
                for: configurationStagingURL
            )
            try atomicInstallNew(staged, destination)
            journal.configurationStagingBinding = try refreshedBinding(
                for: configurationStagingURL,
                previous: binding
            )
            try writeJournal(journal)
        }

        guard case .complete(let installedIdentity) =
                try configurationMigrator.inspectConfiguration(
                    at: paths.patchedLibrary,
                    destinationLibrary: paths.patchedLibrary
                ), installedIdentity == stagedIdentity else {
            throw PatcherError.transactionFailed(
                "published VRChat configuration did not match staging"
            )
        }
        journal.phase = .configurationMigrated
        journal.configurationSHA256 = installedIdentity.sha256
        try writeJournal(journal)
        try removeOwnedTemporaryIfPresent(
            configurationStagingURL,
            binding: journal.configurationStagingBinding
        )
        journal.configurationStagingBinding = nil
        try writeJournal(journal)
        return installedIdentity
    }

    private func configurationNodesMatch(
        _ first: URL,
        _ second: URL
    ) throws -> Bool {
        guard nodeExists(first), nodeExists(second),
              !isSymbolicLink(first), !isSymbolicLink(second) else {
            return false
        }
        var firstDirectory: ObjCBool = false
        var secondDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: first.path,
            isDirectory: &firstDirectory
        ), fileManager.fileExists(
            atPath: second.path,
            isDirectory: &secondDirectory
        ), firstDirectory.boolValue == secondDirectory.boolValue else {
            return false
        }
        if firstDirectory.boolValue {
            return try AppTreeVerifier.treeSHA256(first) ==
                AppTreeVerifier.treeSHA256(second)
        }
        return try AppTreeVerifier.fileSHA256(first) ==
            AppTreeVerifier.fileSHA256(second)
    }

    private func repairWithoutJournal() async throws {
        let inspection = try await inspectIgnoringLock()
        switch inspection.state {
        case .repairRequired, .controllerSetupRequired:
            break
        default:
            throw operationError("Repair", state: inspection.state)
        }
        let patched = try patchedIdentity()
        let targetExists = nodeExists(paths.patchedApp)
        let importedExists = nodeExists(vrChatDestinationURL)

        if targetExists && importedExists {
            try requireIdentity(
                paths.patchedApp,
                expected: patched,
                label: "installed parallel app"
            )
            let imported = try requireImportedVRChat()
            let source = try requireOriginalVRChat()
            try requireIndependentTree(imported, matches: source)
            _ = try requireOriginalConfiguration()
        } else {
            _ = try requirePayload()
        }

        let source = try requireOriginalVRChat()
        _ = try requireOriginalConfiguration()
        var journal = makeJournal(operation: .repair, phase: .preparing)
        try writeJournal(journal)
        _ = try await completeCreate(
            journal: &journal,
            sourceIdentity: source,
            patchedIdentity: patched
        )
    }

    private func recoverRemove(_ journal: TransactionJournal) async throws {
        let patched = try patchedIdentity()
        let targetExists = nodeExists(paths.patchedApp)
        let stagedExists = nodeExists(removalStagingURL)
        guard let removalBinding = journal.removalStagingBinding else {
            throw PatcherError.unknownModification(
                "removal transaction has no staging identity binding"
            )
        }

        if targetExists {
            try SecureTreeAuditor.requireBinding(
                removalBinding,
                for: paths.patchedApp
            )
            try requireIdentity(
                paths.patchedApp,
                expected: patched,
                label: "installed parallel app"
            )
            guard !stagedExists else {
                throw PatcherError.unknownModification(
                    "both the patched app and removal staging exist"
                )
            }
            let requirement = try controllerRequirement()
            let controllerState = try await controllerSetupProvider.inspect(
                requirement: requirement
            )
            switch controllerState {
            case .exact:
                // Authorization was cancelled or failed before root state
                // changed. Roll the user-side journal back to fully patched.
                try SecureFileSystem.unlinkRegularFileIfPresent(journalURL)
                return
            case .uninstalling, .uninstallingActive:
                try await controllerSetupProvider.uninstall(
                    requirement: requirement
                )
                guard try await controllerSetupProvider.inspect(
                    requirement: requirement
                ) == .absent else {
                    throw PatcherError.controllerSetupFailed(
                        "recovered root uninstall did not finish cleanly"
                    )
                }
                try finalizeRecoveredInstalledAppRemoval(
                    removalBinding: removalBinding,
                    patchedIdentity: patched,
                    journal: journal
                )
                return
            case .uninstallFinalizationRepairRequired:
                try await repairFinalControllerUninstall(
                    requirement: requirement
                )
                try finalizeRecoveredInstalledAppRemoval(
                    removalBinding: removalBinding,
                    patchedIdentity: patched,
                    journal: journal
                )
                return
            case .absent:
                try finalizeRecoveredInstalledAppRemoval(
                    removalBinding: removalBinding,
                    patchedIdentity: patched,
                    journal: journal
                )
                return
            case .knownUpgradeRequired, .installing, .unknown:
                throw PatcherError.controllerSetupFailed(
                    "cannot prove whether the root uninstall committed"
                )
            }
        }
        if stagedExists {
            try SecureTreeAuditor.requireBinding(
                removalBinding,
                for: removalStagingURL
            )
            try requireIdentity(
                removalStagingURL,
                expected: patched,
                label: "interrupted removal staging"
            )
            let controllerState = try await controllerSetupProvider.inspect(
                requirement: controllerRequirement()
            )
            switch controllerState {
            case .absent:
                try removeOwnedTemporaryIfPresent(
                    removalStagingURL,
                    binding: journal.removalStagingBinding
                )
                try removeReceiptAndJournal()
                return
            case .uninstalling, .uninstallingActive:
                let requirement = try controllerRequirement()
                try await controllerSetupProvider.uninstall(
                    requirement: requirement
                )
                guard try await controllerSetupProvider.inspect(
                    requirement: requirement
                ) == .absent else {
                    throw PatcherError.controllerSetupFailed(
                        "recovered staged root uninstall did not finish cleanly"
                    )
                }
                try removeOwnedTemporaryIfPresent(
                    removalStagingURL,
                    binding: journal.removalStagingBinding
                )
                try removeReceiptAndJournal()
                return
            case .uninstallFinalizationRepairRequired:
                let requirement = try controllerRequirement()
                try await repairFinalControllerUninstall(
                    requirement: requirement
                )
                try removeOwnedTemporaryIfPresent(
                    removalStagingURL,
                    binding: journal.removalStagingBinding
                )
                try removeReceiptAndJournal()
                return
            case .exact:
                try atomicInstallNew(removalStagingURL, paths.patchedApp)
                try SecureTreeAuditor.requireBinding(
                    removalBinding,
                    for: paths.patchedApp
                )
                try requireIdentity(
                    paths.patchedApp,
                    expected: patched,
                    label: "restored parallel app"
                )
                try SecureFileSystem.unlinkRegularFileIfPresent(journalURL)
                return
            case .knownUpgradeRequired, .installing, .unknown:
                throw PatcherError.controllerSetupFailed(
                    "cannot recover staged Remove with an ambiguous root state"
                )
            }
        }

        // The exact staged app was already deleted. Finalize bookkeeping while
        // retaining the independent library, matching the user's Remove intent.
        let requirement = try controllerRequirement()
        var finalRootState = try await controllerSetupProvider.inspect(
            requirement: requirement
        )
        if finalRootState == .uninstallFinalizationRepairRequired {
            try await repairFinalControllerUninstall(
                requirement: requirement
            )
            finalRootState = try await controllerSetupProvider.inspect(
                requirement: requirement
            )
        }
        if finalRootState == .uninstalling ||
            finalRootState == .uninstallingActive {
            try await controllerSetupProvider.uninstall(
                requirement: requirement
            )
            finalRootState = try await controllerSetupProvider.inspect(
                requirement: requirement
            )
        }
        guard finalRootState == .absent else {
            throw PatcherError.controllerSetupFailed(
                "cannot finalize Remove while root controller state remains"
            )
        }
        try removeReceiptAndJournal()
    }

    private func finalizeRecoveredInstalledAppRemoval(
        removalBinding: SecureNodeBinding,
        patchedIdentity: AppIdentity,
        journal: TransactionJournal
    ) throws {
        // Root uninstall committed before interruption. Continue the durable
        // Remove intent while retaining both independent/original libraries.
        try atomicInstallNew(paths.patchedApp, removalStagingURL)
        try SecureTreeAuditor.requireBinding(
            removalBinding,
            for: removalStagingURL
        )
        try requireIdentity(
            removalStagingURL,
            expected: patchedIdentity,
            label: "recovered removal staging"
        )
        try removeOwnedTemporaryIfPresent(
            removalStagingURL,
            binding: journal.removalStagingBinding
        )
        try removeReceiptAndJournal()
    }

    /// The only automatic reinstall-during-Remove path. The caller has already
    /// validated a durable local Remove journal and the root verifier has
    /// proved that files, receipts and both root journals are absent while one
    /// exact operation claim remains stale. Installer first repairs that claim
    /// into an exact package; one ordinary authorized uninstall then finishes.
    private func repairFinalControllerUninstall(
        requirement: ControllerPackageRequirement
    ) async throws {
        guard try await controllerSetupProvider.inspect(
            requirement: requirement
        ) == .uninstallFinalizationRepairRequired else {
            throw PatcherError.controllerSetupFailed(
                "the final uninstall recovery state changed before package repair"
            )
        }
        _ = try ControllerPackageVerifier.verify(
            paths.controllerPackage,
            requirement: requirement
        )
        try await controllerSetupProvider.install(ControllerSetupRequest(
            requirement: requirement,
            packageURL: paths.controllerPackage
        ))
        let installed = try await controllerSetupProvider.inspect(
            requirement: requirement
        )
        guard case .exact(let evidence) = installed,
              evidence.matches(requirement) else {
            throw PatcherError.controllerSetupFailed(
                "Installer did not rebuild the exact controller package"
            )
        }
        try await controllerSetupProvider.uninstall(requirement: requirement)
        guard try await controllerSetupProvider.inspect(
            requirement: requirement
        ) == .absent else {
            throw PatcherError.controllerSetupFailed(
                "the repaired controller package did not uninstall cleanly"
            )
        }
    }

    private func requireEnvironmentReady() throws {
        try validateSafePaths()
        let runtimeProblems = try runtimeMismatches()
        guard runtimeProblems.isEmpty else {
            throw PatcherError.unsupportedRuntime(runtimeProblems)
        }
        try requireNoProtectedApplications()
    }

    private func requireNoProtectedApplications() throws {
        let running = processInspector.runningProtectedApplications()
        guard running.isEmpty else {
            throw PatcherError.applicationsRunning(running)
        }
    }

    private func runtimeMismatches() throws -> [String] {
        let actual = try runtimeProvider.snapshot()
        var failures: [String] = []
        if actual.macOSVersion != manifest.host.productVersion {
            failures.append(
                "macOS \(actual.macOSVersion), expected \(manifest.host.productVersion)"
            )
        }
        if actual.macOSBuild != manifest.host.buildVersion {
            failures.append(
                "build \(actual.macOSBuild), expected \(manifest.host.buildVersion)"
            )
        }
        if !actual.xnuVersion.contains(manifest.host.xnuVersion) {
            failures.append("unexpected XNU")
        }
        if actual.architecture != manifest.architecture {
            failures.append("architecture \(actual.architecture)")
        }
        let safeBytes = actual.physicalMemoryBytes / 100 *
            UInt64(manifest.policy.maxPhysicalPercent) +
            actual.physicalMemoryBytes % 100 *
            UInt64(manifest.policy.maxPhysicalPercent) / 100
        let safeGiB = safeBytes / 1_073_741_824
        if safeGiB < UInt64(manifest.policy.minGiB) {
            failures.append(
                "the 75% memory-policy ceiling is below \(manifest.policy.minGiB) GiB"
            )
        }
        return failures
    }

    private func validateSafePaths() throws {
        let bases = [
            paths.originalApp,
            paths.patchedApp,
            paths.patchedPayload,
            paths.applicationSupport,
            paths.originalLibrary,
            paths.patchedLibrary
        ]
        let derived = [
            paths.controllerPackage,
            patchRoot,
            receiptURL,
            journalURL,
            lockURL,
            appStagingURL,
            removalStagingURL,
            vrChatSourceURL,
            vrChatDestinationURL,
            vrChatStagingURL,
            configurationStagingURL,
            paths.originalLibrary.appendingPathComponent("Applications"),
            paths.originalLibrary.appendingPathComponent("Entitlements"),
            paths.originalLibrary.appendingPathComponent("App Settings"),
            paths.originalLibrary.appendingPathComponent("Keymapping"),
            paths.patchedLibrary.appendingPathComponent("Applications"),
            paths.patchedLibrary.appendingPathComponent("Entitlements"),
            paths.patchedLibrary.appendingPathComponent("App Settings"),
            paths.patchedLibrary.appendingPathComponent("Keymapping")
        ]
        for url in bases + derived {
            try SecureFileSystem.requireNoSymlinkComponents(
                url,
                allowMissingSuffix: true
            )
        }
        for url in bases {
            guard url.isFileURL,
                  url.path != "/",
                  !url.path.isEmpty,
                  Self.isLexicallySafe(url.path) else {
                throw PatcherError.unsafePath(url)
            }
        }
        guard paths.controllerPackage.isFileURL,
              paths.controllerPackage.path.hasPrefix("/"),
              Self.isLexicallySafe(paths.controllerPackage.path),
              paths.controllerPackage.lastPathComponent ==
                "PlayCoverVRChatMemoryPolicy.pkg" else {
            throw PatcherError.unsafePath(paths.controllerPackage)
        }
        guard paths.originalApp.lastPathComponent == "PlayCover.app",
              paths.patchedApp.lastPathComponent == "PlayCover VRChat.app",
              paths.patchedPayload.lastPathComponent == "PlayCover.app",
              Set(bases.map(\.path)).count == bases.count,
              appStagingURL != paths.originalApp,
              appStagingURL != paths.patchedApp,
              removalStagingURL != paths.originalApp,
              removalStagingURL != paths.patchedApp,
              configurationStagingURL != paths.originalLibrary,
              configurationStagingURL != paths.patchedLibrary,
              Self.contains(
                paths.patchedLibrary.path,
                configurationStagingURL.path
              ),
              vrChatSourceURL != vrChatDestinationURL else {
            throw PatcherError.unsafePath(paths.patchedApp)
        }
        for (index, first) in bases.enumerated() {
            for second in bases.dropFirst(index + 1) {
                if Self.contains(first.path, second.path) ||
                    Self.contains(second.path, first.path) {
                    throw PatcherError.unsafePath(second)
                }
            }
        }
        for endpoint in bases where nodeExists(endpoint) {
            if isSymbolicLink(endpoint) { throw PatcherError.unsafePath(endpoint) }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: endpoint.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw PatcherError.unsafePath(endpoint)
            }
        }
    }

    private static func contains(_ parent: String, _ candidate: String) -> Bool {
        candidate == parent || candidate.hasPrefix(parent + "/")
    }

    private static func isLexicallySafe(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("//") else { return false }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).dropFirst()
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func requireOriginalPlayCover() throws -> AppIdentity {
        guard nodeExists(paths.originalApp) else {
            throw PatcherError.targetMissing(paths.originalApp)
        }
        try requireIdentity(
            paths.originalApp,
            expected: manifest.playCover,
            label: "original PlayCover"
        )
        return try verifier.identity(of: paths.originalApp)
    }

    private func requirePayload() throws -> AppIdentity {
        let patched = try patchedIdentity()
        guard nodeExists(paths.patchedPayload) else {
            throw PatcherError.payloadMissing(paths.patchedPayload)
        }
        try requireIdentity(
            paths.patchedPayload,
            expected: patched,
            label: "patched payload"
        )
        _ = try ControllerPackageVerifier.verify(
            paths.controllerPackage,
            requirement: try controllerRequirement()
        )
        return patched
    }

    private func requireOriginalVRChat() throws -> ObservedVRChatIdentity {
        guard nodeExists(vrChatSourceURL) else {
            throw PatcherError.vrChatMissing(vrChatSourceURL)
        }
        return try requireVRChat(at: vrChatSourceURL, label: "original VRChat")
    }

    private func requireOriginalConfiguration() throws
        -> VRChatConfigurationIdentity {
        try configurationMigrator.validateSource(
            in: paths.originalLibrary,
            destinationLibrary: paths.patchedLibrary
        )
    }

    private func requireInstalledConfiguration() throws
        -> VRChatConfigurationIdentity {
        switch try configurationMigrator.inspectConfiguration(
            at: paths.patchedLibrary,
            destinationLibrary: paths.patchedLibrary
        ) {
        case .complete(let identity):
            return identity
        case .absent:
            throw PatcherError.vrChatConfigurationMissing(
                paths.patchedLibrary
            )
        case .partial:
            throw PatcherError.unknownModification(
                "the independent VRChat configuration is incomplete"
            )
        }
    }

    private func requireImportedVRChat() throws -> ObservedVRChatIdentity {
        guard nodeExists(vrChatDestinationURL) else {
            throw PatcherError.vrChatMissing(vrChatDestinationURL)
        }
        return try requireVRChat(
            at: vrChatDestinationURL,
            label: "independent VRChat copy"
        )
    }

    private func requireVRChat(
        at url: URL,
        label: String
    ) throws -> ObservedVRChatIdentity {
        if isSymbolicLink(url) {
            throw PatcherError.unknownModification("\(label) is a symlink")
        }
        try VRChatArtifactScanner.verifyClean(url)
        let actual = try vrChatVerifier.identity(of: url, expected: manifest.vrChat)
        if let mismatch = actual.mismatch(from: manifest.vrChat) {
            throw PatcherError.identityMismatch(
                expected: "\(label) matching the compatibility manifest",
                actual: mismatch
            )
        }
        return actual
    }

    private func requireIndependentTree(
        _ imported: ObservedVRChatIdentity,
        matches source: ObservedVRChatIdentity
    ) throws {
        guard imported.treeSHA256 == source.treeSHA256 else {
            throw PatcherError.identityMismatch(
                expected: "VRChat source tree \(source.treeSHA256)",
                actual: imported.treeSHA256
            )
        }
        try CloneFirstVRChatImporter.rejectHardLinks(
            from: vrChatSourceURL,
            to: vrChatDestinationURL
        )
    }

    private func requireIdentity(
        _ url: URL,
        expected: AppIdentity,
        label: String
    ) throws {
        guard nodeExists(url) else { throw PatcherError.targetMissing(url) }
        if isSymbolicLink(url) {
            throw PatcherError.unknownModification("\(label) is a symlink")
        }
        let actual = try verifier.identity(of: url)
        if let mismatch = actual.mismatch(from: expected) {
            throw PatcherError.identityMismatch(
                expected: "\(label) \(expected.treeSHA256)",
                actual: mismatch
            )
        }
    }

    private func prepareAppStaging(
        expected: AppIdentity,
        journal: inout TransactionJournal
    ) throws {
        if nodeExists(appStagingURL) {
            do {
                guard let binding = journal.appStagingBinding else {
                    throw PatcherError.unknownModification(
                        "staged payload exists without a journal binding"
                    )
                }
                try SecureTreeAuditor.requireBinding(
                    binding,
                    for: appStagingURL
                )
                try requireIdentity(
                    appStagingURL,
                    expected: expected,
                    label: "staged patched payload"
                )
                try requireSameVolume(
                    appStagingURL,
                    paths.patchedApp.deletingLastPathComponent()
                )
                return
            } catch {
                try removeOwnedTemporaryIfPresent(
                    appStagingURL,
                    binding: journal.appStagingBinding
                )
                journal.appStagingBinding = nil
                try writeJournal(journal)
            }
        }
        do {
            try fileManager.copyItem(at: paths.patchedPayload, to: appStagingURL)
        } catch {
            if nodeExists(appStagingURL) {
                journal.appStagingBinding = try SecureTreeAuditor.binding(
                    for: appStagingURL
                )
                try writeJournal(journal)
            }
            throw error
        }
        journal.appStagingBinding = try SecureTreeAuditor.binding(
            for: appStagingURL
        )
        try writeJournal(journal)
        try requireSameVolume(
            appStagingURL,
            paths.patchedApp.deletingLastPathComponent()
        )
        try requireIdentity(
            appStagingURL,
            expected: expected,
            label: "staged patched payload"
        )
    }

    private func requireSameVolume(_ first: URL, _ second: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let firstID = try first.resourceValues(forKeys: keys).volumeIdentifier
            as? AnyHashable
        let secondID = try second.resourceValues(forKeys: keys).volumeIdentifier
            as? AnyHashable
        guard firstID != nil, firstID == secondID else {
            throw PatcherError.transactionFailed(
                "staging and destination are not on the same volume"
            )
        }
    }

    private func atomicInstallNew(_ source: URL, _ destination: URL) throws {
        try SecureFileSystem.renameExclusive(source, destination)
    }

    private func removeOwnedTemporaryIfPresent(
        _ url: URL,
        binding: SecureNodeBinding?
    ) throws {
        guard [
            appStagingURL,
            vrChatStagingURL,
            configurationStagingURL,
            removalStagingURL
        ].contains(url),
              url != paths.originalApp,
              url != paths.patchedApp,
              url != paths.patchedPayload,
              url != vrChatSourceURL,
              url != vrChatDestinationURL else {
            throw PatcherError.unsafePath(url)
        }
        guard nodeExists(url) else { return }
        guard let binding else {
            throw PatcherError.unknownModification(
                "refusing to remove unbound staging node at \(url.path)"
            )
        }
        try SecureTreeAuditor.requireBinding(binding, for: url)
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            ".pcvr-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        try SecureFileSystem.renameExclusive(url, quarantine)
        do {
            try SecureTreeAuditor.requireBinding(binding, for: quarantine)
            try fileManager.removeItem(at: quarantine)
            guard !nodeExists(quarantine), !nodeExists(url) else {
                throw PatcherError.transactionFailed(
                    "quarantined staging cleanup did not complete"
                )
            }
        } catch {
            if nodeExists(quarantine), !nodeExists(url) {
                try? SecureFileSystem.renameExclusive(quarantine, url)
            }
            throw error
        }
    }

    private func refreshedBinding(
        for url: URL,
        previous: SecureNodeBinding
    ) throws -> SecureNodeBinding {
        let status = try SecureFileSystem.status(of: url)
        guard UInt64(bitPattern: Int64(status.st_dev)) == previous.device,
              UInt64(status.st_ino) == previous.inode,
              status.st_uid == previous.ownerUID,
              UInt32(status.st_mode) == previous.mode else {
            throw PatcherError.unknownModification(
                "owned staging root changed while publishing"
            )
        }
        return try SecureTreeAuditor.binding(
            for: url,
            expectedOwnerUID: previous.ownerUID
        )
    }

    private func ensureAbsent(_ url: URL) throws {
        if nodeExists(url) {
            throw PatcherError.invalidOperation(
                "an owned staging path already exists; Inspect and Repair before retrying"
            )
        }
    }

    private func nodeExists(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString { lstat($0, &status) == 0 }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            return false
        }
        return (status.st_mode & S_IFMT) == S_IFLNK
    }

    private func withExclusiveTransaction<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        try SecureFileSystem.createDirectories(patchRoot)
        let descriptor = try SecureFileSystem.withParentDirectory(
            of: lockURL,
            createMissing: false
        ) { parent, name in
            name.withCString {
                openat(
                    parent,
                    $0,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
        }
        guard descriptor >= 0 else {
            throw PatcherError.transactionFailed(
                "cannot create transaction lock: \(String(cString: strerror(errno)))"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PatcherError.invalidOperation(
                "another patch transaction is active"
            )
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await body()
    }

    private func makeJournal(
        operation: PatcherOperation,
        phase: TransactionPhase
    ) -> TransactionJournal {
        TransactionJournal(
            schemaVersion: 5,
            patchID: manifest.patchID,
            operation: operation,
            phase: phase,
            originalAppPath: paths.originalApp.path,
            patchedAppPath: paths.patchedApp.path,
            payloadPath: paths.patchedPayload.path,
            appStagingPath: appStagingURL.path,
            removalStagingPath: removalStagingURL.path,
            vrChatSourcePath: vrChatSourceURL.path,
            vrChatDestinationPath: vrChatDestinationURL.path,
            vrChatStagingPath: vrChatStagingURL.path,
            configurationStagingPath: configurationStagingURL.path,
            importStrategy: nil,
            configurationSHA256: nil,
            controllerSetupReason: nil,
            controllerInstallation: nil,
            appStagingBinding: nil,
            removalStagingBinding: nil,
            vrChatStagingBinding: nil,
            configurationStagingBinding: nil
        )
    }

    private func validate(journal: TransactionJournal) throws {
        guard journal.schemaVersion == 5,
              journal.patchID == manifest.patchID,
              journal.originalAppPath == paths.originalApp.path,
              journal.patchedAppPath == paths.patchedApp.path,
              journal.appStagingPath == appStagingURL.path,
              journal.removalStagingPath == removalStagingURL.path,
              journal.vrChatSourcePath == vrChatSourceURL.path,
              journal.vrChatDestinationPath == vrChatDestinationURL.path,
              journal.vrChatStagingPath == vrChatStagingURL.path,
              journal.configurationStagingPath ==
                configurationStagingURL.path,
              journal.configurationSHA256.map(AppIdentity.isSHA256) ?? true,
              journal.controllerInstallation.map({ evidence in
                  evidence.runnerSHA256.count == 64 &&
                      evidence.attestationSHA256.count == 64
              }) ?? true,
              journal.appStagingBinding?.validateShape() ?? true,
              journal.removalStagingBinding?.validateShape() ?? true,
              journal.vrChatStagingBinding?.validateShape() ?? true,
              journal.configurationStagingBinding?.validateShape() ?? true else {
            throw PatcherError.unknownModification(
                "transaction journal does not match this manifest and path set"
            )
        }

        // The payload is bundled inside the Patcher application. Its absolute
        // path therefore changes whenever the Patcher is rebuilt, moved, or
        // selected from a different copy. Recovery never follows the path
        // stored in a journal; it re-verifies the payload currently bundled
        // with this Patcher in `repair()`. Keep the journal's payloadPath as
        // historical audit data, but do not mistake a relocated Patcher for
        // an unknown transaction.
        try requireBoundIfPresent(
            appStagingURL,
            binding: journal.appStagingBinding
        )
        try requireBoundIfPresent(
            removalStagingURL,
            binding: journal.removalStagingBinding
        )
        try requireBoundIfPresent(
            vrChatStagingURL,
            binding: journal.vrChatStagingBinding
        )
        try requireBoundIfPresent(
            configurationStagingURL,
            binding: journal.configurationStagingBinding
        )
    }

    private func requireBoundIfPresent(
        _ url: URL,
        binding: SecureNodeBinding?
    ) throws {
        guard nodeExists(url) else { return }
        guard let binding else {
            throw PatcherError.unknownModification(
                "staging exists without a journal identity: \(url.path)"
            )
        }
        try SecureTreeAuditor.requireBinding(binding, for: url)
    }

    private func readJournal() throws -> TransactionJournal? {
        guard nodeExists(journalURL) else { return nil }
        return try JSONDecoder().decode(
            TransactionJournal.self,
            from: Data(contentsOf: journalURL)
        )
    }

    private func writeJournal(_ journal: TransactionJournal) throws {
        try SecureFileSystem.createDirectories(patchRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: [.atomic])
    }

    private func readReceipt() throws -> StoredPatchReceipt? {
        guard nodeExists(receiptURL) else { return nil }
        let data = try SecureFileSystem.readRegularFile(
            receiptURL,
            maximumBytes: 128 * 1_024
        )
        guard let object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? Int else {
            throw PatcherError.unknownModification(
                "the patch receipt has no recognized schema"
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch schemaVersion {
        case 4:
            return .current(try decoder.decode(PatchReceipt.self, from: data))
        case 3:
            return .legacyV3(try decoder.decode(
                LegacyPatchReceiptV3.self,
                from: data
            ))
        default:
            throw PatcherError.unknownModification(
                "unsupported patch receipt schema \(schemaVersion)"
            )
        }
    }

    private func writeReceipt(
        importedTreeSHA256: String,
        configurationSHA256: String,
        strategy: VRChatImportStrategy,
        controllerInstallation: ControllerInstallationEvidence
    ) throws {
        let patched = try patchedIdentity()
        let receipt = PatchReceipt(
            patchID: manifest.patchID,
            installedAt: Date(),
            originalTreeSHA256: manifest.playCover.treeSHA256,
            patchedTreeSHA256: patched.treeSHA256,
            importedVRChatTreeSHA256: importedTreeSHA256,
            configurationSHA256: configurationSHA256,
            importStrategy: strategy,
            controllerInstallation: controllerInstallation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: receiptURL, options: [.atomic])
    }

    private func requireReceipt(
        controllerInstallation: ControllerInstallationEvidence
    ) throws {
        guard let storedReceipt = try readReceipt(),
              case .current(let receipt) = storedReceipt,
              receiptMatches(
                receipt,
                controllerInstallation: controllerInstallation
              ) else {
            throw PatcherError.unknownModification(
                "the patch receipt is missing or does not match the exact installation"
            )
        }
    }

    private func receiptMatches(
        _ receipt: PatchReceipt,
        controllerInstallation: ControllerInstallationEvidence
    ) -> Bool {
        guard let controllerRequirement = manifest.controllerPackage else {
            return false
        }
        return currentReceiptOwnershipMatches(receipt) &&
            receipt.controllerInstallation == controllerInstallation &&
            receipt.controllerInstallation.matches(
                controllerRequirement
            )
    }

    /// A receipt proves ownership of the fixed customized App. Imported games,
    /// settings and keymaps are mutable user data after Create and therefore
    /// are deliberately not part of installed-state or Remove identity.
    private func currentReceiptOwnershipMatches(
        _ receipt: PatchReceipt
    ) -> Bool {
        guard let patched = manifest.patchedPlayCover,
              let controllerRequirement = manifest.controllerPackage else {
            return false
        }
        return receipt.schemaVersion == 4 &&
            receipt.patchID == manifest.patchID &&
            AppIdentity.isSHA256(receipt.originalTreeSHA256) &&
            AppIdentity.isSHA256(receipt.patchedTreeSHA256) &&
            AppIdentity.isSHA256(receipt.importedVRChatTreeSHA256) &&
            AppIdentity.isSHA256(receipt.configurationSHA256) &&
            receipt.originalTreeSHA256.caseInsensitiveCompare(
                manifest.playCover.treeSHA256
            ) == .orderedSame &&
            receipt.patchedTreeSHA256.caseInsensitiveCompare(
                patched.treeSHA256
            ) == .orderedSame &&
            receipt.controllerInstallation.matches(controllerRequirement)
    }

    private func legacyReceiptOwnershipMatches(
        _ receipt: LegacyPatchReceiptV3
    ) -> Bool {
        guard let patched = manifest.patchedPlayCover else { return false }
        return receipt.schemaVersion == 3 &&
            receipt.patchID == manifest.patchID &&
            AppIdentity.isSHA256(receipt.originalTreeSHA256) &&
            AppIdentity.isSHA256(receipt.patchedTreeSHA256) &&
            AppIdentity.isSHA256(receipt.importedVRChatTreeSHA256) &&
            AppIdentity.isSHA256(receipt.configurationSHA256) &&
            receipt.originalTreeSHA256.caseInsensitiveCompare(
                manifest.playCover.treeSHA256
            ) == .orderedSame &&
            receipt.patchedTreeSHA256.caseInsensitiveCompare(
                patched.treeSHA256
            ) == .orderedSame
    }

    private func removeReceiptAndJournal() throws {
        try SecureFileSystem.unlinkRegularFileIfPresent(receiptURL)
        try SecureFileSystem.unlinkRegularFileIfPresent(journalURL)
    }

    private func inspection(_ state: InspectionState) -> Inspection {
        Inspection(
            state: state,
            originalApp: paths.originalApp,
            patchedApp: paths.patchedApp,
            patchID: manifest.patchID
        )
    }

    private func operationError(
        _ operation: String,
        state: InspectionState
    ) -> PatcherError {
        switch state {
        case .unknownModification(let reason):
            return .unknownModification(reason)
        case .busy(let names):
            return .applicationsRunning(names)
        case .unsupportedRuntime(let reasons):
            return .unsupportedRuntime(reasons)
        case .payloadUnavailable:
            return .payloadUnavailable
        case .vrChatMissing(let url):
            return .vrChatMissing(url)
        default:
            return .invalidOperation(
                "\(operation) is not valid while state is \(String(describing: state))"
            )
        }
    }

    private func controllerRequirement() throws
        -> ControllerPackageRequirement {
        guard let requirement = manifest.controllerPackage else {
            throw PatcherError.payloadUnavailable
        }
        return requirement
    }

    private func controllerSetupReason(
        for journal: TransactionJournal
    ) async throws -> ControllerSetupReason {
        if let reason = journal.controllerSetupReason { return reason }
        let state = try await controllerSetupProvider.inspect(
            requirement: controllerRequirement()
        )
        switch state {
        case .absent: return .notInstalled
        case .knownUpgradeRequired: return .knownUpgradeRequired
        case .installing: return .verificationRequired
        case .exact: return .verificationRequired
        case .uninstalling, .uninstallingActive:
            return .verificationRequired
        case .uninstallFinalizationRepairRequired:
            return .verificationRequired
        case .unknown: return .verificationRequired
        }
    }

    private func patchedIdentity() throws -> AppIdentity {
        guard let identity = manifest.patchedPlayCover else {
            throw PatcherError.payloadUnavailable
        }
        return identity
    }

    private var patchRoot: URL {
        paths.applicationSupport.appendingPathComponent(
            manifest.patchID,
            isDirectory: true
        )
    }
    private var receiptURL: URL {
        patchRoot.appendingPathComponent("receipt.json")
    }
    private var journalURL: URL {
        patchRoot.appendingPathComponent("transaction.json")
    }
    private var lockURL: URL {
        patchRoot.appendingPathComponent("transaction.lock")
    }
    private var appStagingURL: URL {
        paths.patchedApp.deletingLastPathComponent().appendingPathComponent(
            ".pcvr-\(manifest.patchID)-app-staging.app",
            isDirectory: true
        )
    }
    private var removalStagingURL: URL {
        paths.patchedApp.deletingLastPathComponent().appendingPathComponent(
            ".pcvr-\(manifest.patchID)-remove-staging.app",
            isDirectory: true
        )
    }
    private var vrChatSourceURL: URL {
        paths.originalLibrary.appendingPathComponent(
            "Applications/com.vrchat.mobile.app",
            isDirectory: true
        )
    }
    private var vrChatDestinationURL: URL {
        paths.patchedLibrary.appendingPathComponent(
            "Applications/com.vrchat.mobile.app",
            isDirectory: true
        )
    }
    private var vrChatStagingURL: URL {
        vrChatDestinationURL.deletingLastPathComponent().appendingPathComponent(
            ".pcvr-\(manifest.patchID)-vrchat-import.app",
            isDirectory: true
        )
    }
    private var configurationStagingURL: URL {
        paths.patchedLibrary.appendingPathComponent(
            ".pcvr-\(manifest.patchID)-configuration-staging",
            isDirectory: true
        )
    }
}
