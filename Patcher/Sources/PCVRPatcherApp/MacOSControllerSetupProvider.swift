import AppKit
import Darwin
import Foundation
import PCVRPatcherCore
import Security

actor MacOSControllerSetupProvider: ControllerSetupProviding {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func inspect(
        requirement: ControllerPackageRequirement
    ) async throws -> ControllerInstallationState {
        let receipt = try packageReceiptState(requirement)
        let operationClaim = try operationClaimObservation(requirement)
        return try RootControllerInstallationVerifier.inspect(
            requirement: requirement,
            receipt: receipt,
            operationClaim: operationClaim
        )
    }

    func install(_ request: ControllerSetupRequest) async throws {
        _ = try ControllerPackageVerifier.verify(
            request.packageURL,
            requirement: request.requirement
        )
        let installer = URL(
            fileURLWithPath: "/System/Library/CoreServices/Installer.app",
            isDirectory: true
        )
        guard Bundle(url: installer)?.bundleIdentifier == "com.apple.installer"
        else {
            throw PatcherError.controllerSetupFailed(
                "the system Installer application identity is unavailable"
            )
        }

        // Recheck immediately before the unavoidable URL handoff. Public
        // distribution remains blocked until the package has a Developer ID
        // Installer signature and notarization; v0.1 is local-development-only.
        _ = try ControllerPackageVerifier.verify(
            request.packageURL,
            requirement: request.requirement
        )
        let runningInstaller = try await openPackage(
            request.packageURL,
            with: installer
        )
        try await waitForExactInstallation(
            requirement: request.requirement,
            installer: runningInstaller
        )
    }

    func uninstall(
        requirement: ControllerPackageRequirement
    ) async throws {
        var tracker = ControllerUninstallAuthorizationTracker()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(requirement.timeoutSeconds)
        while clock.now < deadline {
            let state = try await inspect(requirement: requirement)
            switch tracker.action(for: state) {
            case .complete:
                return
            case .observe:
                break // An exact live owner is making progress: poll only.
            case .authorize:
                // The reviewed runner may discover that another owner won the
                // claim during either authorization-side identity recheck. A
                // false result did not launch anything and must not consume
                // this invocation's one destructive-start opportunity.
                let launched = try executeReviewedRunnerForUninstall(
                    requirement
                )
                tracker.recordAuthorizationAttempt(
                    launchedReviewedRunner: launched
                )
            case .reject:
                throw PatcherError.controllerSetupFailed(
                    "root uninstall entered an unrecognized intermediate state"
                )
            }
            try await Task.sleep(
                for: .milliseconds(requirement.pollMilliseconds)
            )
        }
        throw PatcherError.controllerSetupTimedOut
    }

    private func operationClaimObservation(
        _ requirement: ControllerPackageRequirement
    ) throws -> ControllerOperationClaimObservation {
        let path = requirement.operationClaim.path
        let before = try operationClaimIdentity(at: path)
        if before == nil {
            let after = try operationClaimIdentity(at: path)
            if let observation = ControllerOperationClaimHolderClassifier
                .classifyAbsentWithoutHolderQuery(
                    before: before,
                    after: after
                ) {
                return observation
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        let after = try operationClaimIdentity(at: path)
        return ControllerOperationClaimHolderClassifier.classify(
            terminationStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            before: before,
            after: after
        )
    }

    private func operationClaimIdentity(
        at path: String
    ) throws -> ControllerOperationClaimIdentity? {
        var status = stat()
        errno = 0
        let result = path.withCString { lstat($0, &status) }
        if result != 0 && errno == ENOENT { return nil }
        guard result == 0 else {
            throw PatcherError.controllerSetupFailed(
                "cannot inspect the operation claim (errno \(errno))"
            )
        }
        return ControllerOperationClaimIdentity(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino)
        )
    }

    private func openPackage(
        _ packageURL: URL,
        with installerURL: URL
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        return try await withCheckedThrowingContinuation { continuation in
            workspace.open(
                [packageURL],
                withApplicationAt: installerURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing:
                        PatcherError.controllerSetupFailed(
                            "cannot open system Installer: \(error.localizedDescription)"
                        )
                    )
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing:
                        PatcherError.controllerSetupFailed(
                            "system Installer did not return a process identity"
                        )
                    )
                }
            }
        }
    }

    private func waitForExactInstallation(
        requirement: ControllerPackageRequirement,
        installer: NSRunningApplication
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(requirement.timeoutSeconds)
        while clock.now < deadline {
            let state = try await inspect(requirement: requirement)
            if case .exact(let evidence) = state,
               evidence.matches(requirement) {
                return
            }
            if installer.isTerminated {
                // Installer termination is never success by itself. One final
                // proof closes the race with postinstall publication.
                try await Task.sleep(
                    for: .milliseconds(requirement.pollMilliseconds)
                )
                let final = try await inspect(requirement: requirement)
                if case .exact(let evidence) = final,
                   evidence.matches(requirement) {
                    return
                }
                throw PatcherError.controllerSetupCancelled
            }
            // During Installer-owned publication, receipt and root files are
            // not atomic as a group. No intermediate state is accepted; keep
            // polling until the exact conjunction appears or Installer exits.
            try await Task.sleep(
                for: .milliseconds(requirement.pollMilliseconds)
            )
        }
        throw PatcherError.controllerSetupTimedOut
    }

    private func packageReceiptState(
        _ requirement: ControllerPackageRequirement
    ) throws -> ControllerPackageReceiptState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--pkg-info-plist", requirement.identifier]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderr, as: UTF8.self)
            if message.hasPrefix("No receipt for '") ||
                message.hasPrefix("No receipt for ") {
                return .absent
            }
            return .unknown(
                "pkgutil could not prove receipt state (status \(process.terminationStatus))"
            )
        }
        guard let plist = try PropertyListSerialization.propertyList(
            from: stdout,
            options: [],
            format: nil
        ) as? [String: Any],
              plist["pkgid"] as? String == requirement.identifier,
              plist["pkg-version"] as? String == requirement.version,
              plist["volume"] as? String == "/" else {
            return .unknown("the package receipt identity is not exact")
        }
        return .exact
    }

    @discardableResult
    private func executeReviewedRunnerForUninstall(
        _ requirement: ControllerPackageRequirement
    ) throws -> Bool {
        // The root-owned runner itself proves there is no active lease and
        // performs the crash-recoverable r6 clean uninstall. No password is
        // read, passed as an argument, logged, or retained by this process.
        let beforeAuthorization = try RootControllerInstallationVerifier.inspect(
            requirement: requirement,
            receipt: packageReceiptState(requirement),
            operationClaim: operationClaimObservation(requirement)
        )
        if beforeAuthorization == .uninstallingActive { return false }
        guard uninstallMayAuthorize(beforeAuthorization, requirement) else {
            throw PatcherError.controllerSetupFailed(
                "runner identity changed before authorization"
            )
        }

        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess,
              let authorization else {
            throw PatcherError.controllerSetupFailed(
                "AuthorizationCreate failed (\(createStatus))"
            )
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        let rightsStatus: OSStatus = "system.privilege.admin".withCString {
            rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        if rightsStatus == errAuthorizationCanceled {
            throw PatcherError.controllerSetupCancelled
        }
        guard rightsStatus == errAuthorizationSuccess else {
            throw PatcherError.controllerSetupFailed(
                "administrator authorization was denied (\(rightsStatus))"
            )
        }

        let afterAuthorization = try RootControllerInstallationVerifier.inspect(
            requirement: requirement,
            receipt: packageReceiptState(requirement),
            operationClaim: operationClaimObservation(requirement)
        )
        if afterAuthorization == .uninstallingActive { return false }
        guard uninstallMayAuthorize(afterAuthorization, requirement) else {
            throw PatcherError.controllerSetupFailed(
                "runner identity changed after authorization"
            )
        }
        let status = try executeWithPrivileges(
            authorization: authorization,
            executablePath: requirement.runner.path,
            argument: "--uninstall"
        )
        if status == errAuthorizationCanceled {
            throw PatcherError.controllerSetupCancelled
        }
        guard status == errAuthorizationSuccess else {
            throw PatcherError.controllerSetupFailed(
                "privileged uninstall could not start (\(status))"
            )
        }
        return true
    }

    private func uninstallMayAuthorize(
        _ state: ControllerInstallationState,
        _ requirement: ControllerPackageRequirement
    ) -> Bool {
        switch state {
        case .exact(let evidence): return evidence.matches(requirement)
        case .uninstalling: return true
        default: return false
        }
    }

    private func executeWithPrivileges(
        authorization: AuthorizationRef,
        executablePath: String,
        argument: String
    ) throws -> OSStatus {
        try executablePath.withCString { executable in
            try argument.withCString { argumentPointer in
                let arguments = UnsafeMutablePointer<
                    UnsafeMutablePointer<CChar>?
                >.allocate(capacity: 2)
                defer { arguments.deallocate() }
                arguments.initialize(
                    to: UnsafeMutablePointer(mutating: argumentPointer)
                )
                arguments.advanced(by: 1).initialize(to: nil)
                typealias Execute = @convention(c) (
                    AuthorizationRef,
                    UnsafePointer<CChar>,
                    AuthorizationFlags,
                    UnsafePointer<UnsafeMutablePointer<CChar>>,
                    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
                ) -> OSStatus
                guard let handle = dlopen(
                    "/System/Library/Frameworks/Security.framework/Security",
                    RTLD_LAZY | RTLD_LOCAL
                ) else {
                    throw PatcherError.controllerSetupFailed(
                        "Authorization Services is unavailable"
                    )
                }
                defer { dlclose(handle) }
                guard let symbol = dlsym(
                    handle,
                    "AuthorizationExecuteWithPrivileges"
                ) else {
                    throw PatcherError.controllerSetupFailed(
                        "privileged execution API is unavailable"
                    )
                }
                let execute = unsafeBitCast(symbol, to: Execute.self)
                let cArguments = UnsafeRawPointer(arguments).assumingMemoryBound(
                    to: UnsafeMutablePointer<CChar>.self
                )
                return execute(
                    authorization,
                    executable,
                    [],
                    cArguments,
                    nil
                )
            }
        }
    }
}
