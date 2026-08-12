import Darwin
import Foundation

private enum FakeProviderError: Error {
    case unavailable
}

private final class MutableConfiguration:
    VRChatMemoryPolicyConfigurationProviding {

    var value: VRChatMemoryPolicySnapshot

    init(_ value: VRChatMemoryPolicySnapshot) {
        self.value = value
    }

    func snapshot() throws -> VRChatMemoryPolicySnapshot {
        value
    }
}

private final class FakeBundleIdentityValidator:
    VRChatCompatibleBundleIdentityValidating {

    var identity: VRChatCompatibleBundleIdentity
    var failure: Error?
    private(set) var calls: [(URL, String)] = []

    init(
        identity: VRChatCompatibleBundleIdentity = makeTestBundleIdentity(),
        failure: Error? = nil
    ) {
        self.identity = identity
        self.failure = failure
    }

    func validate(
        appURL: URL,
        bundleIdentifier: String
    ) throws -> VRChatCompatibleBundleIdentity {
        calls.append((appURL, bundleIdentifier))
        if let failure { throw failure }
        guard appURL.path == identity.appURL.path else {
            throw VRChatCompatibleBundleIdentityError.unexpectedAppURL(
                expected: identity.appURL.path,
                found: appURL.path
            )
        }
        return identity
    }
}

private let testHomeURL = URL(fileURLWithPath: "/Users/PCVRTest")
private let testAppURL = VRChatMemoryPolicyManifest.expectedAppURL(
    homeDirectory: testHomeURL
)

private func makeTestBundleIdentity(
    appURL: URL = testAppURL
) -> VRChatCompatibleBundleIdentity {
    VRChatCompatibleBundleIdentity(
        appURL: appURL,
        executableURL: appURL.appendingPathComponent("VRChat"),
        machoCount: VRChatMemoryPolicyManifest.reviewedMachOCount,
        machoAllowlistSHA256:
            VRChatMemoryPolicyManifest.reviewedMachOAllowlistSHA256,
        mainUUID: VRChatMemoryPolicyManifest.reviewedMainUUID,
        mainNormalizedUnsignedSHA256:
            VRChatMemoryPolicyManifest.reviewedMainNormalizedUnsignedSHA256,
        mainNormalizedLoadCommandsSHA256:
            VRChatMemoryPolicyManifest
                .reviewedMainNormalizedLoadCommandsSHA256,
        entitlementsSHA256:
            "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4"
    )
}

private func addTestExtendedACL(to path: String) throws {
    var acl = acl_init(1)
    guard acl != nil else {
        throw TestFailure("acl_init failed: \(errno)")
    }
    defer {
        if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    }

    var entry: acl_entry_t?
    guard acl_create_entry(&acl, &entry) == 0,
          acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else {
        throw TestFailure("cannot create ACL entry: \(errno)")
    }

    guard let handle = dlopen(
        "/usr/lib/libSystem.B.dylib",
        RTLD_LAZY | RTLD_LOCAL
    ) else {
        throw TestFailure("cannot open libSystem for membership conversion")
    }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "mbr_uid_to_uuid") else {
        throw TestFailure("mbr_uid_to_uuid is unavailable")
    }
    typealias UIDToUUID = @convention(c) (
        uid_t,
        UnsafeMutablePointer<UInt8>
    ) -> Int32
    let convert = unsafeBitCast(symbol, to: UIDToUUID.self)
    var qualifier = [UInt8](repeating: 0, count: 16)
    let conversionStatus = qualifier.withUnsafeMutableBufferPointer {
        convert(geteuid(), $0.baseAddress!)
    }
    guard conversionStatus == 0,
          qualifier.withUnsafeBytes({
              acl_set_qualifier(entry, $0.baseAddress)
          }) == 0 else {
        throw TestFailure("cannot assign ACL qualifier: \(errno)")
    }

    var permissions: acl_permset_t?
    guard acl_get_permset(entry, &permissions) == 0,
          acl_clear_perms(permissions) == 0,
          acl_add_perm(permissions, ACL_READ_DATA) == 0,
          acl_set_permset(entry, permissions) == 0,
          acl_valid(acl) == 0 else {
        throw TestFailure("cannot configure ACL permission: \(errno)")
    }
    let setStatus = path.withCString {
        acl_set_file($0, ACL_TYPE_EXTENDED, acl)
    }
    guard setStatus == 0 else {
        throw TestFailure("acl_set_file failed: \(errno)")
    }
}

private actor FakeAuthorization:
    VRChatMemoryPolicyAuthorizationProviding {

    private let failure: Error?
    private(set) var limits: [UInt16] = []

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func startController(selectedLimitGiB: UInt16) async throws {
        limits.append(selectedLimitGiB)
        if let failure {
            throw failure
        }
    }
}

private actor FakeSession: VRChatMemoryPolicySession {
    nonisolated let buildID: String
    nonisolated let selectedLimitMiB: UInt64
    nonisolated let safeMaximumMiB: UInt64

    private var events: [VRChatMemoryPolicyServerEvent]
    private(set) var cancelCount = 0
    private(set) var closeCount = 0

    init(
        buildID: String = VRChatMemoryPolicyManifest.controllerBuildID,
        selectedLimitMiB: UInt64,
        safeMaximumMiB: UInt64,
        events: [VRChatMemoryPolicyServerEvent] = []
    ) {
        self.buildID = buildID
        self.selectedLimitMiB = selectedLimitMiB
        self.safeMaximumMiB = safeMaximumMiB
        self.events = events
    }

    func nextEvent() async throws -> VRChatMemoryPolicyServerEvent {
        guard !events.isEmpty else {
            throw VRChatMemoryPolicyClientError.connectionClosed
        }
        return events.removeFirst()
    }

    func cancelBeforeTargetBound() async throws {
        cancelCount += 1
    }

    func close() async {
        closeCount += 1
    }
}

private actor FakeProvider: VRChatMemoryPolicySessionProvider {
    private let session: VRChatMemoryPolicySession?
    private let failure: Error?
    private(set) var snapshots: [VRChatMemoryPolicySnapshot] = []

    init(session: VRChatMemoryPolicySession) {
        self.session = session
        failure = nil
    }

    init(failure: Error) {
        session = nil
        self.failure = failure
    }

    func openSession(
        socketPath: String,
        timeout: TimeInterval,
        expectedSnapshot: VRChatMemoryPolicySnapshot
    ) async throws -> VRChatMemoryPolicySession {
        snapshots.append(expectedSnapshot)
        if let failure {
            throw failure
        }
        guard let session else {
            throw FakeProviderError.unavailable
        }
        return session
    }
}

@main
private struct CoordinatorStateMachineTests {
    static func main() async throws {
        try testBuildIdentityAndLaunchModeResolution()
        try testWrongSameBundleURLAndSymlinkPathFailClosed()
        try testSafeMaximumAndCustomBounds()
        try testPCVR2Parser()
        try await testDeveloperProviderRejectsNonFixedPath()
        try testRunnerRejectsACLAndReplacementRace()
        try testRealACLEnumerationAndRunnerPreflight()
        try await testIdentityFailurePreventsAuthorization()
        try await testHappyPathAndDynamicMetrics()
        try await testSnapshotHasNextSessionSemantics()
        try await testLaunchServicesFailureCancelsExactlyOnce()
        try await testBusySessionFailsClosed()
        try await testAuthorizationFailurePreventsSocketConnection()
        try await testProviderFailurePreventsWaiting()
        try await testOutOfOrderEventFailsProtocol()
        try await testReturnedProcessPathMismatchFailsClosed()
        try await testTargetPIDMismatchFailsClosed()
        try await testMetricsLimitMismatchFailsProtocol()
        print("CoordinatorStateMachineTests: PASS")
    }

    private static func testBuildIdentityAndLaunchModeResolution() throws {
        try require(
            PlayCoverVRChatBuildIdentity.bundleIdentifier
                == "io.github.northstarxyzz.PlayCoverVRChat",
            "customized PlayCover bundle identity must remain independent"
        )
        try require(
            PlayCoverVRChatBuildIdentity.displayName == "PlayCover VRChat",
            "customized display name must remain explicit"
        )
        try require(
            PlayAppLaunchMode.automatic.resolved(
                for: VRChatMemoryPolicyManifest.bundleIdentifier
            ) == .vrChatCompatible,
            "VRChat automatic launch must use compatibility mode"
        )
        try require(
            PlayAppLaunchMode.standard.resolved(
                for: VRChatMemoryPolicyManifest.bundleIdentifier
            ) == .vrChatCompatible,
            "VRChat must not expose a standard-launch bypass"
        )
        try require(
            PlayAppLaunchMode.automatic.resolved(for: "example.other")
                == .standard,
            "non-VRChat launch must retain standard behavior"
        )
        try require(
            VRChatMemoryPolicyManifest.protocolVersion == "PCVR/2",
            "the client must not regress to PCVR/1"
        )
        try require(
            VRChatMemoryPolicyManifest.controllerBuildID
                == "capability-vrchat-2026.2.30300-1365-r7",
            "the client must accept only the reviewed capability-gated controller"
        )
    }

    private static func testWrongSameBundleURLAndSymlinkPathFailClosed()
        throws {
        let wrongURL = testHomeURL
            .appendingPathComponent("Applications")
            .appendingPathComponent("com.vrchat.mobile.app")
        do {
            try SystemVRChatCompatibleBundleIdentityValidator
                .validateExactLocation(
                    appURL: wrongURL,
                    homeDirectory: testHomeURL,
                    expectedUID: geteuid()
                )
            throw TestFailure("same bundle ID at another URL was accepted")
        } catch let error as VRChatCompatibleBundleIdentityError {
            guard case .unexpectedAppURL = error else {
                throw TestFailure("wrong URL did not fail as unexpectedAppURL")
            }
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "pcvr-location-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let containers = home.appendingPathComponent(
            "Library/Containers",
            isDirectory: true
        )
        let realContainer = root.appendingPathComponent(
            "real-container",
            isDirectory: true
        )
        let realApp = realContainer.appendingPathComponent(
            "Applications/com.vrchat.mobile.app",
            isDirectory: true
        )
        try manager.createDirectory(
            at: containers,
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: realApp,
            withIntermediateDirectories: true
        )
        let symlink = containers.appendingPathComponent(
            PlayCoverVRChatBuildIdentity.containerDirectoryName
        )
        try manager.createSymbolicLink(
            at: symlink,
            withDestinationURL: realContainer
        )
        defer { try? manager.removeItem(at: root) }

        let expectedThroughSymlink = VRChatMemoryPolicyManifest.expectedAppURL(
            homeDirectory: home
        )
        do {
            try SystemVRChatCompatibleBundleIdentityValidator
                .validateExactLocation(
                    appURL: expectedThroughSymlink,
                    homeDirectory: home,
                    expectedUID: geteuid()
                )
            throw TestFailure("symlinked independent library path was accepted")
        } catch let error as VRChatCompatibleBundleIdentityError {
            guard case let .unsafePath(path, _) = error else {
                throw TestFailure("symlink path did not fail as unsafePath")
            }
            try require(path == symlink.path,
                        "the exact symlink component must be identified")
        }
    }

    private static func testSafeMaximumAndCustomBounds() throws {
        let gib = VRChatMemoryPolicyManifest.bytesPerGibibyte
        try require(
            try VRChatMemoryPolicySnapshot.safeMaximumGiB(
                physicalMemoryBytes: 20 * gib
            ) == 15,
            "20 GiB must produce a 15 GiB safe maximum"
        )
        try require(
            try VRChatMemoryPolicySnapshot.safeMaximumGiB(
                physicalMemoryBytes: 20 * gib - 1
            ) == 14,
            "75-percent calculation must use floor semantics"
        )

        let minimum = try VRChatMemoryPolicySnapshot.make(
            mode: .customGiB(4),
            physicalMemoryBytes: 20 * gib
        )
        try require(minimum.selectedLimitGiB == 4,
                    "4 GiB must be the accepted minimum")

        let low = try VRChatMemoryPolicySnapshot.make(
            mode: .customGiB(7),
            physicalMemoryBytes: 20 * gib
        )
        try require(low.shouldWarnLowMemory,
                    "accepted limits below 8 GiB must carry a warning")

        let automatic = try VRChatMemoryPolicySnapshot.make(
            mode: .automatic75Percent,
            physicalMemoryBytes: 20 * gib
        )
        try require(automatic.selectedLimitGiB == 15,
                    "automatic mode must select the exact safe maximum")

        do {
            _ = try VRChatMemoryPolicySnapshot.make(
                mode: .customGiB(16),
                physicalMemoryBytes: 20 * gib
            )
            throw TestFailure("out-of-range custom limit was silently accepted")
        } catch let error as VRChatMemoryPolicyConfigurationError {
            try require(
                error == .customOutsideSafeRange(
                    requestedGiB: 16,
                    safeMaximumGiB: 15
                ),
                "custom values above safe maximum must fail without clamping"
            )
        }
    }

    private static func testPCVR2Parser() throws {
        try require(
            try PCVRLineProtocol.parseHello(
                "PCVR/2 HELLO capability-vrchat-2026.2.30300-1365-r7"
            ) == VRChatMemoryPolicyManifest.controllerBuildID,
            "PCVR/2 HELLO must parse"
        )
        try require(
            try PCVRLineProtocol.parseWaiting(
                "PCVR/2 WAITING 12288 15360"
            ) == .init(selectedLimitMiB: 12_288, safeMaximumMiB: 15_360),
            "WAITING must carry selected and safe maximum MiB"
        )

        let expectedMetrics = VRChatMemoryPolicyMetrics(
            pid: 42,
            selectedLimitMiB: 12_288,
            footprintMiB: 4_096.5,
            headroomMiB: 8_191.5,
            reapplies: 7,
            pressure: "0x1"
        )
        try require(
            try PCVRLineProtocol.parseEvent(
                "PCVR/2 METRICS 42 12288 4096.5 8191.5 7 0x1"
            ) == .metrics(expectedMetrics),
            "dynamic PCVR/2 metrics must parse exactly"
        )

        try expectProtocolFailure("PCVR/1 WAITING 12288 15360")
        try expectProtocolFailure("PCVR/2 WAITING 012288 15360")
        try expectProtocolFailure(
            "PCVR/2 METRICS 42 12288 4096 8192.0 7 normal"
        )
    }

    private static func testDeveloperProviderRejectsNonFixedPath() async throws {
        let provider = DeveloperAlphaSystemAuthorizationProvider(
            runnerPath: "/tmp/not-the-reviewed-runner"
        )
        do {
            try await provider.startController(selectedLimitGiB: 4)
            throw TestFailure("non-fixed runner path unexpectedly executed")
        } catch let error as VRChatMemoryPolicyAuthorizationError {
            try require(
                error == .unsafeRunner(
                    path: "/tmp/not-the-reviewed-runner",
                    reason: "path_not_fixed"
                ),
                "developer provider must reject alternate paths before auth"
            )
        }
    }

    private static func testRunnerRejectsACLAndReplacementRace() throws {
        var metadata = stat()
        metadata.st_uid = 0
        metadata.st_gid = 0
        metadata.st_mode = S_IFREG | 0o555
        metadata.st_nlink = 1
        metadata.st_size = 4_096
        metadata.st_dev = 1
        metadata.st_ino = 10
        try require(
            !DeveloperAlphaSystemAuthorizationProvider
                .runnerMetadataIsSafeForTesting(
                    metadata,
                    hasExtendedACL: true,
                    isRunner: true
                ),
            "an extended ACL must reject the fixed runner"
        )

        let before = DeveloperAlphaSystemAuthorizationProvider
            .RunnerFileIdentity(
                metadata: metadata,
                sha256: VRChatMemoryPolicyManifest.reviewedRunnerSHA256
            )
        metadata.st_ino = 11
        let replacement = DeveloperAlphaSystemAuthorizationProvider
            .RunnerFileIdentity(
                metadata: metadata,
                sha256: VRChatMemoryPolicyManifest.reviewedRunnerSHA256
            )
        try require(
            !DeveloperAlphaSystemAuthorizationProvider
                .runnerIdentitiesMatchForTesting(before, replacement),
            "check/replace inode races must invalidate the retained binding"
        )
    }

    private static func testRealACLEnumerationAndRunnerPreflight() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "pcvr-real-acl-\(UUID().uuidString)",
            isDirectory: true
        )
        let runner = directory.appendingPathComponent("runner")
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        guard manager.createFile(
            atPath: runner.path,
            contents: Data("runner".utf8)
        ), chmod(runner.path, 0o500) == 0 else {
            throw TestFailure("cannot create ACL runner fixture")
        }
        defer { try? manager.removeItem(at: directory) }

        var plainMetadata = stat()
        guard lstat(runner.path, &plainMetadata) == 0 else {
            throw TestFailure("cannot stat ACL runner fixture")
        }
        try require(
            try !PCVRFilesystemSafety.pathHasExtendedACL(
                runner.path,
                expectedMetadata: plainMetadata
            ),
            "nil/ENOENT must mean that a stable path has no extended ACL"
        )
        let plainDescriptor = open(
            runner.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard plainDescriptor >= 0 else {
            throw TestFailure("cannot open ACL runner fixture")
        }
        var plainDescriptorMetadata = stat()
        guard fstat(plainDescriptor, &plainDescriptorMetadata) == 0 else {
            _ = close(plainDescriptor)
            throw TestFailure("cannot fstat ACL runner fixture")
        }
        let plainDescriptorHasACL = try PCVRFilesystemSafety
            .descriptorHasExtendedACL(
                plainDescriptor,
                path: runner.path,
                expectedMetadata: plainDescriptorMetadata
            )
        _ = close(plainDescriptor)
        try require(!plainDescriptorHasACL,
                    "a stable descriptor without an ACL must be accepted")
        _ = try DeveloperAlphaSystemAuthorizationProvider.validateRunnerNode(
            path: runner.path,
            expectedUID: geteuid(),
            isRunner: true
        )

        try addTestExtendedACL(to: runner.path)
        var aclMetadata = stat()
        guard lstat(runner.path, &aclMetadata) == 0 else {
            throw TestFailure("cannot stat ACL-bearing runner fixture")
        }
        try require(
            try PCVRFilesystemSafety.pathHasExtendedACL(
                runner.path,
                expectedMetadata: aclMetadata
            ),
            "a nonnil acl_t must be reported as an extended ACL"
        )

        let aclDescriptor = open(
            runner.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard aclDescriptor >= 0 else {
            throw TestFailure("cannot open ACL-bearing runner fixture")
        }
        var aclDescriptorMetadata = stat()
        guard fstat(aclDescriptor, &aclDescriptorMetadata) == 0 else {
            _ = close(aclDescriptor)
            throw TestFailure("cannot fstat ACL-bearing runner fixture")
        }
        let descriptorHasACL = try PCVRFilesystemSafety
            .descriptorHasExtendedACL(
                aclDescriptor,
                path: runner.path,
                expectedMetadata: aclDescriptorMetadata
            )
        _ = close(aclDescriptor)
        try require(descriptorHasACL,
                    "the exact descriptor ACL getter must reject a real ACL")
        try require(
            !DeveloperAlphaSystemAuthorizationProvider
                .runnerMetadataIsSafeForTesting(
                    aclDescriptorMetadata,
                    expectedUID: geteuid(),
                    hasExtendedACL: descriptorHasACL,
                    isRunner: true
                ),
            "descriptor preflight must reject the getter's real ACL result"
        )

        do {
            _ = try DeveloperAlphaSystemAuthorizationProvider
                .validateRunnerNode(
                    path: runner.path,
                    expectedUID: geteuid(),
                    isRunner: true
                )
            throw TestFailure("real ACL unexpectedly passed runner preflight")
        } catch let error as VRChatMemoryPolicyAuthorizationError {
            try require(
                error == .unsafeRunner(
                    path: runner.path,
                    reason: "extended_acl"
                ),
                "runner preflight must report a real extended ACL"
            )
        }
    }

    private static func testIdentityFailurePreventsAuthorization() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let identityError = VRChatCompatibleBundleIdentityError
            .unexpectedAppURL(expected: testAppURL.path, found: "/tmp/fake.app")
        let validator = FakeBundleIdentityValidator(failure: identityError)
        let authorization = FakeAuthorization()
        let provider = FakeProvider(failure: FakeProviderError.unavailable)
        let coordinator = VRChatMemoryPolicyCoordinator(
            configurationProvider: MutableConfiguration(snapshot),
            bundleIdentityValidator: validator,
            authorizationProvider: authorization,
            sessionProvider: provider
        )
        do {
            _ = try await coordinator.prepareForCompatibleLaunch(
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
                appURL: testAppURL
            )
            throw TestFailure("identity failure unexpectedly authorized runner")
        } catch let error as VRChatCompatibleBundleIdentityError {
            try require(error == identityError,
                        "identity error must be preserved")
        }
        let limits = await authorization.limits
        let snapshots = await provider.snapshots
        let state = await coordinator.state
        try require(limits.isEmpty,
                    "identity failure must precede system authorization")
        try require(snapshots.isEmpty,
                    "identity failure must precede socket connection")
        try require(state == .failed(code: "unexpected_app_url"),
                    "identity failure must enter a stable failed state")
    }

    private static func testHappyPathAndDynamicMetrics() async throws {
        let snapshot = try makeSnapshot(.customGiB(12))
        let pid: pid_t = 42_424
        let metrics = VRChatMemoryPolicyMetrics(
            pid: pid,
            selectedLimitMiB: snapshot.selectedLimitMiB,
            footprintMiB: 5_120.5,
            headroomMiB: 7_167.5,
            reapplies: 2,
            pressure: "0x1"
        )
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB,
            events: [
                .targetBound(pid: pid),
                .leaseActive(
                    pid: pid,
                    selectedLimitMiB: snapshot.selectedLimitMiB
                ),
                .metrics(metrics),
                .completed
            ]
        )
        let authorization = FakeAuthorization()
        let provider = FakeProvider(session: session)
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: authorization,
            provider: provider
        )

        let returnedSnapshot = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try require(returnedSnapshot == snapshot,
                    "prepare must return its immutable session snapshot")
        let waitingState = await coordinator.state
        try require(
            waitingState == .waiting(
                buildID: VRChatMemoryPolicyManifest.controllerBuildID,
                snapshot: snapshot
            ),
            "authorized PCVR/2 handshake must enter waiting"
        )
        let authorizedLimits = await authorization.limits
        let providerSnapshots = await provider.snapshots
        try require(authorizedLimits == [12],
                    "authorization must receive one exact whole-GiB argument")
        try require(providerSnapshots == [snapshot],
                    "socket provider must validate the same snapshot")

        try await coordinator.launchWillBegin()
        try await coordinator.bindLaunchServicesProcess(
            pid: pid,
            bundleURL: testAppURL,
            executableURL: testAppURL.appendingPathComponent("VRChat")
        )
        let finalState = try await waitForTerminalState(coordinator)
        try require(finalState == .completed,
                    "ordered dynamic controller events must complete")
        let cancelCount = await session.cancelCount
        let closeCount = await session.closeCount
        try require(cancelCount == 0,
                    "happy path must not send CANCEL")
        try require(closeCount == 1,
                    "terminal session must close exactly once")
    }

    private static func testSnapshotHasNextSessionSemantics() async throws {
        let firstSnapshot = try makeSnapshot(.automatic75Percent)
        let nextSnapshot = try makeSnapshot(.customGiB(6))
        let configuration = MutableConfiguration(firstSnapshot)
        let authorization = FakeAuthorization()
        let session = FakeSession(
            selectedLimitMiB: firstSnapshot.selectedLimitMiB,
            safeMaximumMiB: firstSnapshot.safeMaximumMiB
        )
        let coordinator = VRChatMemoryPolicyCoordinator(
            configurationProvider: configuration,
            bundleIdentityValidator: FakeBundleIdentityValidator(),
            authorizationProvider: authorization,
            sessionProvider: FakeProvider(session: session)
        )

        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        configuration.value = nextSnapshot

        let waitingState = await coordinator.state
        let authorizedLimits = await authorization.limits
        try require(
            waitingState == .waiting(
                buildID: VRChatMemoryPolicyManifest.controllerBuildID,
                snapshot: firstSnapshot
            ),
            "settings mutation must not alter the active session snapshot"
        )
        try require(authorizedLimits == [15],
                    "automatic mode must pass the frozen safe maximum")

        try await coordinator.launchWillBegin()
        try await coordinator.launchServicesFailedBeforeBinding()
    }

    private static func testLaunchServicesFailureCancelsExactlyOnce() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )

        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try await coordinator.launchWillBegin()
        try await coordinator.launchServicesFailedBeforeBinding()

        let cancelState = await coordinator.state
        let cancelCount = await session.cancelCount
        let closeCount = await session.closeCount
        try require(cancelState == .cancelRequested,
                    "LaunchServices failure must enter cancelRequested")
        try require(cancelCount == 1,
                    "LaunchServices failure must send one PCVR/2 CANCEL")
        try require(closeCount == 1,
                    "cancelled session must close")
    }

    private static func testBusySessionFailsClosed() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )
        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )

        do {
            _ = try await coordinator.prepareForCompatibleLaunch(
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
                appURL: testAppURL
            )
            throw TestFailure("second active session unexpectedly succeeded")
        } catch let error as VRChatMemoryPolicyClientError {
            try require(error == .sessionBusy,
                        "second active session must fail with sessionBusy")
        }
    }

    private static func testAuthorizationFailurePreventsSocketConnection() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let authorization = FakeAuthorization(
            failure: VRChatMemoryPolicyAuthorizationError.authorizationDenied(-60006)
        )
        let provider = FakeProvider(failure: FakeProviderError.unavailable)
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: authorization,
            provider: provider
        )

        do {
            _ = try await coordinator.prepareForCompatibleLaunch(
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
                appURL: testAppURL
            )
            throw TestFailure("authorization failure unexpectedly connected")
        } catch let error as VRChatMemoryPolicyAuthorizationError {
            try require(error == .authorizationDenied(-60006),
                        "authorization failure must be preserved")
        }

        let providerSnapshots = await provider.snapshots
        let failureState = await coordinator.state
        try require(providerSnapshots.isEmpty,
                    "socket connection must not precede authorization")
        try require(
            failureState == .failed(code: "authorization_denied"),
            "authorization denial must become a terminal failure"
        )
    }

    private static func testProviderFailurePreventsWaiting() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(failure: FakeProviderError.unavailable)
        )
        do {
            _ = try await coordinator.prepareForCompatibleLaunch(
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
                appURL: testAppURL
            )
            throw TestFailure("provider failure unexpectedly reached WAITING")
        } catch FakeProviderError.unavailable {
            // Expected.
        }

        let failureState = await coordinator.state
        try require(
            failureState == .failed(code: "session_provider_error"),
            "provider failure must become a terminal failed state"
        )
    }

    private static func testOutOfOrderEventFailsProtocol() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB,
            events: [
                .leaseActive(
                    pid: 99,
                    selectedLimitMiB: snapshot.selectedLimitMiB
                )
            ]
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )
        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try await coordinator.launchWillBegin()
        do {
            try await coordinator.bindLaunchServicesProcess(
                pid: 99,
                bundleURL: testAppURL,
                executableURL: testAppURL.appendingPathComponent("VRChat")
            )
            throw TestFailure("out-of-order event unexpectedly bound")
        } catch is VRChatMemoryPolicyClientError {
            // Expected.
        }
        let finalState = await coordinator.state
        try require(
            finalState == .failed(code: "protocol_violation"),
            "out-of-order event must fail the protocol"
        )
    }

    private static func testReturnedProcessPathMismatchFailsClosed()
        async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )
        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try await coordinator.launchWillBegin()
        let wrongURL = testHomeURL
            .appendingPathComponent("Other/com.vrchat.mobile.app")
        do {
            try await coordinator.bindLaunchServicesProcess(
                pid: 5_001,
                bundleURL: wrongURL,
                executableURL: wrongURL.appendingPathComponent("VRChat")
            )
            throw TestFailure("wrong LaunchServices path unexpectedly bound")
        } catch let error as VRChatCompatibleBundleIdentityError {
            guard case .launchedProcessMismatch = error else {
                throw TestFailure("wrong returned path produced wrong error")
            }
        }
        let state = await coordinator.state
        let cancels = await session.cancelCount
        let closes = await session.closeCount
        try require(
            state == .failed(code: "launchservices_process_mismatch"),
            "wrong returned process must become terminal"
        )
        try require(cancels == 1,
                    "wrong pre-bind process must cancel the root wait")
        try require(closes == 1,
                    "wrong pre-bind process must close the session")
    }

    private static func testTargetPIDMismatchFailsClosed() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let controllerPID: pid_t = 6_001
        let returnedPID: pid_t = 6_002
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB,
            events: [.targetBound(pid: controllerPID)]
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )
        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try await coordinator.launchWillBegin()
        do {
            try await coordinator.bindLaunchServicesProcess(
                pid: returnedPID,
                bundleURL: testAppURL,
                executableURL: testAppURL.appendingPathComponent("VRChat")
            )
            throw TestFailure("mismatched TARGET_BOUND PID was accepted")
        } catch let error as VRChatCompatibleBundleIdentityError {
            try require(
                error == .targetPIDMismatch(
                    expected: returnedPID,
                    found: controllerPID
                ),
                "PID mismatch must preserve both identities"
            )
        }
        let state = await coordinator.state
        let cancels = await session.cancelCount
        let closes = await session.closeCount
        try require(state == .failed(code: "target_pid_mismatch"),
                    "PID mismatch must become terminal")
        try require(cancels == 0,
                    "CANCEL is forbidden after TARGET_BOUND")
        try require(closes == 1,
                    "PID mismatch must close the bound session")
    }

    private static func testMetricsLimitMismatchFailsProtocol() async throws {
        let snapshot = try makeSnapshot(.customGiB(10))
        let pid: pid_t = 99
        let session = FakeSession(
            selectedLimitMiB: snapshot.selectedLimitMiB,
            safeMaximumMiB: snapshot.safeMaximumMiB,
            events: [
                .targetBound(pid: pid),
                .leaseActive(
                    pid: pid,
                    selectedLimitMiB: snapshot.selectedLimitMiB
                ),
                .metrics(VRChatMemoryPolicyMetrics(
                    pid: pid,
                    selectedLimitMiB: snapshot.selectedLimitMiB + 1,
                    footprintMiB: 1.0,
                    headroomMiB: 2.0,
                    reapplies: 0,
                    pressure: "0x1"
                ))
            ]
        )
        let coordinator = makeCoordinator(
            snapshot: snapshot,
            authorization: FakeAuthorization(),
            provider: FakeProvider(session: session)
        )
        _ = try await coordinator.prepareForCompatibleLaunch(
            bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier,
            appURL: testAppURL
        )
        try await coordinator.launchWillBegin()
        try await coordinator.bindLaunchServicesProcess(
            pid: pid,
            bundleURL: testAppURL,
            executableURL: testAppURL.appendingPathComponent("VRChat")
        )

        let finalState = try await waitForTerminalState(coordinator)
        try require(
            finalState == .failed(code: "protocol_violation"),
            "METRICS selected limit must match the immutable snapshot"
        )
    }

    private static func makeSnapshot(
        _ mode: VRChatMemoryPolicyMode
    ) throws -> VRChatMemoryPolicySnapshot {
        try VRChatMemoryPolicySnapshot.make(
            mode: mode,
            physicalMemoryBytes:
                20 * VRChatMemoryPolicyManifest.bytesPerGibibyte
        )
    }

    private static func makeCoordinator(
        snapshot: VRChatMemoryPolicySnapshot,
        authorization: VRChatMemoryPolicyAuthorizationProviding,
        provider: VRChatMemoryPolicySessionProvider
    ) -> VRChatMemoryPolicyCoordinator {
        VRChatMemoryPolicyCoordinator(
            configurationProvider: MutableConfiguration(snapshot),
            bundleIdentityValidator: FakeBundleIdentityValidator(),
            authorizationProvider: authorization,
            sessionProvider: provider
        )
    }

    private static func expectProtocolFailure(_ line: String) throws {
        do {
            if line.contains("WAITING") {
                _ = try PCVRLineProtocol.parseWaiting(line)
            } else {
                _ = try PCVRLineProtocol.parseEvent(line)
            }
            throw TestFailure("invalid protocol line unexpectedly parsed: \(line)")
        } catch is VRChatMemoryPolicyClientError {
            // Expected.
        }
    }

    private static func waitForTerminalState(
        _ coordinator: VRChatMemoryPolicyCoordinator
    ) async throws -> VRChatMemoryPolicyCoordinator.State {
        for _ in 0..<200 {
            let state = await coordinator.state
            if state.permitsNewSession {
                return state
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TestFailure("timed out waiting for terminal state")
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        if try !condition() {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
