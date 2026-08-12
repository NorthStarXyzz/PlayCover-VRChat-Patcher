import CryptoKit
import Foundation
import XCTest
@testable import PCVRPatcherCore

final class PatcherEngineTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var originalApp: URL!
    private var patchedApp: URL!
    private var payload: URL!
    private var controllerPackage: URL!
    private var support: URL!
    private var originalLibrary: URL!
    private var patchedLibrary: URL!
    private var sourceVRChat: URL!
    private var importedVRChat: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory
        let noFollowTemporary = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temporary.path)", isDirectory: true)
            : temporary
        root = noFollowTemporary.appendingPathComponent(
                "pcvr-patcher-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        originalApp = applications.appendingPathComponent(
            "PlayCover.app",
            isDirectory: true
        )
        patchedApp = applications.appendingPathComponent(
            "PlayCover VRChat.app",
            isDirectory: true
        )
        payload = root.appendingPathComponent(
            "Payload/PlayCover.app",
            isDirectory: true
        )
        controllerPackage = root.appendingPathComponent(
            "Controller/PlayCoverVRChatMemoryPolicy.pkg"
        )
        support = root.appendingPathComponent("Patcher Support", isDirectory: true)
        originalLibrary = root.appendingPathComponent(
            "Original Library",
            isDirectory: true
        )
        patchedLibrary = root.appendingPathComponent(
            "Patched Library",
            isDirectory: true
        )
        sourceVRChat = originalLibrary.appendingPathComponent(
            "Applications/com.vrchat.mobile.app",
            isDirectory: true
        )
        importedVRChat = patchedLibrary.appendingPathComponent(
            "Applications/com.vrchat.mobile.app",
            isDirectory: true
        )
        try makeApp(originalApp, marker: "source")
        try makeApp(payload, marker: "patched")
        try FileManager.default.createDirectory(
            at: controllerPackage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("controller-package-fixture".utf8).write(
            to: controllerPackage
        )
        try makeVRChat(sourceVRChat, marker: "vrchat")
        try makeVRChatConfiguration()
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testRepositorySourceOnlySchemaTwoManifestLoads() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Compatibility/manifests/pc-55638e9-vrc-2026.2.30300-1365-macos-25G70.json"
            )
        let manifest = try PatcherEngine.loadManifest(from: url)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertNil(manifest.patchedPlayCover)
        XCTAssertEqual(manifest.policy.maxPhysicalPercent, 75)
        XCTAssertEqual(manifest.ipc.protocolVersion, 2)
    }

    func testSourceOnlyManifestRejectsControllerPackageField() throws {
        let invalid = CompatibilityManifest(
            patchID: "test-patch",
            architecture: "arm64",
            playCover: .sourceFixture,
            patchedPlayCover: nil,
            vrChat: .fixture,
            host: CompatibilityManifest.fixture.host,
            policy: CompatibilityManifest.fixture.policy,
            ipc: CompatibilityManifest.fixture.ipc,
            controllerPackage: .fixture
        )
        let url = root.appendingPathComponent("invalid-source-only.json")
        try JSONEncoder().encode(invalid).write(to: url)
        XCTAssertThrowsError(try PatcherEngine.loadManifest(from: url)) {
            guard case PatcherError.invalidManifest(let reason) = $0 else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertTrue(reason.contains("source-only"))
        }
    }

    func testPayloadManifestRejectsUnreviewedControllerQuarantinePath() throws {
        let encoded = try JSONEncoder().encode(CompatibilityManifest.fixture)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var package = try XCTUnwrap(
            object["controllerPackage"] as? [String: Any]
        )
        package["runnerQuarantinePath"] = "/private/tmp/unreviewed-runner"
        object["controllerPackage"] = package
        let url = root.appendingPathComponent("invalid-quarantine-path.json")
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: url)

        XCTAssertThrowsError(try PatcherEngine.loadManifest(from: url)) {
            guard case PatcherError.invalidManifest = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
    }

    func testTreeHashIncludesFrameworkContentsAfterSymlinkAlias() throws {
        let framework = root.appendingPathComponent(
            "Tree/Sparkle.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Resources").path,
            withDestinationPath: "Versions/B/Resources"
        )
        let resources = framework.appendingPathComponent(
            "Versions/B/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let reviewedFile = resources.appendingPathComponent("important.txt")
        try Data("first".utf8).write(to: reviewedFile)
        let before = try AppTreeVerifier.treeSHA256(
            root.appendingPathComponent("Tree", isDirectory: true)
        )

        try Data("second".utf8).write(to: reviewedFile)
        let after = try AppTreeVerifier.treeSHA256(
            root.appendingPathComponent("Tree", isDirectory: true)
        )

        XCTAssertNotEqual(
            before,
            after,
            "A framework symlink alias must not prune its real Versions tree"
        )
    }

    func testReviewedLocalPlayCoverMetadataWhenFixtureIsAvailable() throws {
        let local = URL(
            fileURLWithPath: "/Applications/PlayCover.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw XCTSkip("reviewed local PlayCover fixture is not installed")
        }
        let actual = try AppTreeVerifier().identity(of: local)
        XCTAssertEqual(actual.bundleIdentifier, "io.playcover.PlayCover")
        XCTAssertTrue(AppIdentity.isSHA256(actual.treeSHA256))
    }

    func testCreateAndRemoveKeepOriginalTreeUnchangedAndPreserveLibrary() async throws {
        let originalBefore = try AppTreeVerifier.treeSHA256(originalApp)
        let originalMetadataBefore = try SecureTreeAuditor.inspect(originalApp)
        let originalLibraryBefore = try AppTreeVerifier.treeSHA256(
            originalLibrary
        )
        let originalLibraryMetadataBefore = try SecureTreeAuditor.inspect(
            originalLibrary
        )
        let vrChatBefore = try AppTreeVerifier.treeSHA256(sourceVRChat)
        let vrChatMetadataBefore = try SecureTreeAuditor.inspect(sourceVRChat)
        let engine = try makeEngine()
        let initial = try await engine.inspect()
        XCTAssertEqual(initial.state, .readyToCreate)

        let created = try await engine.createPatchedCopy()
        XCTAssertEqual(created.inspection.state, .fullyPatched)
        XCTAssertEqual(created.importStrategy, .clone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedEntitlement.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedAppSettings.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedKeymapping.path
        ))
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalApp),
            originalBefore
        )
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(sourceVRChat),
            vrChatBefore
        )
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalLibrary),
            originalLibraryBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(originalApp),
            originalMetadataBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(sourceVRChat),
            vrChatMetadataBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(originalLibrary),
            originalLibraryMetadataBefore
        )

        let removed = try await engine.removePatchedCopy()
        XCTAssertEqual(removed.inspection.state, .readyToCreate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedEntitlement.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedAppSettings.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedKeymapping.path
        ))
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalApp),
            originalBefore
        )
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(sourceVRChat),
            vrChatBefore
        )
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalLibrary),
            originalLibraryBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(originalApp),
            originalMetadataBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(sourceVRChat),
            vrChatMetadataBefore
        )
        XCTAssertEqual(
            try SecureTreeAuditor.inspect(originalLibrary),
            originalLibraryMetadataBefore
        )
    }

    func testCreateInstallsControllerBeforeBecomingFullyPatched() async throws {
        let provider = FixtureControllerSetupProvider(initial: .absent)
        let engine = try makeEngine(controllerSetupProvider: provider)

        let result = try await engine.createPatchedCopy()

        XCTAssertEqual(result.inspection.state, .fullyPatched)
        let installCalls = await provider.installCalls
        XCTAssertEqual(installCalls, 1)
        let receipt = try receiptJSONObject()
        XCTAssertEqual(receipt["schemaVersion"] as? Int, 4)
        XCTAssertNotNil(receipt["controllerInstallation"])
    }

    func testKnownPreProvenanceRunnerIsOnlyAnUpgradePredecessor() {
        XCTAssertTrue(
            RootControllerInstallationVerifier
                .isReviewedPredecessorRunner(
                    "039047ea409a4cd5b27f142b657f239ec99bbed6e2ee1a866bf031a81973f558"
                )
        )
        XCTAssertTrue(
            RootControllerInstallationVerifier
                .isReviewedPredecessorRunner(
                    "5a712cf92c7c54cf70f554b0804bab28923edf911db82edd1b65b7e010998a87"
                )
        )
        XCTAssertFalse(
            RootControllerInstallationVerifier
                .isReviewedPredecessorRunner(String(repeating: "0", count: 64))
        )
    }

    func testInstallerCancellationLeavesRecoverableControllerSetupState() async throws {
        let cancelled = FixtureControllerSetupProvider(
            initial: .absent,
            installOutcome: .cancel
        )
        let engine = try makeEngine(controllerSetupProvider: cancelled)
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            XCTAssertEqual($0 as? PatcherError, .controllerSetupCancelled)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        let cancelledInspection = try await engine.inspect()
        XCTAssertEqual(
            cancelledInspection.state,
            .controllerSetupRequired(.installationCancelled)
        )

        let retry = FixtureControllerSetupProvider(initial: .absent)
        let repaired = try await makeEngine(
            importer: FailIfCalledImporter(),
            controllerSetupProvider: retry
        ).repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        let retryCalls = await retry.installCalls
        XCTAssertEqual(retryCalls, 1)
    }

    func testInstallerTimeoutLeavesRecoverableJournalWithoutReceipt() async throws {
        let provider = FixtureControllerSetupProvider(
            initial: .absent,
            installOutcome: .timeOut
        )
        let engine = try makeEngine(controllerSetupProvider: provider)
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            XCTAssertEqual($0 as? PatcherError, .controllerSetupTimedOut)
        }
        let timedOutInspection = try await engine.inspect()
        XCTAssertEqual(
            timedOutInspection.state,
            .controllerSetupRequired(.installationTimedOut)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testExactArtifactsWithoutPackageReceiptAreRepairableButNeverReady() async throws {
        let provider = FixtureControllerSetupProvider(
            initial: .knownUpgradeRequired
        )
        let engine = try makeEngine(controllerSetupProvider: provider)

        let result = try await engine.createPatchedCopy()

        XCTAssertEqual(result.inspection.state, .fullyPatched)
        let calls = await provider.installCalls
        XCTAssertEqual(calls, 1)
    }

    func testRemoveAuthorizationCancellationNeverDeletesParallelApp() async throws {
        let provider = FixtureControllerSetupProvider(
            initial: .exact(.fixture),
            uninstallOutcome: .cancel
        )
        let engine = try makeEngine(controllerSetupProvider: provider)
        _ = try await engine.createPatchedCopy()

        await XCTAssertThrowsErrorAsync(try await engine.removePatchedCopy()) {
            XCTAssertEqual($0 as? PatcherError, .controllerSetupCancelled)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let interruptedInspection = try await engine.inspect()
        XCTAssertEqual(
            interruptedInspection.state,
            .repairRequired(.uninstallingController)
        )

        let repaired = try await engine.repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testRepairResumesReviewedUninstallBeforeDeletingApp() async throws {
        let interrupted = FixtureControllerSetupProvider(
            initial: .exact(.fixture),
            uninstallOutcome: .leaveUninstalling
        )
        let engine = try makeEngine(controllerSetupProvider: interrupted)
        _ = try await engine.createPatchedCopy()
        await XCTAssertThrowsErrorAsync(try await engine.removePatchedCopy())
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))

        let recovery = FixtureControllerSetupProvider(initial: .uninstalling)
        let repaired = try await makeEngine(
            controllerSetupProvider: recovery
        ).repair()
        XCTAssertEqual(repaired.inspection.state, .readyToCreate)
        let recoveryCalls = await recovery.uninstallCalls
        XCTAssertEqual(recoveryCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedLibrary.path))
    }

    func testRepairObservesConcurrentUninstallWithoutSecondDestructiveStart()
        async throws {
        let firstOwner = FixtureControllerSetupProvider(
            initial: .exact(.fixture),
            uninstallOutcome: .leaveUninstallingActive
        )
        let engine = try makeEngine(controllerSetupProvider: firstOwner)
        _ = try await engine.createPatchedCopy()
        await XCTAssertThrowsErrorAsync(try await engine.removePatchedCopy())

        let observer = FixtureControllerSetupProvider(
            initial: .uninstallingActive,
            uninstallOutcome: .observeActiveThenSucceed
        )
        let repaired = try await makeEngine(
            controllerSetupProvider: observer
        ).repair()
        XCTAssertEqual(repaired.inspection.state, .readyToCreate)
        let observerCalls = await observer.uninstallCalls
        let destructiveCalls = await observer.destructiveUninstallCalls
        XCTAssertEqual(observerCalls, 1)
        XCTAssertEqual(destructiveCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedLibrary.path))
    }

    func testFinalStaleClaimInstallerCancellationPreservesRemoveRecovery()
        async throws {
        try await createFinalStaleClaimRemoveJournal()
        let recovery = FixtureControllerSetupProvider(
            initial: .uninstallFinalizationRepairRequired,
            installOutcome: .cancel
        )
        await XCTAssertThrowsErrorAsync(try await makeEngine(
            controllerSetupProvider: recovery
        ).repair()) {
            XCTAssertEqual($0 as? PatcherError, .controllerSetupCancelled)
        }
        let installCalls = await recovery.installCalls
        let uninstallCalls = await recovery.uninstallCalls
        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(uninstallCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedLibrary.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: transactionJournalURL.path
        ))
    }

    func testFinalStaleClaimSecondAuthorizationCancellationCanRollBack()
        async throws {
        try await createFinalStaleClaimRemoveJournal()
        let recovery = FixtureControllerSetupProvider(
            initial: .uninstallFinalizationRepairRequired,
            uninstallOutcome: .cancel
        )
        let recoveryEngine = try makeEngine(
            controllerSetupProvider: recovery
        )
        await XCTAssertThrowsErrorAsync(try await recoveryEngine.repair()) {
            XCTAssertEqual($0 as? PatcherError, .controllerSetupCancelled)
        }
        let installCalls = await recovery.installCalls
        let uninstallCalls = await recovery.uninstallCalls
        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(uninstallCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedLibrary.path))

        let rolledBack = try await recoveryEngine.repair()
        XCTAssertEqual(rolledBack.inspection.state, .fullyPatched)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: transactionJournalURL.path
        ))
    }

    func testFinalStaleClaimPackageRepairCompletesRemoveAndPreservesLibrary()
        async throws {
        try await createFinalStaleClaimRemoveJournal()
        let recovery = FixtureControllerSetupProvider(
            initial: .uninstallFinalizationRepairRequired
        )
        let repaired = try await makeEngine(
            controllerSetupProvider: recovery
        ).repair()
        XCTAssertEqual(repaired.inspection.state, .readyToCreate)
        let installCalls = await recovery.installCalls
        let uninstallCalls = await recovery.uninstallCalls
        XCTAssertEqual(installCalls, 1)
        XCTAssertEqual(uninstallCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedLibrary.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: transactionJournalURL.path
        ))
    }

    func testExactLegacyV3ReceiptRequiresControllerRepairAndUpgradesNarrowly() async throws {
        let provider = FixtureControllerSetupProvider(initial: .exact(.fixture))
        let engine = try makeEngine(controllerSetupProvider: provider)
        _ = try await engine.createPatchedCopy()
        var legacy = try receiptJSONObject()
        legacy["schemaVersion"] = 3
        legacy.removeValue(forKey: "controllerInstallation")
        try writeJSONObject(legacy, to: receiptURL)

        let legacyInspection = try await engine.inspect()
        XCTAssertEqual(
            legacyInspection.state,
            .controllerSetupRequired(.verificationRequired)
        )
        let repaired = try await engine.repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        XCTAssertEqual(try receiptJSONObject()["schemaVersion"] as? Int, 4)
    }

    func testUnknownReceiptSchemaFailsClosedBeforeControllerRepair() async throws {
        let exact = FixtureControllerSetupProvider(initial: .exact(.fixture))
        _ = try await makeEngine(
            controllerSetupProvider: exact
        ).createPatchedCopy()
        var unknown = try receiptJSONObject()
        unknown["schemaVersion"] = 99
        try writeJSONObject(unknown, to: receiptURL)

        let missingController = FixtureControllerSetupProvider(initial: .absent)
        let engine = try makeEngine(
            controllerSetupProvider: missingController
        )
        guard case .unknownModification(let reason) =
                try await engine.inspect().state else {
            return XCTFail("unknown receipt must fail closed")
        }
        XCTAssertTrue(reason.contains("receipt"))
        await XCTAssertThrowsErrorAsync(try await engine.repair()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        let installCalls = await missingController.installCalls
        XCTAssertEqual(installCalls, 0)
    }

    func testControllerPackageAndTrustedDirectoryRejectRealExtendedACLs() throws {
        let acl = try makeExtendedACL()
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(
            controllerPackage.path.withCString {
                acl_set_file($0, ACL_TYPE_EXTENDED, acl)
            },
            0
        )
        XCTAssertThrowsError(try ControllerPackageVerifier.verify(
            controllerPackage,
            requirement: .fixture
        ))

        let trustedDirectory = root.appendingPathComponent(
            "acl-ancestor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: trustedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let descriptor = open(
            trustedDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(
            acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED),
            0
        )
        XCTAssertThrowsError(try RootControllerInstallationVerifier
            .requireTrustedDirectory(
                trustedDirectory,
                expectedOwnerUID: getuid(),
                expectedGroupID: getgid(),
                expectedMode: 0o755
            ))
    }

    func testExactInstallJournalIsNeverReadyAndMixedJournalsFailClosed() throws {
        let fixture = try makeRootControllerStateFixture()
        try fixture.installJournalData.write(to: fixture.installJournal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.installJournal.path
        )

        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ),
            .installing
        )

        let unknownInstallEntry = URL(
            fileURLWithPath: fixture.requirement.controller.path
        ).deletingLastPathComponent().appendingPathComponent("unknown-install")
        try Data("unknown".utf8).write(to: unknownInstallEntry)
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("journaled install must reject unknown package entries")
        }
        try FileManager.default.removeItem(at: unknownInstallEntry)

        try fixture.uninstallJournalData.write(to: fixture.uninstallJournal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.uninstallJournal.path
        )
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("simultaneous install/uninstall journals must fail")
        }

        try FileManager.default.removeItem(at: fixture.uninstallJournal)
        let acl = try makeExtendedACL()
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(
            fixture.installJournal.path.withCString {
                acl_set_file($0, ACL_TYPE_EXTENDED, acl)
            },
            0
        )
        XCTAssertThrowsError(try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ))
    }

    func testStrictPresenceTreatsOnlyENOENTAsAbsent() throws {
        let missing = root.appendingPathComponent("strict/missing")
        XCTAssertFalse(try SecureFileSystem.nodeExistsStrict(missing))

        let nonDirectory = root.appendingPathComponent("strict/not-a-directory")
        try FileManager.default.createDirectory(
            at: nonDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("file".utf8).write(to: nonDirectory)
        XCTAssertThrowsError(try SecureFileSystem.nodeExistsStrict(
            nonDirectory.appendingPathComponent("hidden-leaf")
        ))
    }

    func testRootExactStateRejectsPackageAndQuarantineResidue() throws {
        let fixture = try makeRootControllerStateFixture()
        guard case .exact = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("fixture must begin as an exact installation")
        }

        let packageDirectory = URL(
            fileURLWithPath: fixture.requirement.controller.path
        ).deletingLastPathComponent()
        let unexpected = packageDirectory.appendingPathComponent("unexpected")
        try Data("unknown".utf8).write(to: unexpected)
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("an extra package entry must never be ready")
        }
        try FileManager.default.removeItem(at: unexpected)

        let controllerQuarantine = URL(
            fileURLWithPath: fixture.requirement.controllerQuarantinePath
        )
        try Data("predecessor".utf8).write(to: controllerQuarantine)
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("controller quarantine requires an install journal")
        }
        try FileManager.default.removeItem(at: controllerQuarantine)

        let runnerQuarantine = URL(
            fileURLWithPath: fixture.requirement.runnerQuarantinePath
        )
        try Data("predecessor".utf8).write(to: runnerQuarantine)
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("runner quarantine requires an install journal")
        }
    }

    func testInstalledR6PairIsOnlyAnUpgradePredecessor() {
        let runner = "26d2e2776f17707d7ca15469bf00890b547210b8416a9b9ef39144032764e9af"
        let attestation = "4623932fdd80005cc436c9a02f55cd6d2e7186294ce7afc645338460c7dc7bc5"
        XCTAssertTrue(
            RootControllerInstallationVerifier.isReviewedInstalledR6Pair(
                runnerSHA256: runner,
                attestationSHA256: attestation
            )
        )
        XCTAssertFalse(
            RootControllerInstallationVerifier.isReviewedInstalledR6Pair(
                runnerSHA256: runner,
                attestationSHA256: String(repeating: "0", count: 64)
            )
        )
        XCTAssertFalse(
            RootControllerInstallationVerifier.isReviewedInstalledR6Pair(
                runnerSHA256: String(repeating: "0", count: 64),
                attestationSHA256: attestation
            )
        )
    }

    func testRootUninstallRecognizesOnlyReviewedOrderedSubsets() throws {
        let fixture = try makeRootControllerStateFixture()
        try fixture.uninstallJournalData.write(to: fixture.uninstallJournal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.uninstallJournal.path
        )
        let controller = URL(
            fileURLWithPath: fixture.requirement.controller.path
        )
        let attestation = URL(
            fileURLWithPath: fixture.requirement.attestation.path
        )
        let packageDirectory = controller.deletingLastPathComponent()

        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ),
            .uninstalling
        )

        let unexpected = packageDirectory.appendingPathComponent("unexpected")
        try Data("unknown".utf8).write(to: unexpected)
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ) else {
            return XCTFail("journaled uninstall must reject extra entries")
        }
        try FileManager.default.removeItem(at: unexpected)

        try FileManager.default.removeItem(at: controller)
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ),
            .uninstalling
        )
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .absent,
                trustedRoot: fixture.root
            ),
            .uninstalling
        )

        try FileManager.default.removeItem(at: attestation)
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .absent,
                trustedRoot: fixture.root
            ),
            .uninstalling
        )
        try FileManager.default.removeItem(at: packageDirectory)
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .absent,
                trustedRoot: fixture.root
            ),
            .uninstalling
        )
    }

    func testOperationClaimSeparatesLiveOwnerFromStaleRecovery() throws {
        let fixture = try makeRootControllerStateFixture()
        let identity = try publishOperationClaim(in: fixture)
        try fixture.uninstallJournalData.write(to: fixture.uninstallJournal)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.uninstallJournal.path
        )

        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .live(identity),
                trustedRoot: fixture.root
            ),
            .uninstallingActive
        )
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .stale(identity),
                trustedRoot: fixture.root
            ),
            .uninstalling
        )
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .live(ControllerOperationClaimIdentity(
                    device: identity.device,
                    inode: identity.inode &+ 1
                )),
                trustedRoot: fixture.root
            ) else {
            return XCTFail("a replaced claim inode must fail closed")
        }
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .unknown("injected lsof error"),
                trustedRoot: fixture.root
            ) else {
            return XCTFail("an ambiguous holder observation must fail closed")
        }
    }

    func testOperationClaimHolderClassifierFailsClosed() {
        let first = ControllerOperationClaimIdentity(device: 7, inode: 11)
        let replacement = ControllerOperationClaimIdentity(device: 7, inode: 12)
        XCTAssertEqual(
            ControllerOperationClaimHolderClassifier
                .classifyAbsentWithoutHolderQuery(
                    before: nil,
                    after: nil
                ),
            .absent
        )
        XCTAssertEqual(
            ControllerOperationClaimHolderClassifier
                .classifyAbsentWithoutHolderQuery(
                    before: first,
                    after: first
                ),
            nil
        )
        guard case .unknown = ControllerOperationClaimHolderClassifier
            .classifyAbsentWithoutHolderQuery(
                before: nil,
                after: first
            ) else {
            return XCTFail("a claim created between absence checks must fail closed")
        }
        XCTAssertEqual(
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 0,
                stdout: Data("123\n456\n".utf8),
                stderr: Data(),
                before: first,
                after: first
            ),
            .live(first)
        )
        XCTAssertEqual(
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(),
                before: first,
                after: first
            ),
            .stale(first)
        )
        for observation in [
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 2,
                stdout: Data(),
                stderr: Data(),
                before: first,
                after: first
            ),
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 0,
                stdout: Data("not-a-pid\n".utf8),
                stderr: Data(),
                before: first,
                after: first
            ),
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 0,
                stdout: Data("123\n".utf8),
                stderr: Data("warning".utf8),
                before: first,
                after: first
            ),
            ControllerOperationClaimHolderClassifier.classify(
                terminationStatus: 0,
                stdout: Data("123\n".utf8),
                stderr: Data(),
                before: first,
                after: replacement
            )
        ] {
            guard case .unknown = observation else {
                return XCTFail("ambiguous lsof evidence must fail closed")
            }
        }
    }

    func testConcurrentUninstallAuthorizationRaceConsumesOnlyARealLaunch() {
        var tracker = ControllerUninstallAuthorizationTracker()
        XCTAssertEqual(
            tracker.action(for: .uninstallingActive),
            .observe
        )
        XCTAssertEqual(tracker.action(for: .uninstalling), .authorize)

        // The pre/post-authorization proof observed a newly active owner, so
        // AuthorizationExecuteWithPrivileges was never called.
        tracker.recordAuthorizationAttempt(launchedReviewedRunner: false)
        XCTAssertFalse(tracker.launchedReviewedRunner)
        XCTAssertEqual(
            tracker.action(for: .uninstallingActive),
            .observe
        )

        // Once that owner leaves a stale reviewed journal, exactly one launch
        // remains available. Further stale polls cannot start a second runner.
        XCTAssertEqual(tracker.action(for: .uninstalling), .authorize)
        tracker.recordAuthorizationAttempt(launchedReviewedRunner: true)
        XCTAssertTrue(tracker.launchedReviewedRunner)
        XCTAssertEqual(tracker.action(for: .uninstalling), .observe)
        XCTAssertEqual(tracker.action(for: .absent), .complete)
    }

    func testOperationClaimFinalAndNormalStatesAreClosed() throws {
        let fixture = try makeRootControllerStateFixture()
        let identity = try publishOperationClaim(in: fixture)

        guard case .exact = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .stale(identity),
                trustedRoot: fixture.root
            ) else {
            return XCTFail("an exact install may retain one stale claim")
        }
        guard case .unknown = try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                operationClaim: .live(identity),
                trustedRoot: fixture.root
            ) else {
            return XCTFail("a live normal operation must block readiness")
        }

        let runner = URL(fileURLWithPath: fixture.requirement.runner.path)
        let packageDirectory = URL(
            fileURLWithPath: fixture.requirement.controller.path
        ).deletingLastPathComponent()
        try FileManager.default.removeItem(at: runner)
        try FileManager.default.removeItem(at: packageDirectory)
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .absent,
                operationClaim: .live(identity),
                trustedRoot: fixture.root
            ),
            .uninstallingActive
        )
        XCTAssertEqual(
            try RootControllerInstallationVerifier.inspectForTesting(
                requirement: fixture.requirement,
                receipt: .absent,
                operationClaim: .stale(identity),
                trustedRoot: fixture.root
            ),
            .uninstallFinalizationRepairRequired
        )
    }

    func testAbsentJournalsStillRequireTrustedDatabaseAncestors() throws {
        let fixture = try makeRootControllerStateFixture()
        let journalDirectory = fixture.installJournal.deletingLastPathComponent()
        let acl = try makeExtendedACL()
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let descriptor = open(
            journalDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(
            acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED),
            0
        )

        XCTAssertThrowsError(try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ))
    }

    func testRootInstallationRejectsBenignNonzeroFileAndDirectoryFlags() throws {
        let fixture = try makeRootControllerStateFixture()
        let runner = URL(fileURLWithPath: fixture.requirement.runner.path)
        XCTAssertEqual(chflags(runner.path, UInt32(UF_NODUMP)), 0)
        XCTAssertThrowsError(try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ))
        XCTAssertEqual(chflags(runner.path, 0), 0)

        let packageDirectory = URL(
            fileURLWithPath: fixture.requirement.controller.path
        ).deletingLastPathComponent()
        XCTAssertEqual(chflags(packageDirectory.path, UInt32(UF_NODUMP)), 0)
        XCTAssertThrowsError(try RootControllerInstallationVerifier
            .inspectForTesting(
                requirement: fixture.requirement,
                receipt: .exact,
                trustedRoot: fixture.root
            ))
    }

    func testRepairFromInstallingControllerStateReopensProvider() async throws {
        let cancelled = FixtureControllerSetupProvider(
            initial: .absent,
            installOutcome: .cancel
        )
        await XCTAssertThrowsErrorAsync(
            try await makeEngine(
                controllerSetupProvider: cancelled
            ).createPatchedCopy()
        )

        let installing = FixtureControllerSetupProvider(initial: .installing)
        let repaired = try await makeEngine(
            importer: FailIfCalledImporter(),
            controllerSetupProvider: installing
        ).repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        let installCalls = await installing.installCalls
        XCTAssertEqual(installCalls, 1)
    }

    func testConfigurationMigrationSanitizesSettingsAndRewritesFileURLs() async throws {
        let sourceConfig = originalLibrary.appendingPathComponent(
            "Keymapping/com.vrchat.mobile/.config.plist"
        )
        let sourceConfigBefore = try Data(contentsOf: sourceConfig)
        let engine = try makeEngine()
        _ = try await engine.createPatchedCopy()

        let settings = try plistDictionary(at: patchedAppSettings)
        XCTAssertEqual(
            Set(settings.keys),
            SelectiveVRChatConfigurationMigrator.safeAppSettingKeys
        )
        for omitted in [
            "bypass",
            "injectIntrospection",
            "playChain",
            "playChainDebugging",
            "rootWorkDir",
            "futureUnknownSetting"
        ] {
            XCTAssertNil(settings[omitted])
        }

        let migratedConfig = try plistDictionary(
            at: patchedKeymapping.appendingPathComponent(".config.plist")
        )
        let defaultKm = try XCTUnwrap(migratedConfig["defaultKm"] as? [String: Any])
        let rewritten = try XCTUnwrap(defaultKm["relative"] as? String)
        XCTAssertEqual(
            rewritten,
            patchedKeymapping.appendingPathComponent("default.plist")
                .absoluteURL.absoluteString
        )
        XCTAssertFalse(rewritten.contains(originalLibrary.path))
        XCTAssertEqual(try Data(contentsOf: sourceConfig), sourceConfigBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: patchedLibrary.appendingPathComponent("PlayChain").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: patchedLibrary.appendingPathComponent("PlayTools").path
        ))
    }

    func testInstalledConfigurationIsMutableAndDoesNotBlockRemove() async throws {
        let engine = try makeEngine()
        let created = try await engine.createPatchedCopy()
        XCTAssertEqual(
            created.inspection.state,
            .fullyPatched
        )
        var settings = try plistDictionary(at: patchedAppSettings)
        settings["windowWidth"] = 1_600
        settings["playChain"] = false
        settings["futurePlayCoverSetting"] = "user-owned"
        try writePlist(settings, to: patchedAppSettings)

        let mutatedInspection = try await engine.inspect()
        XCTAssertEqual(mutatedInspection.state, .fullyPatched)
        _ = try await engine.removePatchedCopy()
        XCTAssertEqual(
            (try plistDictionary(at: patchedAppSettings))["windowWidth"]
                as? Int,
            1_600
        )
        XCTAssertEqual(
            (try plistDictionary(at: patchedAppSettings))[
                "futurePlayCoverSetting"
            ] as? String,
            "user-owned"
        )
    }

    func testConfigurationSymlinkIsRejectedBeforeMutation() async throws {
        let sourceEntitlement = originalLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.entitlementRelativePath
        )
        let external = root.appendingPathComponent("external-entitlement.plist")
        try FileManager.default.moveItem(at: sourceEntitlement, to: external)
        try FileManager.default.createSymbolicLink(
            at: sourceEntitlement,
            withDestinationURL: external
        )

        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected configuration symlink to fail closed")
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedLibrary.path))
    }

    func testConfigurationNonRegularKeymapEntryIsRejectedBeforeMutation() async throws {
        let unsupported = originalLibrary.appendingPathComponent(
            "Keymapping/com.vrchat.mobile/nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsupported,
            withIntermediateDirectories: true
        )

        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected keymap directory entry to fail closed")
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedLibrary.path))
    }

    func testMissingVRChatFailsBeforeAnyTransactionWrite() async throws {
        try FileManager.default.removeItem(at: sourceVRChat)
        let engine = try makeEngine()
        let inspection = try await engine.inspect()
        XCTAssertEqual(
            inspection.state,
            .vrChatMissing(sourceVRChat)
        )

        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            XCTAssertEqual($0 as? PatcherError, .vrChatMissing(self.sourceVRChat))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedLibrary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testUnsupportedVRChatFailsBeforeAnyTransactionWrite() async throws {
        try "foreign".write(
            to: sourceVRChat.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected unsupported VRChat classification")
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.identityMismatch = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testExcludedPlayToolsArtifactFailsBeforeAnyTransactionWrite() async throws {
        let excluded = sourceVRChat.appendingPathComponent(
            "Frameworks/PlayTools.framework/PlayTools"
        )
        try FileManager.default.createDirectory(
            at: excluded.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("excluded".utf8).write(to: excluded)
        let engine = try makeEngine()
        guard case .unknownModification(let reason) =
                try await engine.inspect().state else {
            return XCTFail("expected excluded artifact classification")
        }
        XCTAssertTrue(reason.lowercased().contains("playtools"))
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testImportInterruptionIsJournaledAndRepairRetriesCleanly() async throws {
        let interrupted = try makeEngine(importer: PartialFailingImporter())
        await XCTAssertThrowsErrorAsync(
            try await interrupted.createPatchedCopy()
        ) { error in
            guard case PatcherError.transactionFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        let interruptedInspection = try await interrupted.inspect()
        XCTAssertEqual(
            interruptedInspection.state,
            .repairRequired(.importingVRChat)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))

        let repairedEngine = try makeEngine()
        let repaired = try await repairedEngine.repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vrChatStagingURL.path
        ))
    }

    func testConfigurationInterruptionIsJournaledAndRepairRetriesCleanly() async throws {
        let interrupted = try makeEngine(
            configurationMigrator: PartialFailingConfigurationMigrator()
        )
        await XCTAssertThrowsErrorAsync(
            try await interrupted.createPatchedCopy()
        ) { error in
            guard case PatcherError.transactionFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        let interruptedInspection = try await interrupted.inspect()
        XCTAssertEqual(
            interruptedInspection.state,
            .repairRequired(.migratingConfiguration)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configurationStagingURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))

        let repaired = try await makeEngine().repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configurationStagingURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patchedAppSettings.path
        ))
    }

    func testCopyFallbackIsRecorded() async throws {
        let engine = try makeEngine(
            importer: FixtureImporter(strategy: .copyFallback)
        )
        let result = try await engine.createPatchedCopy()
        XCTAssertEqual(result.importStrategy, .copyFallback)
        XCTAssertEqual(result.inspection.state, .fullyPatched)
    }

    func testImporterHardLinksAreRejected() async throws {
        let engine = try makeEngine(importer: HardLinkingImporter())
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            if case PatcherError.hardLinkDetected = $0 { return }
            if case PatcherError.unknownModification(let reason) = $0,
               reason.contains("link count") { return }
            XCTFail("unexpected \($0)")
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertEqual(
            try String(
                contentsOf: originalApp.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "source"
        )
    }

    func testImportedLibraryMutationDoesNotBlockInstalledStateOrRemove() async throws {
        let engine = try makeEngine()
        _ = try await engine.createPatchedCopy()
        let relative = "Resources/asset.bin"
        let importedAsset = importedVRChat.appendingPathComponent(relative)
        try FileManager.default.removeItem(at: importedAsset)
        try FileManager.default.linkItem(
            at: sourceVRChat.appendingPathComponent(relative),
            to: importedAsset
        )

        let mutatedInspection = try await engine.inspect()
        XCTAssertEqual(mutatedInspection.state, .fullyPatched)
        _ = try await engine.removePatchedCopy()
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedAsset.path))
    }

    func testProductionCloneFirstImporterNeverCreatesHardLinks() throws {
        let destination = root.appendingPathComponent(
            "Native Import/com.vrchat.mobile.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let strategy = try CloneFirstVRChatImporter().copyTree(
            from: sourceVRChat,
            to: destination
        )
        XCTAssertTrue([.clone, .copyFallback].contains(strategy))
        XCTAssertNoThrow(try CloneFirstVRChatImporter.rejectHardLinks(
            from: sourceVRChat,
            to: destination
        ))
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(sourceVRChat),
            try AppTreeVerifier.treeSHA256(destination)
        )
    }

    func testUnknownParallelTargetIsNeverOverwrittenOrRemoved() async throws {
        try makeApp(patchedApp, marker: "foreign")
        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected unknown target")
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await engine.removePatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertEqual(
            try String(
                contentsOf: patchedApp.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "foreign"
        )
    }

    func testUnknownRetainedLibraryIsNeverOverwritten() async throws {
        try makeVRChat(importedVRChat, marker: "foreign")
        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected unknown retained library")
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unknownModification = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertEqual(
            try String(
                contentsOf: importedVRChat.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "foreign"
        )
    }

    func testPortableButTreeDifferentRetainedLibraryIsNeverAccepted() async throws {
        try FileManager.default.createDirectory(
            at: importedVRChat.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceVRChat, to: importedVRChat)
        try "unexpected".write(
            to: importedVRChat.appendingPathComponent("unexpected-resource"),
            atomically: true,
            encoding: .utf8
        )
        let engine = try makeEngine()
        guard case .unknownModification = try await engine.inspect().state else {
            return XCTFail("expected full-tree mismatch to fail closed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testRetainedExactLibraryIsReusedAfterRemove() async throws {
        let engine = try makeEngine()
        _ = try await engine.createPatchedCopy()
        _ = try await engine.removePatchedCopy()

        var retainedSettings = try plistDictionary(at: patchedAppSettings)
        retainedSettings["customScaler"] = 3.0
        try writePlist(retainedSettings, to: patchedAppSettings)

        let recreated = try await engine.createPatchedCopy()
        XCTAssertEqual(recreated.importStrategy, .existingVerified)
        XCTAssertEqual(recreated.inspection.state, .fullyPatched)
        XCTAssertEqual(
            (try plistDictionary(at: patchedAppSettings))["customScaler"]
                as? Double,
            3.0
        )
    }

    func testInterruptedRemovalRepairRestoresExactPatchedApp() async throws {
        let engine = try makeEngine()
        _ = try await engine.createPatchedCopy()
        let removal = removalStagingURL
        try FileManager.default.moveItem(at: patchedApp, to: removal)
        try writeJournal(operation: "removePatchedCopy", phase: "removalStaged")

        let interruptedInspection = try await engine.inspect()
        XCTAssertEqual(
            interruptedInspection.state,
            .repairRequired(.removalStaged)
        )
        let repaired = try await engine.repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVRChat.path))
    }

    func testExactInstallWithoutReceiptIsRepairable() async throws {
        try FileManager.default.copyItem(at: payload, to: patchedApp)
        try FileManager.default.createDirectory(
            at: importedVRChat.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceVRChat, to: importedVRChat)
        let engine = try makeEngine()
        let beforeRepair = try await engine.inspect()
        XCTAssertEqual(
            beforeRepair.state,
            .repairRequired(.verified)
        )
        let repaired = try await engine.repair()
        XCTAssertEqual(repaired.inspection.state, .fullyPatched)
    }

    func testRunningApplicationsBlockAllMutation() async throws {
        let engine = try makeEngine(running: ["PlayCover VRChat", "VRChat"])
        let inspection = try await engine.inspect()
        XCTAssertEqual(
            inspection.state,
            .busy(["PlayCover VRChat", "VRChat"])
        )
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            XCTAssertEqual(
                $0 as? PatcherError,
                .applicationsRunning(["PlayCover VRChat", "VRChat"])
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testUnsupportedRuntimeIsReportedWithoutMutation() async throws {
        let runtime = RuntimeSnapshot(
            macOSVersion: "27.0",
            macOSBuild: "99A1",
            xnuVersion: "unknown",
            architecture: "x86_64",
            physicalMemoryBytes: 4 * 1_073_741_824
        )
        let engine = try makeEngine(runtime: runtime)
        guard case .unsupportedRuntime(let reasons) = try await engine.inspect().state else {
            return XCTFail("expected unsupported runtime")
        }
        XCTAssertGreaterThanOrEqual(reasons.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testNewMacOSBuildIsNotRejectedByTestedHostMetadata() async throws {
        let runtime = RuntimeSnapshot(
            macOSVersion: "26.6.2",
            macOSBuild: "25G82",
            xnuVersion: "Darwin Kernel Version 25.6.0: xnu-12377.161.14~5",
            architecture: "arm64",
            physicalMemoryBytes: 24 * 1_073_741_824
        )
        let engine = try makeEngine(runtime: runtime)
        let inspection = try await engine.inspect()
        XCTAssertEqual(inspection.state, .readyToCreate)
    }

    func testSourceOnlyManifestCanInspectButCannotCreate() async throws {
        let engine = try PatcherEngine(
            manifest: .sourceOnlyFixture,
            paths: paths,
            verifier: MarkerAppVerifier(),
            vrChatVerifier: MarkerVRChatVerifier(),
            importer: FixtureImporter(strategy: .clone),
            runtimeProvider: FixedRuntimeProvider(value: .supportedFixture),
            processInspector: FixedProcessInspector(names: [])
        )
        let inspection = try await engine.inspect()
        XCTAssertEqual(inspection.state, .payloadUnavailable)
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            XCTAssertEqual($0 as? PatcherError, .payloadUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testPathOverlapIsRejectedWithoutDeletion() async throws {
        let unsafePaths = PatcherPaths(
            originalApp: originalApp,
            patchedApp: patchedApp,
            patchedPayload: payload,
            controllerPackage: controllerPackage,
            applicationSupport: originalLibrary,
            originalLibrary: originalLibrary,
            patchedLibrary: patchedLibrary
        )
        let engine = try PatcherEngine(
            manifest: .fixture,
            paths: unsafePaths,
            verifier: MarkerAppVerifier(),
            vrChatVerifier: MarkerVRChatVerifier(),
            importer: FixtureImporter(strategy: .clone),
            runtimeProvider: FixedRuntimeProvider(value: .supportedFixture),
            processInspector: FixedProcessInspector(names: [])
        )
        await XCTAssertThrowsErrorAsync(try await engine.inspect()) {
            guard case PatcherError.unsafePath = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalApp.path))
    }

    func testStagingSymlinkToOriginalIsRejectedWithoutWriting() async throws {
        let originalBefore = try AppTreeVerifier.treeSHA256(originalApp)
        try FileManager.default.createSymbolicLink(
            at: appStagingURL,
            withDestinationURL: originalApp
        )
        let engine = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await engine.inspect()) {
            guard case PatcherError.unsafePath = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unsafePath = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalApp),
            originalBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testIndependentApplicationsAncestorSymlinkCannotEscape() async throws {
        let originalBefore = try AppTreeVerifier.treeSHA256(originalLibrary)
        try FileManager.default.createDirectory(
            at: patchedLibrary,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: patchedLibrary.appendingPathComponent("Applications"),
            withDestinationURL: originalLibrary.appendingPathComponent(
                "Applications"
            )
        )
        let engine = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unsafePath = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalLibrary),
            originalBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testPatchRootAncestorSymlinkCannotEscape() async throws {
        let originalBefore = try AppTreeVerifier.treeSHA256(originalLibrary)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: patchRoot,
            withDestinationURL: originalLibrary
        )
        let engine = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await engine.createPatchedCopy()) {
            guard case PatcherError.unsafePath = $0 else {
                return XCTFail("unexpected \($0)")
            }
        }
        XCTAssertEqual(
            try AppTreeVerifier.treeSHA256(originalLibrary),
            originalBefore
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testJournalBoundStagingSwapIsNeverDeleted() async throws {
        let interrupted = try makeEngine(importer: PartialFailingImporter())
        await XCTAssertThrowsErrorAsync(
            try await interrupted.createPatchedCopy()
        )
        let displaced = vrChatStagingURL.deletingLastPathComponent()
            .appendingPathComponent("displaced-owned-staging", isDirectory: true)
        try FileManager.default.moveItem(at: vrChatStagingURL, to: displaced)
        try FileManager.default.createDirectory(
            at: vrChatStagingURL,
            withIntermediateDirectories: true
        )
        let sentinel = vrChatStagingURL.appendingPathComponent("do-not-delete")
        try Data("foreign".utf8).write(to: sentinel)

        let repairing = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await repairing.repair()) {
            guard case PatcherError.unknownModification(let reason) = $0 else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertTrue(reason.contains("replaced") || reason.contains("modified"))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testWorldWritablePayloadMetadataIsRejected() async throws {
        XCTAssertEqual(chmod(payload.path, 0o777), 0)
        let engine = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await engine.inspect()) {
            guard case PatcherError.unknownModification(let reason) = $0 else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertTrue(reason.contains("writable"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testPayloadExtendedACLIsRejected() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", payload.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let engine = try makeEngine()
        await XCTAssertThrowsErrorAsync(try await engine.inspect()) {
            guard case PatcherError.unknownModification(let reason) = $0 else {
                return XCTFail("unexpected \($0)")
            }
            XCTAssertTrue(reason.contains("ACL"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: patchedApp.path))
    }

    func testEntitlementFramingIsDeterministicAndHomeIndependent() throws {
        let first: [String: Any] = [
            "z.array": ["hello", "/Users/alice/path"],
            "a.bool": true
        ]
        let second: [String: Any] = [
            "a.bool": true,
            "z.array": ["hello", "/Users/bob/path"]
        ]
        let firstHash = try EntitlementsCanonicalizer.canonicalSHA256(
            of: first,
            homeDirectory: URL(fileURLWithPath: "/Users/alice")
        )
        let secondHash = try EntitlementsCanonicalizer.canonicalSHA256(
            of: second,
            homeDirectory: URL(fileURLWithPath: "/Users/bob")
        )
        XCTAssertEqual(firstHash, secondHash)
        XCTAssertEqual(
            firstHash,
            "c016eb3e2bd0b90bd540540a776cbaa3301cbdd2aa32d70e89b0f9504139cf8a"
        )
    }

    func testReviewedLocalVRChatPortableIdentityWhenFixtureIsAvailable() throws {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.playcover.PlayCover/Applications/com.vrchat.mobile.app",
                isDirectory: true
            )
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw XCTSkip("reviewed local VRChat fixture is not installed")
        }
        XCTAssertNoThrow(try VRChatArtifactScanner.verifyClean(local))
        let actual = try VRChatAppVerifier().identity(
            of: local,
            expected: .reviewedFixture
        )
        XCTAssertNil(actual.mismatch(from: .reviewedFixture))
        XCTAssertEqual(
            actual.mainIdentity.normalizedUnsignedSHA256,
            "cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3"
        )
        XCTAssertEqual(
            actual.mainIdentity.entitlementsSHA256,
            "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4"
        )
        XCTAssertEqual(actual.machoAllowlist, .reviewed)
        let originalLibrary = local.deletingLastPathComponent()
            .deletingLastPathComponent()
        let destinationLibrary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat",
                isDirectory: true
            )
        let configuration = try SelectiveVRChatConfigurationMigrator()
            .validateSource(
                in: originalLibrary,
                destinationLibrary: destinationLibrary
            )
        XCTAssertTrue(AppIdentity.isSHA256(configuration.sha256))
    }

    func testMachOAllowlistRejectsExtraAndTamperedCode() throws {
        let reviewedApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/io.playcover.PlayCover/Applications/com.vrchat.mobile.app",
                isDirectory: true
            )
        let reviewedBinary = reviewedApp.appendingPathComponent(
            "Frameworks/_bisect.framework/_bisect"
        )
        guard FileManager.default.fileExists(atPath: reviewedBinary.path) else {
            throw XCTSkip("reviewed Mach-O fixture is not installed")
        }
        let fixture = root.appendingPathComponent(
            "MachO Allowlist Fixture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true
        )
        let first = fixture.appendingPathComponent("first")
        try FileManager.default.copyItem(at: reviewedBinary, to: first)
        let baseline = try MachOAllowlistVerifier.identity(of: fixture)
        XCTAssertEqual(baseline.count, 1)

        let extra = fixture.appendingPathComponent("extra")
        try FileManager.default.copyItem(at: reviewedBinary, to: extra)
        let withExtra = try MachOAllowlistVerifier.identity(of: fixture)
        XCTAssertEqual(withExtra.count, 2)
        XCTAssertNotEqual(withExtra.digestSHA256, baseline.digestSHA256)
        try FileManager.default.removeItem(at: extra)

        var bytes = try Data(contentsOf: first)
        guard bytes.count > 8_192 else {
            throw XCTSkip("reviewed Mach-O fixture is unexpectedly small")
        }
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: first)
        let tampered = try MachOAllowlistVerifier.identity(of: fixture)
        XCTAssertEqual(tampered.count, 1)
        XCTAssertNotEqual(tampered.digestSHA256, baseline.digestSHA256)
    }

    func testJournalSurvivesPatcherPayloadRelocation() async throws {
        let engine = try makeEngine()
        _ = try await engine.createPatchedCopy()

        // A journal can outlive the Patcher bundle that created it. The
        // payload path is an audit breadcrumb, not a recovery input; a new
        // Patcher copy must verify its own payload instead of rejecting this
        // otherwise valid transaction solely because its absolute path moved.
        try writeJournal(operation: "repair", phase: "appPublished")
        var journal = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: transactionJournalURL)
            ) as? [String: Any]
        )
        journal["payloadPath"] = root
            .appendingPathComponent("Previous Patcher/Payload/PlayCover.app")
            .path
        try JSONSerialization.data(
            withJSONObject: journal,
            options: [.sortedKeys]
        ).write(to: transactionJournalURL, options: .atomic)

        let inspection = try await engine.inspect()
        XCTAssertEqual(inspection.state, .repairRequired(.appPublished))
    }

    private func makeEngine(
        importer: any VRChatTreeImporting = FixtureImporter(strategy: .clone),
        configurationMigrator: any VRChatConfigurationMigrating =
            SelectiveVRChatConfigurationMigrator(),
        running: [String] = [],
        runtime: RuntimeSnapshot = .supportedFixture,
        controllerSetupProvider: any ControllerSetupProviding =
            FixtureControllerSetupProvider(initial: .exact(.fixture))
    ) throws -> PatcherEngine {
        try PatcherEngine(
            manifest: .fixture,
            paths: paths,
            verifier: MarkerAppVerifier(),
            vrChatVerifier: MarkerVRChatVerifier(),
            importer: importer,
            configurationMigrator: configurationMigrator,
            runtimeProvider: FixedRuntimeProvider(value: runtime),
            processInspector: FixedProcessInspector(names: running),
            controllerSetupProvider: controllerSetupProvider
        )
    }

    private var paths: PatcherPaths {
        PatcherPaths(
            originalApp: originalApp,
            patchedApp: patchedApp,
            patchedPayload: payload,
            controllerPackage: controllerPackage,
            applicationSupport: support,
            originalLibrary: originalLibrary,
            patchedLibrary: patchedLibrary
        )
    }

    private var patchRoot: URL {
        support.appendingPathComponent("test-patch", isDirectory: true)
    }

    private var receiptURL: URL {
        patchRoot.appendingPathComponent("receipt.json")
    }

    private var transactionJournalURL: URL {
        patchRoot.appendingPathComponent("transaction.json")
    }

    private var appStagingURL: URL {
        applications.appendingPathComponent(
            ".pcvr-test-patch-app-staging.app",
            isDirectory: true
        )
    }

    private var removalStagingURL: URL {
        applications.appendingPathComponent(
            ".pcvr-test-patch-remove-staging.app",
            isDirectory: true
        )
    }

    private var vrChatStagingURL: URL {
        importedVRChat.deletingLastPathComponent().appendingPathComponent(
            ".pcvr-test-patch-vrchat-import.app",
            isDirectory: true
        )
    }

    private var configurationStagingURL: URL {
        patchedLibrary.appendingPathComponent(
            ".pcvr-test-patch-configuration-staging",
            isDirectory: true
        )
    }

    private var patchedEntitlement: URL {
        patchedLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.entitlementRelativePath
        )
    }

    private var patchedAppSettings: URL {
        patchedLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.appSettingsRelativePath
        )
    }

    private var patchedKeymapping: URL {
        patchedLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.keymappingRelativePath,
            isDirectory: true
        )
    }

    private func makeApp(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try marker.write(
            to: url.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeVRChat(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try marker.write(
            to: url.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
        try Data("asset".utf8).write(
            to: url.appendingPathComponent("Resources/asset.bin")
        )
    }

    private func makeVRChatConfiguration() throws {
        let entitlement = originalLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.entitlementRelativePath
        )
        try writePlist(
            ["com.apple.security.network.client": true],
            to: entitlement
        )

        var settings = safeSettingsFixture
        settings["bypass"] = false
        settings["injectIntrospection"] = false
        settings["playChain"] = true
        settings["playChainDebugging"] = false
        settings["rootWorkDir"] = true
        settings["futureUnknownSetting"] = "must not migrate"
        try writePlist(
            settings,
            to: originalLibrary.appendingPathComponent(
                SelectiveVRChatConfigurationMigrator.appSettingsRelativePath
            )
        )

        let sourceKeymapping = originalLibrary.appendingPathComponent(
            SelectiveVRChatConfigurationMigrator.keymappingRelativePath,
            isDirectory: true
        )
        let defaultKeymap = sourceKeymapping.appendingPathComponent(
            "default.plist"
        )
        try writePlist(["buttons": ["jump"]], to: defaultKeymap)
        let sourceURL = defaultKeymap.absoluteURL.absoluteString
        try writePlist(
            [
                "defaultKm": ["relative": sourceURL],
                "keymapOrder": [["relative": sourceURL]]
            ],
            to: sourceKeymapping.appendingPathComponent(".config.plist")
        )
    }

    private var safeSettingsFixture: [String: Any] {
        [
            "aspectRatio": 1,
            "bundleIdentifier": "com.vrchat.mobile",
            "customScaler": 2.0,
            "disableBuiltinMouse": false,
            "displayRotation": 0,
            "enableScrollWheel": true,
            "floatingWindow": false,
            "hideTitleBar": false,
            "inverseScreenValues": false,
            "keymapping": true,
            "noKMOnInput": true,
            "notch": true,
            "resizableAspectRatioHeight": 0,
            "resizableAspectRatioType": 0,
            "resizableAspectRatioWidth": 0,
            "resolution": 1,
            "sensitivity": 50.0,
            "version": "3.0.0",
            "windowHeight": 1080,
            "windowWidth": 1920
        ]
    }

    private func writePlist(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: [.atomic])
    }

    private func receiptJSONObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: receiptURL)
            ) as? [String: Any]
        )
    }

    private func createFinalStaleClaimRemoveJournal() async throws {
        let interrupted = FixtureControllerSetupProvider(
            initial: .exact(.fixture),
            uninstallOutcome: .leaveFinalizationRepairRequired
        )
        let engine = try makeEngine(controllerSetupProvider: interrupted)
        _ = try await engine.createPatchedCopy()
        do {
            _ = try await engine.removePatchedCopy()
            XCTFail("injected final stale claim must interrupt Remove")
        } catch {
            // Expected: the user-side Remove journal remains durable.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchedApp.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: transactionJournalURL.path
        ))
    }

    private func writeJSONObject(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func makeExtendedACL() throws -> acl_t {
        let template = root.appendingPathComponent("acl-template")
        try Data("acl".utf8).write(to: template)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", template.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let acl = template.path.withCString({
                acl_get_file($0, ACL_TYPE_EXTENDED)
              }) else {
            throw PatcherError.transactionFailed(
                "cannot create the extended ACL test fixture"
            )
        }
        return acl
    }

    private struct RootControllerStateFixture {
        let root: URL
        let requirement: ControllerPackageRequirement
        let installJournal: URL
        let uninstallJournal: URL
        let operationClaim: URL
        let installJournalData: Data
        let uninstallJournalData: Data
        let operationClaimData: Data
    }

    private func makeRootControllerStateFixture() throws
        -> RootControllerStateFixture {
        let stateRoot = root.appendingPathComponent(
            "root-controller-state",
            isDirectory: true
        )
        let runner = stateRoot.appendingPathComponent(
            "usr/local/bin/playcover-vrchat-memory-policy"
        )
        let packageDirectory = stateRoot.appendingPathComponent(
            "usr/local/libexec/playcover-vrchat-memory-policy",
            isDirectory: true
        )
        let controller = packageDirectory.appendingPathComponent("controller")
        let attestation = packageDirectory.appendingPathComponent(
            "installation.json"
        )
        let controllerQuarantine = packageDirectory.appendingPathComponent(
            ".controller.pcvr-install"
        )
        let runnerQuarantine = runner.deletingLastPathComponent()
            .appendingPathComponent(
                ".playcover-vrchat-memory-policy.pcvr-install"
            )
        let journalDirectory = stateRoot.appendingPathComponent(
            "private/var/db",
            isDirectory: true
        )
        let installJournal = journalDirectory.appendingPathComponent(
            "io.github.northstarxyzz.pcvrpatcher.memory-policy.install"
        )
        let uninstallJournal = journalDirectory.appendingPathComponent(
            "io.github.northstarxyzz.pcvrpatcher.memory-policy.uninstall"
        )
        let operationClaim = journalDirectory.appendingPathComponent(
            "io.github.northstarxyzz.pcvrpatcher.memory-policy.operation"
        )
        for directory in [
            runner.deletingLastPathComponent(),
            packageDirectory,
            journalDirectory
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
        // Normalize every reviewed ancestor under the test trust anchor.
        var current = stateRoot
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: current.path
        )
        for relative in [
            "usr", "usr/local", "usr/local/bin", "usr/local/libexec",
            "usr/local/libexec/playcover-vrchat-memory-policy",
            "private", "private/var", "private/var/db"
        ] {
            current = stateRoot.appendingPathComponent(
                relative,
                isDirectory: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: current.path
            )
        }

        let runnerData = Data("runner-r6".utf8)
        let controllerData = Data("controller-r6".utf8)
        let attestationData = Data("attestation-r6".utf8)
        try runnerData.write(to: runner)
        try controllerData.write(to: controller)
        try attestationData.write(to: attestation)
        for (url, mode) in [
            (runner, 0o555),
            (controller, 0o500),
            (attestation, 0o444)
        ] {
            try FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: url.path
            )
        }
        let installJournalData = Data("install-journal-r6".utf8)
        let uninstallJournalData = Data("uninstall-journal-r6".utf8)
        let operationClaimData = Data("operation-claim-r6".utf8)
        let uid = UInt32(getuid())
        let gid = UInt32(getgid())
        let artifact: (URL, Data, String) -> RootArtifactRequirement = {
            url, data, mode in
            RootArtifactRequirement(
                path: url.path,
                sha256: SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined(),
                uid: uid,
                gid: gid,
                mode: mode
            )
        }
        let requirement = ControllerPackageRequirement(
            relativePath: "Controller/PlayCoverVRChatMemoryPolicy.pkg",
            identifier: "io.github.northstarxyzz.pcvrpatcher.memory-policy",
            version: "0.1.0",
            sha256:
                "dac659b8ad876000a547024da1606ab59ad3dd73655ce84e7674b1aec86d81df",
            controllerBuildID: "capability-vrchat-2026.2.30300-1365-r7",
            controllerQuarantinePath: controllerQuarantine.path,
            runnerQuarantinePath: runnerQuarantine.path,
            runner: artifact(runner, runnerData, "0555"),
            controller: artifact(controller, controllerData, "0500"),
            attestation: artifact(attestation, attestationData, "0444"),
            installJournal: artifact(
                installJournal,
                installJournalData,
                "0400"
            ),
            uninstallJournal: artifact(
                uninstallJournal,
                uninstallJournalData,
                "0400"
            ),
            operationClaim: artifact(
                operationClaim,
                operationClaimData,
                "0400"
            ),
            timeoutSeconds: 900,
            pollMilliseconds: 500
        )
        return RootControllerStateFixture(
            root: stateRoot,
            requirement: requirement,
            installJournal: installJournal,
            uninstallJournal: uninstallJournal,
            operationClaim: operationClaim,
            installJournalData: installJournalData,
            uninstallJournalData: uninstallJournalData,
            operationClaimData: operationClaimData
        )
    }

    private func publishOperationClaim(
        in fixture: RootControllerStateFixture
    ) throws -> ControllerOperationClaimIdentity {
        try fixture.operationClaimData.write(to: fixture.operationClaim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.operationClaim.path
        )
        var status = stat()
        guard fixture.operationClaim.path.withCString({
            lstat($0, &status)
        }) == 0 else {
            throw PatcherError.transactionFailed(
                "cannot inspect the operation-claim fixture"
            )
        }
        return ControllerOperationClaimIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino)
        )
    }

    private func plistDictionary(at url: URL) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: Any])
    }

    private func writeJournal(operation: String, phase: String) throws {
        try FileManager.default.createDirectory(
            at: patchRoot,
            withIntermediateDirectories: true
        )
        var object: [String: Any] = [
            "schemaVersion": 5,
            "patchID": "test-patch",
            "operation": operation,
            "phase": phase,
            "originalAppPath": originalApp.path,
            "patchedAppPath": patchedApp.path,
            "payloadPath": payload.path,
            "appStagingPath": appStagingURL.path,
            "removalStagingPath": removalStagingURL.path,
            "vrChatSourcePath": sourceVRChat.path,
            "vrChatDestinationPath": importedVRChat.path,
            "vrChatStagingPath": vrChatStagingURL.path,
            "configurationStagingPath": configurationStagingURL.path,
            "importStrategy": "clone"
        ]
        if FileManager.default.fileExists(atPath: appStagingURL.path) {
            object["appStagingBinding"] = try bindingObject(appStagingURL)
        }
        if FileManager.default.fileExists(atPath: removalStagingURL.path) {
            object["removalStagingBinding"] = try bindingObject(
                removalStagingURL
            )
        }
        if FileManager.default.fileExists(atPath: vrChatStagingURL.path) {
            object["vrChatStagingBinding"] = try bindingObject(vrChatStagingURL)
        }
        if FileManager.default.fileExists(atPath: configurationStagingURL.path) {
            object["configurationStagingBinding"] = try bindingObject(
                configurationStagingURL
            )
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: patchRoot.appendingPathComponent("transaction.json"),
            options: .atomic
        )
    }

    private func bindingObject(_ url: URL) throws -> [String: Any] {
        let binding = try SecureTreeAuditor.binding(for: url)
        return [
            "device": binding.device,
            "inode": binding.inode,
            "ownerUID": binding.ownerUID,
            "mode": binding.mode,
            "contentSHA256": binding.contentSHA256,
            "metadataSHA256": binding.metadataSHA256
        ]
    }
}

private struct MarkerAppVerifier: TreeVerifying {
    func identity(of appURL: URL) throws -> AppIdentity {
        _ = try SecureTreeAuditor.inspect(appURL)
        let marker = try String(
            contentsOf: appURL.appendingPathComponent("marker"),
            encoding: .utf8
        )
        switch marker {
        case "source": return .sourceFixture
        case "patched": return .patchedFixture
        default:
            return AppIdentity(
                bundleIdentifier: "invalid.foreign",
                shortVersion: "0",
                buildVersion: "0",
                executableName: "Unknown",
                executableSHA256: String(repeating: "f", count: 64),
                executableUUID: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
                treeSHA256: String(repeating: "f", count: 64)
            )
        }
    }
}

private struct MarkerVRChatVerifier: VRChatVerifying {
    func identity(
        of appURL: URL,
        expected: VRChatIdentity
    ) throws -> ObservedVRChatIdentity {
        _ = try SecureTreeAuditor.inspect(appURL)
        let marker = try String(
            contentsOf: appURL.appendingPathComponent("marker"),
            encoding: .utf8
        )
        let tree = try AppTreeVerifier.treeSHA256(appURL)
        if marker == "vrchat" {
            return ObservedVRChatIdentity(
                bundleIdentifier: expected.bundleIdentifier,
                shortVersion: expected.shortVersion,
                buildVersion: expected.buildVersion,
                executableName: expected.executableName,
                mainIdentity: expected.mainIdentity,
                unityFramework: expected.unityFramework,
                appdomeLibloader: expected.appdomeLibloader,
                machoAllowlist: expected.machoAllowlist,
                treeSHA256: tree
            )
        }
        return ObservedVRChatIdentity(
            bundleIdentifier: "foreign.vrchat",
            shortVersion: "0",
            buildVersion: "0",
            executableName: "Foreign",
            mainIdentity: expected.mainIdentity,
            unityFramework: expected.unityFramework,
            appdomeLibloader: expected.appdomeLibloader,
            machoAllowlist: expected.machoAllowlist,
            treeSHA256: tree
        )
    }
}

private struct FixtureImporter: VRChatTreeImporting {
    let strategy: VRChatImportStrategy

    func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy {
        try FileManager.default.copyItem(at: source, to: destination)
        return strategy
    }
}

private struct FailIfCalledImporter: VRChatTreeImporting {
    func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy {
        throw PatcherError.transactionFailed(
            "importer must not run during controller-only Repair"
        )
    }
}

private struct PartialFailingImporter: VRChatTreeImporting {
    func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy {
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try "partial".write(
            to: destination.appendingPathComponent("marker"),
            atomically: true,
            encoding: .utf8
        )
        throw PatcherError.transactionFailed("injected import interruption")
    }
}

private struct HardLinkingImporter: VRChatTreeImporting {
    func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(atPath: source.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let relative as String in enumerator {
            let sourceEntry = source.appendingPathComponent(relative)
            let destinationEntry = destination.appendingPathComponent(relative)
            let values = try sourceEntry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationEntry,
                    withIntermediateDirectories: true
                )
            } else if values.isRegularFile == true {
                try fileManager.linkItem(at: sourceEntry, to: destinationEntry)
            }
        }
        return .clone
    }
}

private struct PartialFailingConfigurationMigrator:
    VRChatConfigurationMigrating {
    private let concrete = SelectiveVRChatConfigurationMigrator()

    func validateSource(
        in originalLibrary: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity {
        try concrete.validateSource(
            in: originalLibrary,
            destinationLibrary: destinationLibrary
        )
    }

    func stageConfiguration(
        from originalLibrary: URL,
        to stagingRoot: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity {
        let relative =
            SelectiveVRChatConfigurationMigrator.entitlementRelativePath
        let source = originalLibrary.appendingPathComponent(relative)
        let destination = stagingRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        throw PatcherError.transactionFailed(
            "injected configuration migration interruption"
        )
    }

    func inspectConfiguration(
        at root: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationState {
        try concrete.inspectConfiguration(
            at: root,
            destinationLibrary: destinationLibrary
        )
    }
}

private struct FixedRuntimeProvider: RuntimeProviding {
    let value: RuntimeSnapshot
    func snapshot() throws -> RuntimeSnapshot { value }
}

private struct FixedProcessInspector: ProcessInspecting {
    let names: [String]
    func runningProtectedApplications() -> [String] { names }
}

private actor FixtureControllerSetupProvider: ControllerSetupProviding {
    enum InstallOutcome: Sendable {
        case succeed
        case cancel
        case fail
        case timeOut
    }

    enum UninstallOutcome: Sendable {
        case succeed
        case cancel
        case fail
        case leaveUninstalling
        case leaveUninstallingActive
        case observeActiveThenSucceed
        case leaveFinalizationRepairRequired
    }

    private var state: ControllerInstallationState
    private let installOutcome: InstallOutcome
    private let uninstallOutcome: UninstallOutcome
    private(set) var installCalls = 0
    private(set) var uninstallCalls = 0
    private(set) var destructiveUninstallCalls = 0

    init(
        initial: ControllerInstallationState,
        installOutcome: InstallOutcome = .succeed,
        uninstallOutcome: UninstallOutcome = .succeed
    ) {
        state = initial
        self.installOutcome = installOutcome
        self.uninstallOutcome = uninstallOutcome
    }

    func inspect(
        requirement: ControllerPackageRequirement
    ) async throws -> ControllerInstallationState {
        state
    }

    func install(_ request: ControllerSetupRequest) async throws {
        installCalls += 1
        switch installOutcome {
        case .succeed:
            state = .exact(.fixture)
        case .cancel:
            throw PatcherError.controllerSetupCancelled
        case .fail:
            throw PatcherError.controllerSetupFailed("injected failure")
        case .timeOut:
            throw PatcherError.controllerSetupTimedOut
        }
    }

    func uninstall(
        requirement: ControllerPackageRequirement
    ) async throws {
        uninstallCalls += 1
        switch uninstallOutcome {
        case .succeed:
            destructiveUninstallCalls += 1
            state = .absent
        case .cancel:
            destructiveUninstallCalls += 1
            throw PatcherError.controllerSetupCancelled
        case .fail:
            destructiveUninstallCalls += 1
            throw PatcherError.controllerSetupFailed("injected uninstall")
        case .leaveUninstalling:
            destructiveUninstallCalls += 1
            state = .uninstalling
        case .leaveUninstallingActive:
            destructiveUninstallCalls += 1
            state = .uninstallingActive
        case .observeActiveThenSucceed:
            state = .absent
        case .leaveFinalizationRepairRequired:
            destructiveUninstallCalls += 1
            state = .uninstallFinalizationRepairRequired
        }
    }

    func setState(_ newState: ControllerInstallationState) {
        state = newState
    }
}

private extension RuntimeSnapshot {
    static let supportedFixture = RuntimeSnapshot(
        macOSVersion: "26.6",
        macOSBuild: "25G70",
        xnuVersion: "Darwin Kernel xnu-12377.161.13~4",
        architecture: "arm64",
        physicalMemoryBytes: 24 * 1_073_741_824
    )
}

private extension AppIdentity {
    static let sourceFixture = AppIdentity(
        bundleIdentifier: "io.playcover.PlayCover",
        shortVersion: "3.1.0",
        buildVersion: "856",
        executableName: "PlayCover",
        executableSHA256: String(repeating: "a", count: 64),
        executableUUID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        treeSHA256: String(repeating: "b", count: 64),
        repository: "https://github.com/PlayCover/PlayCover.git",
        commit: "55638e98f36eac1f3d09803799480e9d83f663f8",
        infoPlistSHA256: String(repeating: "e", count: 64),
        codeResourcesSHA256: String(repeating: "f", count: 64)
    )

    static let patchedFixture = AppIdentity(
        bundleIdentifier: "io.github.northstarxyzz.PlayCoverVRChat",
        shortVersion: "3.1.0",
        buildVersion: "856",
        executableName: "PlayCover VRChat",
        executableSHA256: String(repeating: "c", count: 64),
        executableUUID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
        treeSHA256: String(repeating: "d", count: 64),
        infoPlistSHA256: String(repeating: "1", count: 64),
        codeResourcesSHA256: String(repeating: "2", count: 64)
    )
}

private extension VRChatIdentity {
    static let fixture = VRChatIdentity(
        bundleIdentifier: "com.vrchat.mobile",
        shortVersion: "2026.2.30300",
        buildVersion: "1365",
        sourceAppRelativePath:
            "Library/Containers/io.playcover.PlayCover/Applications/com.vrchat.mobile.app",
        destinationAppRelativePath:
            "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/com.vrchat.mobile.app",
        executableName: "VRChat",
        mainIdentity: PortableMachOIdentity(
            uuid: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB",
            normalizedUnsignedSHA256: String(repeating: "1", count: 64),
            loadCommandsSHA256: String(repeating: "2", count: 64),
            entitlementsSHA256: String(repeating: "3", count: 64)
        ),
        unityFramework: ReviewedBinaryIdentity(
            relativePath: "Frameworks/UnityFramework.framework/UnityFramework",
            sha256: String(repeating: "4", count: 64),
            uuid: "BBBBBBBB-1111-2222-3333-CCCCCCCCCCCC"
        ),
        appdomeLibloader: ReviewedBinaryIdentity(
            relativePath: "Frameworks/libloader.framework/libloader",
            sha256: String(repeating: "5", count: 64),
            uuid: "CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD"
        ),
        machoAllowlist: .reviewed
    )

    static let reviewedFixture = VRChatIdentity(
        bundleIdentifier: "com.vrchat.mobile",
        shortVersion: "2026.2.30300",
        buildVersion: "1365",
        sourceAppRelativePath:
            "Library/Containers/io.playcover.PlayCover/Applications/com.vrchat.mobile.app",
        destinationAppRelativePath:
            "Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/com.vrchat.mobile.app",
        executableName: "VRChat",
        mainIdentity: PortableMachOIdentity(
            uuid: "41CADB30-CCEF-3B6C-8A1D-237CE5D64C42",
            normalizedUnsignedSHA256:
                "cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3",
            loadCommandsSHA256:
                "664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb",
            entitlementsSHA256:
                "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4"
        ),
        unityFramework: ReviewedBinaryIdentity(
            relativePath: "Frameworks/UnityFramework.framework/UnityFramework",
            sha256:
                "497d0ea4416d734ef0fb8dbb1376a0c31370577ed86bfd8f37a6d1f63e2163e9",
            uuid: "37732282-7315-38F5-9DD3-124F2B1162B4"
        ),
        appdomeLibloader: ReviewedBinaryIdentity(
            relativePath: "Frameworks/libloader.framework/libloader",
            sha256:
                "90fd505324581d09883e03cbb46ac6cf8817c18181fa9438381551d589d62440",
            uuid: "64B5DAFB-DE12-3089-AE61-912CE193C876"
        ),
        machoAllowlist: .reviewed
    )
}

private extension MachOAllowlistIdentity {
    static let reviewed = MachOAllowlistIdentity(
        format: "PCVR-MACHO-ALLOWLIST/1",
        digestSHA256:
            "60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109",
        count: 46
    )
}

private extension ControllerInstallationEvidence {
    static let fixture = ControllerInstallationEvidence(
        controllerBuildID: "capability-vrchat-2026.2.30300-1365-r7",
        packageIdentifier:
            "io.github.northstarxyzz.pcvrpatcher.memory-policy",
        packageVersion: "0.1.0",
        runnerSHA256: String(repeating: "7", count: 64),
        attestationSHA256: String(repeating: "8", count: 64)
    )
}

private extension ControllerPackageRequirement {
    static let fixture = ControllerPackageRequirement(
        relativePath: "Controller/PlayCoverVRChatMemoryPolicy.pkg",
        identifier: "io.github.northstarxyzz.pcvrpatcher.memory-policy",
        version: "0.1.0",
        sha256:
            "dac659b8ad876000a547024da1606ab59ad3dd73655ce84e7674b1aec86d81df",
        controllerBuildID: "capability-vrchat-2026.2.30300-1365-r7",
        controllerQuarantinePath:
            "/usr/local/libexec/playcover-vrchat-memory-policy/.controller.pcvr-install",
        runnerQuarantinePath:
            "/usr/local/bin/.playcover-vrchat-memory-policy.pcvr-install",
        runner: RootArtifactRequirement(
            path: "/usr/local/bin/playcover-vrchat-memory-policy",
            sha256: String(repeating: "7", count: 64),
            mode: "0555"
        ),
        controller: RootArtifactRequirement(
            path:
                "/usr/local/libexec/playcover-vrchat-memory-policy/controller",
            sha256: String(repeating: "9", count: 64),
            mode: "0500"
        ),
        attestation: RootArtifactRequirement(
            path:
                "/usr/local/libexec/playcover-vrchat-memory-policy/installation.json",
            sha256: String(repeating: "8", count: 64),
            mode: "0444"
        ),
        installJournal: RootArtifactRequirement(
            path:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.install",
            sha256:
                "2c4dcac138decf2d452fa661cf2542dc145451e01905cd7c05821fd0aec9dcd1",
            mode: "0400"
        ),
        uninstallJournal: RootArtifactRequirement(
            path:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.uninstall",
            sha256:
                "81774131768fce7378e740fc2bfaeb50620c2121ae4f56a7539cb5cd69d33b13",
            mode: "0400"
        ),
        operationClaim: RootArtifactRequirement(
            path:
                "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.operation",
            sha256:
                "7fbc5571dfedc9073d71607562a97c1ea0c0435e6783f1818dcdcc40e8f23eed",
            mode: "0400"
        ),
        timeoutSeconds: 900,
        pollMilliseconds: 500
    )
}

private extension CompatibilityManifest {
    static let fixture = CompatibilityManifest(
        patchID: "test-patch",
        architecture: "arm64",
        playCover: .sourceFixture,
        patchedPlayCover: .patchedFixture,
        vrChat: .fixture,
        host: HostRequirement(
            productVersion: "26.6",
            buildVersion: "25G70",
            xnuVersion: "xnu-12377.161.13~4"
        ),
        policy: MemoryPolicy(
            mode: .automatic75Percent,
            minGiB: 4,
            maxPhysicalPercent: 75,
            stepGiB: 1,
            waitSeconds: 300,
            fatal: false
        ),
        ipc: IPCRequirement(
            protocolVersion: 2,
            socketPath:
                "/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock"
        ),
        controllerPackage: .fixture
    )

    static let sourceOnlyFixture = CompatibilityManifest(
        patchID: "test-patch",
        architecture: "arm64",
        playCover: .sourceFixture,
        patchedPlayCover: nil,
        vrChat: .fixture,
        host: fixture.host,
        policy: fixture.policy,
        ipc: fixture.ipc
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
