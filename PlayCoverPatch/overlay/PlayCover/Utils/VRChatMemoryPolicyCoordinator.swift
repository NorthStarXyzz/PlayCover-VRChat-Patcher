//
//  VRChatMemoryPolicyCoordinator.swift
//  PlayCover VRChat
//
//  Fail-closed coordination for the separately installed root memory-policy
//  runner. The developer Alpha uses macOS Authorization Services directly;
//  it never opens Terminal, invokes a shell, or handles an administrator
//  password. A signed SMAppService helper is intentionally unavailable in
//  this source-only release.
//

import Darwin
import CryptoKit
import Dispatch
import Foundation
import Security
import SwiftUI

enum PlayCoverVRChatBuildIdentity {
    static let bundleIdentifier = "io.github.northstarxyzz.PlayCoverVRChat"
    static let displayName = "PlayCover VRChat"
    static let containerDirectoryName = bundleIdentifier
}

enum VRChatMemoryPolicyManifest {
    static let bundleIdentifier = "com.vrchat.mobile"
    static let protocolVersion = "PCVR/2"
    static let socketPath =
        "/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock"
    static let runnerPath = "/usr/local/bin/playcover-vrchat-memory-policy"
    static let reviewedRunnerSHA256 =
        "26d2e2776f17707d7ca15469bf00890b547210b8416a9b9ef39144032764e9af"
    static let controllerBuildID = "25G70-vrchat-2026.2.30300-1365-r6"
    static let expectedShortVersion = "2026.2.30300"
    static let expectedBuildVersion = "1365"
    static let expectedExecutableName = "VRChat"
    static let reviewedMachOCount = 46
    static let reviewedMachOAllowlistSHA256 =
        "60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109"
    static let reviewedMainUUID = "41cadb30ccef3b6c8a1d237ce5d64c42"
    static let reviewedMainNormalizedUnsignedSHA256 =
        "cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3"
    static let reviewedMainNormalizedLoadCommandsSHA256 =
        "664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb"
    // The root controller performs a full reviewed-bundle/Mach-O identity
    // check before publishing its socket.  Five seconds is too short on a
    // cold filesystem scan; keep this bounded, but give that fail-closed
    // preflight enough time to finish.
    static let handshakeTimeout: TimeInterval = 30
    static let minimumLimitGiB: UInt16 = 4
    static let lowMemoryWarningBelowGiB: UInt16 = 8
    static let mebibytesPerGibibyte: UInt64 = 1_024
    static let bytesPerGibibyte: UInt64 = 1_073_741_824

    static func expectedAppURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(
                PlayCoverVRChatBuildIdentity.containerDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                bundleIdentifier + ".app",
                isDirectory: true
            )
    }

    static func matches(bundleIdentifier: String) -> Bool {
        bundleIdentifier == self.bundleIdentifier
    }

    static func matches(controllerBuildID: String) -> Bool {
        controllerBuildID == self.controllerBuildID
    }
}

enum PlayAppLaunchMode {
    case automatic
    case standard

    /// VRChat has no standard-launch escape hatch in this customized build.
    /// Keeping `standard` permits the existing non-VRChat call sites to retain
    /// their upstream behavior without making it a VRChat fallback.
    func resolved(for bundleIdentifier: String) -> ResolvedPlayAppLaunchMode {
        if VRChatMemoryPolicyManifest.matches(bundleIdentifier: bundleIdentifier) {
            return .vrChatCompatible
        }
        return .standard
    }
}

enum ResolvedPlayAppLaunchMode {
    case standard
    case vrChatCompatible
}

enum VRChatMemoryPolicyMode: Equatable {
    case automatic75Percent
    case customGiB(UInt16)
}

struct VRChatMemoryPolicySnapshot: Equatable {
    let mode: VRChatMemoryPolicyMode
    let selectedLimitGiB: UInt16
    let safeMaximumGiB: UInt16

    var selectedLimitMiB: UInt64 {
        UInt64(selectedLimitGiB)
            * VRChatMemoryPolicyManifest.mebibytesPerGibibyte
    }

    var safeMaximumMiB: UInt64 {
        UInt64(safeMaximumGiB)
            * VRChatMemoryPolicyManifest.mebibytesPerGibibyte
    }

    var shouldWarnLowMemory: Bool {
        selectedLimitGiB
            < VRChatMemoryPolicyManifest.lowMemoryWarningBelowGiB
    }

    static func make(
        mode: VRChatMemoryPolicyMode,
        physicalMemoryBytes: UInt64
    ) throws -> VRChatMemoryPolicySnapshot {
        let safeMaximum = try safeMaximumGiB(
            physicalMemoryBytes: physicalMemoryBytes
        )

        let selected: UInt16
        switch mode {
        case .automatic75Percent:
            selected = safeMaximum
        case let .customGiB(value):
            guard value >= VRChatMemoryPolicyManifest.minimumLimitGiB,
                  value <= safeMaximum else {
                throw VRChatMemoryPolicyConfigurationError.customOutsideSafeRange(
                    requestedGiB: value,
                    safeMaximumGiB: safeMaximum
                )
            }
            selected = value
        }

        return VRChatMemoryPolicySnapshot(
            mode: mode,
            selectedLimitGiB: selected,
            safeMaximumGiB: safeMaximum
        )
    }

    /// Computes floor(physicalBytes * 75% / GiB) without overflowing UInt64.
    static func safeMaximumGiB(
        physicalMemoryBytes: UInt64
    ) throws -> UInt16 {
        let denominator = VRChatMemoryPolicyManifest.bytesPerGibibyte * 4
        let wholeGroups = physicalMemoryBytes / denominator
        let remainder = physicalMemoryBytes % denominator
        let safeGiB = wholeGroups * 3 + (remainder * 3) / denominator

        guard safeGiB >= UInt64(VRChatMemoryPolicyManifest.minimumLimitGiB) else {
            throw VRChatMemoryPolicyConfigurationError.insufficientPhysicalMemory(
                safeMaximumGiB: safeGiB
            )
        }
        guard safeGiB <= UInt64(UInt16.max) else {
            throw VRChatMemoryPolicyConfigurationError.physicalMemoryOutOfRange
        }
        return UInt16(safeGiB)
    }
}

enum VRChatMemoryPolicyConfigurationError: LocalizedError, Equatable {
    case physicalMemoryUnavailable(Int32)
    case insufficientPhysicalMemory(safeMaximumGiB: UInt64)
    case physicalMemoryOutOfRange
    case invalidStoredMode(String)
    case invalidStoredCustomGiB(Int)
    case customOutsideSafeRange(requestedGiB: UInt16, safeMaximumGiB: UInt16)

    var stableCode: String {
        switch self {
        case .physicalMemoryUnavailable:
            return "physical_memory_unavailable"
        case .insufficientPhysicalMemory:
            return "insufficient_physical_memory"
        case .physicalMemoryOutOfRange:
            return "physical_memory_out_of_range"
        case .invalidStoredMode:
            return "invalid_stored_mode"
        case .invalidStoredCustomGiB:
            return "invalid_stored_custom_limit"
        case .customOutsideSafeRange:
            return "custom_limit_out_of_range"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .physicalMemoryUnavailable(errorNumber):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.physicalMemory", comment: ""
            ), String(cString: strerror(errorNumber)))
        case let .insufficientPhysicalMemory(safeMaximumGiB):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.insufficientMemory", comment: ""
            ), safeMaximumGiB)
        case .physicalMemoryOutOfRange:
            return NSLocalizedString(
                "error.vrchatMemoryPolicy.physicalMemoryRange", comment: ""
            )
        case let .invalidStoredMode(value):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.invalidMode", comment: ""
            ), value)
        case let .invalidStoredCustomGiB(value):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.invalidCustom", comment: ""
            ), value)
        case let .customOutsideSafeRange(requestedGiB, safeMaximumGiB):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.customRange", comment: ""
            ), requestedGiB, safeMaximumGiB)
        }
    }
}

protocol PhysicalMemoryProviding {
    func physicalMemoryBytes() throws -> UInt64
}

struct HostPhysicalMemoryProvider: PhysicalMemoryProviding {
    func physicalMemoryBytes() throws -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0,
              size == MemoryLayout<UInt64>.size,
              value > 0 else {
            throw VRChatMemoryPolicyConfigurationError
                .physicalMemoryUnavailable(errno)
        }
        return value
    }
}

enum VRChatMemoryPolicySettingsKeys {
    static let mode = "pcvr.memoryPolicy.mode"
    static let customGiB = "pcvr.memoryPolicy.customGiB"
    static let automaticValue = "automatic75Percent"
    static let customValue = "customGiB"
}

protocol VRChatMemoryPolicyConfigurationProviding {
    func snapshot() throws -> VRChatMemoryPolicySnapshot
}

struct UserDefaultsVRChatMemoryPolicyConfigurationProvider:
    VRChatMemoryPolicyConfigurationProviding {

    let defaults: UserDefaults
    let physicalMemoryProvider: PhysicalMemoryProviding

    init(
        defaults: UserDefaults = .standard,
        physicalMemoryProvider: PhysicalMemoryProviding = HostPhysicalMemoryProvider()
    ) {
        self.defaults = defaults
        self.physicalMemoryProvider = physicalMemoryProvider
    }

    func snapshot() throws -> VRChatMemoryPolicySnapshot {
        let storedMode = defaults.string(
            forKey: VRChatMemoryPolicySettingsKeys.mode
        ) ?? VRChatMemoryPolicySettingsKeys.automaticValue

        let mode: VRChatMemoryPolicyMode
        switch storedMode {
        case VRChatMemoryPolicySettingsKeys.automaticValue:
            mode = .automatic75Percent
        case VRChatMemoryPolicySettingsKeys.customValue:
            let customValue: Int
            if defaults.object(
                forKey: VRChatMemoryPolicySettingsKeys.customGiB
            ) == nil {
                customValue = Int(
                    VRChatMemoryPolicyManifest.lowMemoryWarningBelowGiB
                )
            } else {
                customValue = defaults.integer(
                    forKey: VRChatMemoryPolicySettingsKeys.customGiB
                )
            }
            guard customValue >= 0,
                  customValue <= Int(UInt16.max) else {
                throw VRChatMemoryPolicyConfigurationError
                    .invalidStoredCustomGiB(customValue)
            }
            mode = .customGiB(UInt16(customValue))
        default:
            throw VRChatMemoryPolicyConfigurationError
                .invalidStoredMode(storedMode)
        }

        return try VRChatMemoryPolicySnapshot.make(
            mode: mode,
            physicalMemoryBytes: physicalMemoryProvider.physicalMemoryBytes()
        )
    }
}

struct VRChatCompatibleBundleIdentity: Equatable {
    let appURL: URL
    let executableURL: URL
    let machoCount: Int
    let machoAllowlistSHA256: String
    let mainUUID: String
    let mainNormalizedUnsignedSHA256: String
    let mainNormalizedLoadCommandsSHA256: String
    let entitlementsSHA256: String
}

protocol VRChatCompatibleBundleIdentityValidating {
    func validate(
        appURL: URL,
        bundleIdentifier: String
    ) throws -> VRChatCompatibleBundleIdentity
}

enum VRChatCompatibleBundleIdentityError: LocalizedError, Equatable {
    case unexpectedAppURL(expected: String, found: String)
    case unsafePath(path: String, reason: String)
    case invalidBundleMetadata(reason: String)
    case invalidCodeSignature(OSStatus)
    case identityMismatch(reason: String)
    case launchedProcessMismatch(reason: String)
    case targetPIDMismatch(expected: pid_t, found: pid_t)

    var stableCode: String {
        switch self {
        case .unexpectedAppURL:
            return "unexpected_app_url"
        case .unsafePath:
            return "unsafe_app_path"
        case .invalidBundleMetadata:
            return "invalid_bundle_metadata"
        case .invalidCodeSignature:
            return "invalid_bundle_signature"
        case .identityMismatch:
            return "reviewed_identity_mismatch"
        case .launchedProcessMismatch:
            return "launchservices_process_mismatch"
        case .targetPIDMismatch:
            return "target_pid_mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .unexpectedAppURL(expected, found):
            return String(format: NSLocalizedString(
                "error.vrchatIdentity.unexpectedURL", comment: ""
            ), expected, found)
        case let .unsafePath(path, reason):
            return String(format: NSLocalizedString(
                "error.vrchatIdentity.unsafePath", comment: ""
            ), path, reason)
        case let .invalidBundleMetadata(reason),
             let .identityMismatch(reason),
             let .launchedProcessMismatch(reason):
            return String(format: NSLocalizedString(
                "error.vrchatIdentity.mismatch", comment: ""
            ), reason)
        case let .invalidCodeSignature(status):
            return String(format: NSLocalizedString(
                "error.vrchatIdentity.signature", comment: ""
            ), status)
        case let .targetPIDMismatch(expected, found):
            return String(format: NSLocalizedString(
                "error.vrchatIdentity.pid", comment: ""
            ), expected, found)
        }
    }
}

enum PCVRFilesystemSafety {
    static let dangerousFlags = UInt32(
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
    )

    static func metadataIsSafe(
        _ metadata: stat,
        expectedUID: uid_t,
        expectedType: mode_t,
        hasExtendedACL: Bool,
        requiresSingleLink: Bool
    ) -> Bool {
        metadata.st_uid == expectedUID
            && metadata.st_mode & S_IFMT == expectedType
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            && metadata.st_flags & dangerousFlags == 0
            && !hasExtendedACL
            && metadata.st_nlink > 0
            && (!requiresSingleLink || metadata.st_nlink == 1)
    }

    static func statIsUnchanged(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_uid == right.st_uid
            && left.st_gid == right.st_gid
            && left.st_mode == right.st_mode
            && left.st_size == right.st_size
            && left.st_nlink == right.st_nlink
            && left.st_flags == right.st_flags
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }

    static func pathHasExtendedACL(
        _ path: String,
        expectedMetadata: stat? = nil
    ) throws -> Bool {
        errno = 0
        let acl = acl_get_file(path, ACL_TYPE_EXTENDED)
        let savedError = errno
        if let expectedMetadata {
            var currentMetadata = stat()
            guard lstat(path, &currentMetadata) == 0,
                  statIsUnchanged(expectedMetadata, currentMetadata) else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "changed_during_acl_inspection"
                )
            }
        }
        guard let acl else {
            // Darwin reports ENOENT both when a path vanished and when a
            // stable object has no extended ACL. The stable lstat comparison
            // above distinguishes the fail-closed path-race case.
            if savedError == ENOENT, expectedMetadata != nil { return false }
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "acl_get_file_\(savedError)"
            )
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        // On Darwin, ACL_TYPE_EXTENDED returns nil/ENOENT when no extended
        // ACL exists. A nonnil acl_t therefore means the node has an extended
        // ACL; acl_get_entry returns 0 for a successfully retrieved entry and
        // must not be interpreted as an empty list.
        return true
    }

    static func descriptorHasExtendedACL(
        _ descriptor: Int32,
        path: String,
        expectedMetadata: stat? = nil
    ) throws -> Bool {
        errno = 0
        let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
        let savedError = errno
        if let expectedMetadata {
            var currentMetadata = stat()
            guard fstat(descriptor, &currentMetadata) == 0,
                  statIsUnchanged(expectedMetadata, currentMetadata) else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "descriptor_changed_during_acl_inspection"
                )
            }
        }
        guard let acl else {
            if savedError == ENOENT, expectedMetadata != nil { return false }
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "acl_get_fd_\(savedError)"
            )
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        return true
    }

    static func readExact(
        descriptor: Int32,
        count: Int,
        offset: Int64,
        path: String
    ) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var completed = 0
        while completed < count {
            let amount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return pread(
                    descriptor,
                    base.advanced(by: completed),
                    count - completed,
                    off_t(offset + Int64(completed))
                )
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "pread_\(amount < 0 ? errno : EIO)"
                )
            }
            completed += amount
        }
        return Data(bytes)
    }

    static func updateSHA256(
        _ hasher: inout SHA256,
        descriptor: Int32,
        offset: UInt64,
        length: UInt64,
        path: String
    ) throws {
        var cursor = offset
        var remaining = length
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while remaining > 0 {
            let requested = min(UInt64(bytes.count), remaining)
            let amount = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return pread(
                    descriptor,
                    base,
                    Int(requested),
                    off_t(cursor)
                )
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "pread_\(amount < 0 ? errno : EIO)"
                )
            }
            hasher.update(data: Data(bytes[0..<amount]))
            cursor += UInt64(amount)
            remaining -= UInt64(amount)
        }
    }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct PCVRNormalizedMachOIdentity: Equatable {
    let relativePath: String
    let uuidHex: String
    let normalizedUnsignedSHA256: String
    let normalizedLoadCommandsSHA256: String
}

private enum PCVRMachOIdentityInspector {
    private static let magic64: UInt32 = 0xfeedfacf
    private static let cpuTypeARM64: UInt32 = 0x0100000c
    private static let loadCommandUUID: UInt32 = 0x1b
    private static let loadCommandCodeSignature: UInt32 = 0x1d
    private static let loadCommandSegment64: UInt32 = 0x19

    static func isMachO(path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "open_\(errno)"
            )
        }
        defer { _ = close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 4)
        let amount = bytes.withUnsafeMutableBytes { buffer in
            read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard amount >= 0 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "read_\(errno)"
            )
        }
        guard amount == 4 else { return false }
        let magic = bytes.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        return [
            UInt32(0xfeedface), UInt32(0xcefaedfe), magic64,
            UInt32(0xcffaedfe), UInt32(0xbebafeca),
            UInt32(0xcafebabe), UInt32(0xbfbafeca), UInt32(0xcafebabf)
        ].contains(magic)
    }

    static func identity(
        path: String,
        relativePath: String,
        expectedUID: uid_t,
        requireExecutable: Bool
    ) throws -> PCVRNormalizedMachOIdentity {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "open_\(errno)"
            )
        }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "fstat_\(errno)"
            )
        }
        let hasACL = try PCVRFilesystemSafety.descriptorHasExtendedACL(
            descriptor,
            path: path,
            expectedMetadata: before
        )
        guard PCVRFilesystemSafety.metadataIsSafe(
            before,
            expectedUID: expectedUID,
            expectedType: S_IFREG,
            hasExtendedACL: hasACL,
            requiresSingleLink: true
        ), !requireExecutable || before.st_mode & S_IXUSR != 0,
           before.st_size >= 32 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "unsafe_macho_metadata"
            )
        }

        let header = try PCVRFilesystemSafety.readExact(
            descriptor: descriptor,
            count: 32,
            offset: 0,
            path: path
        )
        guard readUInt32(header, 0) == magic64,
              readUInt32(header, 4) == cpuTypeARM64 else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "non_thin_arm64_macho:\(relativePath)"
            )
        }
        let commandCount = Int(readUInt32(header, 16))
        let commandsSize = Int(readUInt32(header, 20))
        guard commandCount > 0, commandCount <= 4_096,
              commandsSize >= 8, commandsSize <= 1_048_576,
              UInt64(32 + commandsSize) <= UInt64(before.st_size) else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "invalid_load_commands:\(relativePath)"
            )
        }
        var commands = try PCVRFilesystemSafety.readExact(
            descriptor: descriptor,
            count: 32 + commandsSize,
            offset: 0,
            path: path
        )

        var cursor = 32
        var uuidBytes: [UInt8]?
        var uuidCount = 0
        var linkeditOffset: Int?
        var linkeditCount = 0
        var signatureCommandOffset: Int?
        var signatureOffset = 0
        var signatureSize = 0
        var signatureCount = 0
        for _ in 0..<commandCount {
            guard cursor + 8 <= commands.count else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "truncated_load_command:\(relativePath)"
                )
            }
            let command = readUInt32(commands, cursor)
            let size = Int(readUInt32(commands, cursor + 4))
            guard size >= 8, cursor + size <= commands.count else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "invalid_load_command:\(relativePath)"
                )
            }
            if command == loadCommandUUID {
                guard size == 24 else {
                    throw VRChatCompatibleBundleIdentityError.identityMismatch(
                        reason: "invalid_uuid_command:\(relativePath)"
                    )
                }
                uuidBytes = [UInt8](commands[(cursor + 8)..<(cursor + 24)])
                uuidCount += 1
            } else if command == loadCommandCodeSignature {
                guard size == 16 else {
                    throw VRChatCompatibleBundleIdentityError.identityMismatch(
                        reason: "invalid_signature_command:\(relativePath)"
                    )
                }
                signatureCommandOffset = cursor
                signatureOffset = Int(readUInt32(commands, cursor + 8))
                signatureSize = Int(readUInt32(commands, cursor + 12))
                signatureCount += 1
            } else if command == loadCommandSegment64, size >= 72 {
                let nameBytes = commands[(cursor + 8)..<(cursor + 24)]
                let name = String(
                    decoding: nameBytes.prefix { $0 != 0 },
                    as: UTF8.self
                )
                if name == "__LINKEDIT" {
                    linkeditOffset = cursor
                    linkeditCount += 1
                }
            }
            cursor += size
        }

        guard cursor == commands.count,
              uuidCount == 1,
              let uuidBytes,
              signatureCount == 1,
              let signatureCommandOffset,
              signatureSize > 0,
              signatureOffset >= commands.count,
              signatureOffset <= Int(before.st_size),
              signatureSize <= Int(before.st_size) - signatureOffset,
              linkeditCount == 1,
              let linkeditOffset else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "incomplete_macho_identity:\(relativePath)"
            )
        }

        zero(&commands, at: signatureCommandOffset + 8, count: 8)
        zero(&commands, at: linkeditOffset + 32, count: 8)
        zero(&commands, at: linkeditOffset + 48, count: 8)

        var loadHasher = SHA256()
        loadHasher.update(data: commands)
        var unsignedHasher = SHA256()
        unsignedHasher.update(data: commands)
        try PCVRFilesystemSafety.updateSHA256(
            &unsignedHasher,
            descriptor: descriptor,
            offset: UInt64(commands.count),
            length: UInt64(signatureOffset - commands.count),
            path: path
        )
        let signatureEnd = signatureOffset + signatureSize
        try PCVRFilesystemSafety.updateSHA256(
            &unsignedHasher,
            descriptor: descriptor,
            offset: UInt64(signatureEnd),
            length: UInt64(before.st_size) - UInt64(signatureEnd),
            path: path
        )

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              PCVRFilesystemSafety.statIsUnchanged(before, after) else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: path,
                reason: "macho_changed_during_read"
            )
        }
        return PCVRNormalizedMachOIdentity(
            relativePath: relativePath,
            uuidHex: uuidBytes.map { String(format: "%02x", $0) }.joined(),
            normalizedUnsignedSHA256:
                PCVRFilesystemSafety.hex(unsignedHasher.finalize()),
            normalizedLoadCommandsSHA256:
                PCVRFilesystemSafety.hex(loadHasher.finalize())
        )
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }

    private static func zero(_ data: inout Data, at offset: Int, count: Int) {
        data.replaceSubrange(
            offset..<(offset + count),
            with: repeatElement(UInt8(0), count: count)
        )
    }
}

struct SystemVRChatCompatibleBundleIdentityValidator:
    VRChatCompatibleBundleIdentityValidating {

    let homeDirectory: URL
    let expectedUID: uid_t

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedUID: uid_t = geteuid()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.expectedUID = expectedUID
    }

    func validate(
        appURL: URL,
        bundleIdentifier: String
    ) throws -> VRChatCompatibleBundleIdentity {
        guard bundleIdentifier == VRChatMemoryPolicyManifest.bundleIdentifier else {
            throw VRChatCompatibleBundleIdentityError.invalidBundleMetadata(
                reason: "wrong_bundle_identifier"
            )
        }
        try Self.validateExactLocation(
            appURL: appURL,
            homeDirectory: homeDirectory,
            expectedUID: expectedUID
        )
        let expectedURL = VRChatMemoryPolicyManifest.expectedAppURL(
            homeDirectory: homeDirectory
        )
        let infoURL = expectedURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            format: nil
        ) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == VRChatMemoryPolicyManifest.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String
                == VRChatMemoryPolicyManifest.expectedShortVersion,
              info["CFBundleVersion"] as? String
                == VRChatMemoryPolicyManifest.expectedBuildVersion,
              info["CFBundleExecutable"] as? String
                == VRChatMemoryPolicyManifest.expectedExecutableName else {
            throw VRChatCompatibleBundleIdentityError.invalidBundleMetadata(
                reason: "Info.plist"
            )
        }
        let executableURL = expectedURL.appendingPathComponent(
            VRChatMemoryPolicyManifest.expectedExecutableName
        )

        try verifyStrictCodeSignature(appURL: expectedURL)
        let entitlementsSHA256 = try canonicalEntitlementsSHA256(
            executableURL: executableURL,
            homeDirectory: homeDirectory
        )
        guard entitlementsSHA256 ==
                "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4" else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "entitlements_sha256"
            )
        }

        let identities = try enumerateMachOIdentities(
            appURL: expectedURL,
            expectedUID: expectedUID
        )
        guard identities.count == VRChatMemoryPolicyManifest.reviewedMachOCount else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "macho_count_\(identities.count)"
            )
        }
        let digest = allowlistSHA256(identities)
        guard digest == VRChatMemoryPolicyManifest.reviewedMachOAllowlistSHA256 else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "macho_allowlist_sha256"
            )
        }
        guard let main = identities.first(where: {
            $0.relativePath == VRChatMemoryPolicyManifest.expectedExecutableName
        }),
              main.uuidHex == VRChatMemoryPolicyManifest.reviewedMainUUID,
              main.normalizedUnsignedSHA256 ==
                VRChatMemoryPolicyManifest.reviewedMainNormalizedUnsignedSHA256,
              main.normalizedLoadCommandsSHA256 ==
                VRChatMemoryPolicyManifest.reviewedMainNormalizedLoadCommandsSHA256 else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "main_composite_identity"
            )
        }

        return VRChatCompatibleBundleIdentity(
            appURL: expectedURL,
            executableURL: executableURL,
            machoCount: identities.count,
            machoAllowlistSHA256: digest,
            mainUUID: main.uuidHex,
            mainNormalizedUnsignedSHA256: main.normalizedUnsignedSHA256,
            mainNormalizedLoadCommandsSHA256:
                main.normalizedLoadCommandsSHA256,
            entitlementsSHA256: entitlementsSHA256
        )
    }

    static func validateExactLocation(
        appURL: URL,
        homeDirectory: URL,
        expectedUID: uid_t
    ) throws {
        let normalizedHome = homeDirectory.standardizedFileURL
        let expectedURL = VRChatMemoryPolicyManifest.expectedAppURL(
            homeDirectory: normalizedHome
        )
        guard appURL.isFileURL,
              appURL.path == expectedURL.path else {
            throw VRChatCompatibleBundleIdentityError.unexpectedAppURL(
                expected: expectedURL.path,
                found: appURL.path
            )
        }
        guard expectedUID != 0 else {
            throw VRChatCompatibleBundleIdentityError.unsafePath(
                path: expectedURL.path,
                reason: "root_console_user"
            )
        }
        let paths = [
            normalizedHome.path,
            normalizedHome.appendingPathComponent("Library").path,
            normalizedHome.appendingPathComponent("Library/Containers").path,
            normalizedHome.appendingPathComponent(
                "Library/Containers/"
                    + PlayCoverVRChatBuildIdentity.containerDirectoryName
            ).path,
            normalizedHome.appendingPathComponent(
                "Library/Containers/"
                    + PlayCoverVRChatBuildIdentity.containerDirectoryName
                    + "/Applications"
            ).path,
            expectedURL.path
        ]
        for path in paths {
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "lstat_\(errno)"
                )
            }
            let hasACL = try PCVRFilesystemSafety.pathHasExtendedACL(
                path,
                expectedMetadata: metadata
            )
            guard PCVRFilesystemSafety.metadataIsSafe(
                metadata,
                expectedUID: expectedUID,
                expectedType: S_IFDIR,
                hasExtendedACL: hasACL,
                requiresSingleLink: false
            ) else {
                throw VRChatCompatibleBundleIdentityError.unsafePath(
                    path: path,
                    reason: "unsafe_directory_metadata"
                )
            }
        }
    }

    private func verifyStrictCodeSignature(appURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw VRChatCompatibleBundleIdentityError
                .invalidCodeSignature(createStatus)
        }
        let status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSStrictValidate |
                    kSecCSCheckAllArchitectures |
                    kSecCSCheckNestedCode
            ),
            nil
        )
        guard status == errSecSuccess else {
            throw VRChatCompatibleBundleIdentityError.invalidCodeSignature(status)
        }
    }

    private func canonicalEntitlementsSHA256(
        executableURL: URL,
        homeDirectory: URL
    ) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw VRChatCompatibleBundleIdentityError
                .invalidCodeSignature(createStatus)
        }
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String]
                as? [String: Any] else {
            throw VRChatCompatibleBundleIdentityError
                .invalidCodeSignature(infoStatus)
        }

        let home = homeDirectory.standardizedFileURL.path
        var canonical = Data("PCVR-ENTITLEMENTS/1\n".utf8)
        let keys = entitlements.keys.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        var arrayCount = 0
        for key in keys {
            guard let value = entitlements[key] else { continue }
            let keyBytes = Data(key.utf8)
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                guard CFBooleanGetValue((value as! CFBoolean)) else {
                    throw VRChatCompatibleBundleIdentityError.identityMismatch(
                        reason: "false_entitlement"
                    )
                }
                canonical.append(contentsOf: "B \(keyBytes.count) ".utf8)
                canonical.append(keyBytes)
                canonical.append(0x0a)
                continue
            }
            guard let values = value as? [String] else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "unsupported_entitlement_type"
                )
            }
            arrayCount += 1
            guard arrayCount == 1 else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "multiple_entitlement_arrays"
                )
            }
            canonical.append(
                contentsOf: "A \(keyBytes.count) ".utf8
            )
            canonical.append(keyBytes)
            canonical.append(contentsOf: " \(values.count)\n".utf8)
            for value in values {
                let normalized = value.replacingOccurrences(
                    of: home,
                    with: "@CONSOLE_HOME@"
                )
                let bytes = Data(normalized.utf8)
                canonical.append(contentsOf: "S \(bytes.count) ".utf8)
                canonical.append(bytes)
                canonical.append(0x0a)
            }
        }
        guard arrayCount == 1 else {
            throw VRChatCompatibleBundleIdentityError.identityMismatch(
                reason: "missing_entitlement_array"
            )
        }
        return PCVRFilesystemSafety.hex(SHA256.hash(data: canonical))
    }

    private func enumerateMachOIdentities(
        appURL: URL,
        expectedUID: uid_t
    ) throws -> [PCVRNormalizedMachOIdentity] {
        let root = appURL.path
        let rootPrefix = root + "/"
        var directories = [root]
        var identities: [PCVRNormalizedMachOIdentity] = []
        while let directory = directories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                atPath: directory
            )
            for name in children {
                guard name != ".", name != "..", !name.contains("/") else {
                    throw VRChatCompatibleBundleIdentityError.unsafePath(
                        path: directory,
                        reason: "invalid_directory_entry"
                    )
                }
                let path = (directory as NSString)
                    .appendingPathComponent(name)
                var metadata = stat()
                guard lstat(path, &metadata) == 0 else {
                    throw VRChatCompatibleBundleIdentityError.unsafePath(
                        path: path,
                        reason: "lstat_\(errno)"
                    )
                }
                let hasACL = try PCVRFilesystemSafety.pathHasExtendedACL(
                    path,
                    expectedMetadata: metadata
                )
                let type = metadata.st_mode & S_IFMT
                if type == S_IFDIR {
                    guard PCVRFilesystemSafety.metadataIsSafe(
                        metadata,
                        expectedUID: expectedUID,
                        expectedType: S_IFDIR,
                        hasExtendedACL: hasACL,
                        requiresSingleLink: false
                    ) else {
                        throw VRChatCompatibleBundleIdentityError.unsafePath(
                            path: path,
                            reason: "unsafe_directory_metadata"
                        )
                    }
                    directories.append(path)
                    continue
                }
                guard type == S_IFREG,
                      PCVRFilesystemSafety.metadataIsSafe(
                        metadata,
                        expectedUID: expectedUID,
                        expectedType: S_IFREG,
                        hasExtendedACL: hasACL,
                        requiresSingleLink: true
                      ) else {
                    throw VRChatCompatibleBundleIdentityError.unsafePath(
                        path: path,
                        reason: "unsafe_file_metadata"
                    )
                }
                guard try PCVRMachOIdentityInspector.isMachO(path: path) else {
                    continue
                }
                guard path.hasPrefix(rootPrefix) else {
                    throw VRChatCompatibleBundleIdentityError.unsafePath(
                        path: path,
                        reason: "outside_bundle"
                    )
                }
                let relative = String(path.dropFirst(rootPrefix.count))
                identities.append(try PCVRMachOIdentityInspector.identity(
                    path: path,
                    relativePath: relative,
                    expectedUID: expectedUID,
                    requireExecutable:
                        relative == VRChatMemoryPolicyManifest.expectedExecutableName
                ))
            }
        }
        return identities.sorted {
            Array($0.relativePath.utf8).lexicographicallyPrecedes(
                Array($1.relativePath.utf8)
            )
        }
    }

    private func allowlistSHA256(
        _ identities: [PCVRNormalizedMachOIdentity]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("PCVR-MACHO-ALLOWLIST/1\n".utf8))
        for identity in identities {
            let line = "M \(identity.relativePath.utf8.count) "
                + identity.relativePath + " "
                + identity.uuidHex + " "
                + identity.normalizedUnsignedSHA256 + " "
                + identity.normalizedLoadCommandsSHA256 + "\n"
            hasher.update(data: Data(line.utf8))
        }
        return PCVRFilesystemSafety.hex(hasher.finalize())
    }
}

struct VRChatMemoryPolicyMetrics: Equatable {
    let pid: pid_t
    let selectedLimitMiB: UInt64
    let footprintMiB: Double
    let headroomMiB: Double
    let reapplies: UInt64
    let pressure: String
}

enum VRChatMemoryPolicyServerEvent: Equatable {
    case targetBound(pid: pid_t)
    case leaseActive(pid: pid_t, selectedLimitMiB: UInt64)
    case metrics(VRChatMemoryPolicyMetrics)
    case completed
    case failed(code: String)
}

protocol VRChatMemoryPolicySession: AnyObject {
    var buildID: String { get }
    var selectedLimitMiB: UInt64 { get }
    var safeMaximumMiB: UInt64 { get }

    func nextEvent() async throws -> VRChatMemoryPolicyServerEvent
    func cancelBeforeTargetBound() async throws
    func close() async
}

protocol VRChatMemoryPolicySessionProvider {
    func openSession(
        socketPath: String,
        timeout: TimeInterval,
        expectedSnapshot: VRChatMemoryPolicySnapshot
    ) async throws -> VRChatMemoryPolicySession
}

protocol VRChatMemoryPolicyAuthorizationProviding {
    func startController(selectedLimitGiB: UInt16) async throws
}

enum VRChatMemoryPolicyAuthorizationError: LocalizedError, Equatable {
    case unsafeRunner(path: String, reason: String)
    case authorizationAPIUnavailable
    case authorizationCreateFailed(OSStatus)
    case authorizationDenied(OSStatus)
    case executeFailed(OSStatus)

    var stableCode: String {
        switch self {
        case .unsafeRunner:
            return "unsafe_runner"
        case .authorizationAPIUnavailable:
            return "authorization_api_unavailable"
        case .authorizationCreateFailed:
            return "authorization_create_failed"
        case .authorizationDenied:
            return "authorization_denied"
        case .executeFailed:
            return "authorization_execute_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .unsafeRunner(path, reason):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.unsafeRunner", comment: ""
            ), path, reason)
        case .authorizationAPIUnavailable:
            return NSLocalizedString(
                "error.vrchatMemoryPolicy.authorizationUnavailable", comment: ""
            )
        case let .authorizationCreateFailed(status):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.authorizationCreate", comment: ""
            ), status)
        case let .authorizationDenied(status):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.authorizationDenied", comment: ""
            ), status)
        case let .executeFailed(status):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.authorizationExecute", comment: ""
            ), status)
        }
    }
}

/// Developer Alpha provider. It validates every component of the fixed path,
/// asks macOS Authorization Services for the one execute right, and passes one
/// canonical decimal argument directly to the runner. The legacy API accepts
/// a pathname rather than a descriptor, so this provider retains an
/// O_NOFOLLOW descriptor identity and revalidates the pathname immediately
/// before and after execution. There is no shell.
final class DeveloperAlphaSystemAuthorizationProvider:
    VRChatMemoryPolicyAuthorizationProviding {

    struct RunnerFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let uid: uid_t
        let gid: gid_t
        let mode: mode_t
        let size: off_t
        let linkCount: nlink_t
        let flags: UInt32
        let changeSeconds: Int
        let changeNanoseconds: Int
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let sha256: String

        init(metadata: stat, sha256: String) {
            device = metadata.st_dev
            inode = metadata.st_ino
            uid = metadata.st_uid
            gid = metadata.st_gid
            mode = metadata.st_mode
            size = metadata.st_size
            linkCount = metadata.st_nlink
            flags = metadata.st_flags
            changeSeconds = metadata.st_ctimespec.tv_sec
            changeNanoseconds = metadata.st_ctimespec.tv_nsec
            modificationSeconds = metadata.st_mtimespec.tv_sec
            modificationNanoseconds = metadata.st_mtimespec.tv_nsec
            self.sha256 = sha256
        }
    }

    private final class RunnerBinding {
        let descriptor: Int32
        let path: String
        let identity: RunnerFileIdentity

        init(
            descriptor: Int32,
            path: String,
            identity: RunnerFileIdentity
        ) {
            self.descriptor = descriptor
            self.path = path
            self.identity = identity
        }

        deinit {
            _ = close(descriptor)
        }
    }

    private let runnerPath: String
    private let queue = DispatchQueue(
        label: "io.github.northstarxyzz.pcvrpatcher.authorization",
        qos: .userInitiated
    )

    init(runnerPath: String = VRChatMemoryPolicyManifest.runnerPath) {
        self.runnerPath = runnerPath
    }

    func startController(selectedLimitGiB: UInt16) async throws {
        guard selectedLimitGiB >= VRChatMemoryPolicyManifest.minimumLimitGiB else {
            throw VRChatMemoryPolicyConfigurationError
                .invalidStoredCustomGiB(Int(selectedLimitGiB))
        }
        let argument = String(selectedLimitGiB)
        guard UInt16(argument) == selectedLimitGiB,
              argument.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw VRChatMemoryPolicyConfigurationError
                .invalidStoredCustomGiB(Int(selectedLimitGiB))
        }
        let runnerPath = self.runnerPath

        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let binding = try Self.openAndValidateFixedRunner(
                        path: runnerPath
                    )
                    try Self.executeWithAuthorization(
                        binding: binding,
                        argument: argument
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func validateFixedRunner(path: String) throws {
        _ = try openAndValidateFixedRunner(path: path)
    }

    static func runnerMetadataIsSafeForTesting(
        _ metadata: stat,
        expectedUID: uid_t = 0,
        hasExtendedACL: Bool,
        isRunner: Bool
    ) -> Bool {
        PCVRFilesystemSafety.metadataIsSafe(
            metadata,
            expectedUID: expectedUID,
            expectedType: isRunner ? S_IFREG : S_IFDIR,
            hasExtendedACL: hasExtendedACL,
            requiresSingleLink: isRunner
        )
            && (isRunner
                ? metadata.st_mode & S_IXUSR != 0 && metadata.st_size > 0
                : metadata.st_mode & S_IXUSR != 0 && metadata.st_nlink >= 2)
    }

    static func runnerIdentitiesMatchForTesting(
        _ before: RunnerFileIdentity,
        _ after: RunnerFileIdentity
    ) -> Bool {
        before == after
    }

    @discardableResult
    static func validateRunnerNode(
        path: String,
        expectedUID: uid_t,
        isRunner: Bool
    ) throws -> stat {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "lstat_\(errno)"
            )
        }
        let hasACL: Bool
        do {
            hasACL = try PCVRFilesystemSafety.pathHasExtendedACL(
                path,
                expectedMetadata: metadata
            )
        } catch {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "acl_inspection_failed"
            )
        }
        guard runnerMetadataIsSafeForTesting(
            metadata,
            expectedUID: expectedUID,
            hasExtendedACL: hasACL,
            isRunner: isRunner
        ) else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: hasACL
                    ? "extended_acl"
                    : "unsafe_owner_mode_flags_or_links"
            )
        }
        return metadata
    }

    private static func openAndValidateFixedRunner(
        path: String
    ) throws -> RunnerBinding {
        guard path == VRChatMemoryPolicyManifest.runnerPath else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "path_not_fixed"
            )
        }

        let requiredPathComponents = [
            "/",
            "/usr",
            "/usr/local",
            "/usr/local/bin",
            VRChatMemoryPolicyManifest.runnerPath
        ]

        for component in requiredPathComponents {
            _ = try validateRunnerNode(
                path: component,
                expectedUID: 0,
                isRunner: component == path
            )
        }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "open_\(errno)"
            )
        }
        var shouldClose = true
        defer {
            if shouldClose { _ = close(descriptor) }
        }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "fstat_\(errno)"
            )
        }
        let descriptorHasACL: Bool
        do {
            descriptorHasACL = try PCVRFilesystemSafety
                .descriptorHasExtendedACL(
                    descriptor,
                    path: path,
                    expectedMetadata: before
                )
        } catch {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "descriptor_acl_inspection_failed"
            )
        }
        guard runnerMetadataIsSafeForTesting(
            before,
            hasExtendedACL: descriptorHasACL,
            isRunner: true
        ) else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: descriptorHasACL
                    ? "extended_acl"
                    : "unsafe_descriptor_metadata"
            )
        }

        let digest: String
        do {
            var hasher = SHA256()
            try PCVRFilesystemSafety.updateSHA256(
                &hasher,
                descriptor: descriptor,
                offset: 0,
                length: UInt64(before.st_size),
                path: path
            )
            digest = PCVRFilesystemSafety.hex(hasher.finalize())
        } catch {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "hash_failed"
            )
        }
        guard digest == VRChatMemoryPolicyManifest.reviewedRunnerSHA256 else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "sha256_mismatch"
            )
        }

        var after = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &after) == 0,
              PCVRFilesystemSafety.statIsUnchanged(before, after),
              lstat(path, &pathMetadata) == 0,
              PCVRFilesystemSafety.statIsUnchanged(after, pathMetadata) else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: path,
                reason: "changed_during_validation"
            )
        }
        let binding = RunnerBinding(
            descriptor: descriptor,
            path: path,
            identity: RunnerFileIdentity(metadata: after, sha256: digest)
        )
        shouldClose = false
        return binding
    }

    private static func revalidateFixedRunner(
        _ binding: RunnerBinding
    ) throws {
        var retainedMetadata = stat()
        guard fstat(binding.descriptor, &retainedMetadata) == 0 else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: binding.path,
                reason: "retained_fstat_\(errno)"
            )
        }
        let retainedIdentity = RunnerFileIdentity(
            metadata: retainedMetadata,
            sha256: binding.identity.sha256
        )
        guard retainedIdentity == binding.identity else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: binding.path,
                reason: "retained_descriptor_changed"
            )
        }
        let current = try openAndValidateFixedRunner(path: binding.path)
        guard current.identity == binding.identity else {
            throw VRChatMemoryPolicyAuthorizationError.unsafeRunner(
                path: binding.path,
                reason: "path_replaced_after_authorization"
            )
        }
    }

    private static func executeWithAuthorization(
        binding: RunnerBinding,
        argument: String
    ) throws {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(
            nil,
            nil,
            [],
            &authorization
        )
        guard createStatus == errAuthorizationSuccess,
              let authorization else {
            throw VRChatMemoryPolicyAuthorizationError
                .authorizationCreateFailed(createStatus)
        }
        defer {
            AuthorizationFree(authorization, [.destroyRights])
        }

        let rightsStatus: OSStatus = "system.privilege.admin".withCString {
            rightCString in
            var item = AuthorizationItem(
                name: rightCString,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(
                    count: 1,
                    items: itemPointer
                )
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard rightsStatus == errAuthorizationSuccess else {
            throw VRChatMemoryPolicyAuthorizationError
                .authorizationDenied(rightsStatus)
        }

        // AuthorizationExecuteWithPrivileges cannot execute an already-open
        // descriptor. Revalidate the retained dev/inode/metadata/hash binding
        // at the last possible point before its unavoidable pathname lookup.
        try revalidateFixedRunner(binding)
        let executeStatus: OSStatus = try binding.path.withCString {
            runnerCString in
            try argument.withCString { argumentCString in
                let arguments = UnsafeMutablePointer<
                    UnsafeMutablePointer<CChar>?
                >.allocate(capacity: 2)
                defer { arguments.deallocate() }
                arguments.initialize(
                    to: UnsafeMutablePointer(mutating: argumentCString)
                )
                arguments.advanced(by: 1).initialize(to: nil)
                let cArguments = UnsafeRawPointer(arguments)
                    .assumingMemoryBound(
                        to: UnsafeMutablePointer<CChar>.self
                    )
                typealias ExecuteWithPrivileges = @convention(c) (
                    AuthorizationRef,
                    UnsafePointer<CChar>,
                    AuthorizationFlags,
                    UnsafePointer<UnsafeMutablePointer<CChar>>,
                    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
                ) -> OSStatus
                guard let securityHandle = dlopen(
                    "/System/Library/Frameworks/Security.framework/Security",
                    RTLD_LAZY | RTLD_LOCAL
                ) else {
                    throw VRChatMemoryPolicyAuthorizationError
                        .authorizationAPIUnavailable
                }
                defer { dlclose(securityHandle) }
                guard let symbol = dlsym(
                    securityHandle,
                    "AuthorizationExecuteWithPrivileges"
                ) else {
                    throw VRChatMemoryPolicyAuthorizationError
                        .authorizationAPIUnavailable
                }
                let execute = unsafeBitCast(
                    symbol,
                    to: ExecuteWithPrivileges.self
                )
                return execute(
                    authorization,
                    runnerCString,
                    [],
                    cArguments,
                    nil
                )
            }
        }
        guard executeStatus == errAuthorizationSuccess else {
            throw VRChatMemoryPolicyAuthorizationError
                .executeFailed(executeStatus)
        }
        // Detect replacement racing the legacy execution call. Detection here
        // is fail-closed but cannot retroactively make the pathname ABI atomic.
        try revalidateFixedRunner(binding)
    }
}

enum VRChatMemoryPolicyFormalAuthorization {
    /// A production SMAppService provider requires a signed embedded helper,
    /// launchd property list, code requirement, XPC audit-token validation,
    /// Developer ID signing, notarization, and real-machine review. None are
    /// present in the developer Alpha, so the feature is explicitly disabled.
    static let isAvailable = false
}

enum VRChatReadOnlyLaunchError: LocalizedError, Equatable {
    case importRequiresCompatibleCopy
    case repairRequired(reason: String)

    var errorDescription: String? {
        switch self {
        case .importRequiresCompatibleCopy:
            return NSLocalizedString(
                "error.vrchatReadOnly.importRequired", comment: ""
            )
        case let .repairRequired(reason):
            let reasonDescription = NSLocalizedString(
                "error.vrchatReadOnly.reason.\(reason)", comment: ""
            )
            return String(format: NSLocalizedString(
                "error.vrchatReadOnly.repairRequired", comment: ""
            ), reasonDescription)
        }
    }
}

enum VRChatMemoryPolicyClientError: LocalizedError, Equatable {
    case wrongBundleIdentifier(String)
    case sessionBusy
    case socketPathTooLong
    case connectionTimedOut
    case connectionFailed(Int32)
    case peerCredentialUnavailable
    case peerIsNotRoot(uid_t)
    case handshakeTimedOut
    case connectionClosed
    case lineTooLong
    case invalidUTF8
    case protocolViolation(String)
    case writeFailed(Int32)
    case cancelAfterTargetBound
    case invalidTransition(String)

    var stableCode: String {
        switch self {
        case .wrongBundleIdentifier:
            return "wrong_bundle"
        case .sessionBusy:
            return "session_busy"
        case .socketPathTooLong:
            return "socket_path_too_long"
        case .connectionTimedOut:
            return "connect_timeout"
        case .connectionFailed:
            return "connect_failed"
        case .peerCredentialUnavailable:
            return "peer_credential_unavailable"
        case .peerIsNotRoot:
            return "peer_not_root"
        case .handshakeTimedOut:
            return "waiting_timeout"
        case .connectionClosed:
            return "connection_closed"
        case .lineTooLong:
            return "line_too_long"
        case .invalidUTF8:
            return "invalid_utf8"
        case .protocolViolation:
            return "protocol_violation"
        case .writeFailed:
            return "write_failed"
        case .cancelAfterTargetBound:
            return "late_cancel"
        case .invalidTransition:
            return "invalid_transition"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .wrongBundleIdentifier(bundleIdentifier):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.wrongBundle", comment: ""
            ), bundleIdentifier)
        case .sessionBusy:
            return NSLocalizedString("error.vrchatMemoryPolicy.busy", comment: "")
        case .connectionTimedOut, .handshakeTimedOut:
            return NSLocalizedString("error.vrchatMemoryPolicy.timeout", comment: "")
        case .peerCredentialUnavailable, .peerIsNotRoot:
            return NSLocalizedString("error.vrchatMemoryPolicy.peer", comment: "")
        case let .connectionFailed(errorNumber):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.connection", comment: ""
            ), String(cString: strerror(errorNumber)))
        case .socketPathTooLong, .connectionClosed, .lineTooLong, .invalidUTF8,
             .protocolViolation, .invalidTransition:
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.protocol", comment: ""
            ), stableCode)
        case let .writeFailed(errorNumber):
            return String(format: NSLocalizedString(
                "error.vrchatMemoryPolicy.cancel", comment: ""
            ), String(cString: strerror(errorNumber)))
        case .cancelAfterTargetBound:
            return NSLocalizedString(
                "error.vrchatMemoryPolicy.lateCancel", comment: ""
            )
        }
    }
}

actor VRChatMemoryPolicyCoordinator {
    enum State: Equatable {
        case idle
        case preflighting
        case authorizing(snapshot: VRChatMemoryPolicySnapshot)
        case connecting(snapshot: VRChatMemoryPolicySnapshot)
        case waiting(buildID: String, snapshot: VRChatMemoryPolicySnapshot)
        case launching(buildID: String, snapshot: VRChatMemoryPolicySnapshot)
        case targetBound(pid: pid_t, snapshot: VRChatMemoryPolicySnapshot)
        case maintaining(pid: pid_t, snapshot: VRChatMemoryPolicySnapshot,
                         metrics: VRChatMemoryPolicyMetrics?)
        case completed
        case cancelRequested
        case failed(code: String)

        var permitsNewSession: Bool {
            switch self {
            case .idle, .completed, .cancelRequested, .failed:
                return true
            case .preflighting, .authorizing, .connecting, .waiting,
                 .launching, .targetBound, .maintaining:
                return false
            }
        }
    }

    static let shared = VRChatMemoryPolicyCoordinator(
        configurationProvider:
            UserDefaultsVRChatMemoryPolicyConfigurationProvider(),
        bundleIdentityValidator:
            SystemVRChatCompatibleBundleIdentityValidator(),
        authorizationProvider: DeveloperAlphaSystemAuthorizationProvider(),
        sessionProvider: UnixSocketVRChatMemoryPolicySessionProvider()
    )

    private(set) var state: State = .idle

    private let configurationProvider: VRChatMemoryPolicyConfigurationProviding
    private let bundleIdentityValidator:
        VRChatCompatibleBundleIdentityValidating
    private let authorizationProvider: VRChatMemoryPolicyAuthorizationProviding
    private let sessionProvider: VRChatMemoryPolicySessionProvider
    private var session: VRChatMemoryPolicySession?
    private var preparedBundleIdentity: VRChatCompatibleBundleIdentity?
    private var monitorTask: Task<Void, Never>?

    init(
        configurationProvider: VRChatMemoryPolicyConfigurationProviding,
        bundleIdentityValidator:
            VRChatCompatibleBundleIdentityValidating,
        authorizationProvider: VRChatMemoryPolicyAuthorizationProviding,
        sessionProvider: VRChatMemoryPolicySessionProvider
    ) {
        self.configurationProvider = configurationProvider
        self.bundleIdentityValidator = bundleIdentityValidator
        self.authorizationProvider = authorizationProvider
        self.sessionProvider = sessionProvider
    }

    @discardableResult
    func prepareForCompatibleLaunch(
        bundleIdentifier: String,
        appURL: URL
    ) async throws -> VRChatMemoryPolicySnapshot {
        guard VRChatMemoryPolicyManifest.matches(
            bundleIdentifier: bundleIdentifier
        ) else {
            throw VRChatMemoryPolicyClientError
                .wrongBundleIdentifier(bundleIdentifier)
        }
        guard state.permitsNewSession else {
            throw VRChatMemoryPolicyClientError.sessionBusy
        }

        monitorTask?.cancel()
        monitorTask = nil
        if let previousSession = session {
            session = nil
            await previousSession.close()
        }
        preparedBundleIdentity = nil

        state = .preflighting
        do {
            preparedBundleIdentity = try bundleIdentityValidator.validate(
                appURL: appURL,
                bundleIdentifier: bundleIdentifier
            )
        } catch {
            state = .failed(code: Self.stableCode(for: error))
            throw error
        }
        let snapshot: VRChatMemoryPolicySnapshot
        do {
            snapshot = try configurationProvider.snapshot()
        } catch {
            preparedBundleIdentity = nil
            state = .failed(code: Self.stableCode(for: error))
            throw error
        }

        state = .authorizing(snapshot: snapshot)
        do {
            try await authorizationProvider.startController(
                selectedLimitGiB: snapshot.selectedLimitGiB
            )
        } catch {
            preparedBundleIdentity = nil
            state = .failed(code: Self.stableCode(for: error))
            throw error
        }

        state = .connecting(snapshot: snapshot)
        do {
            let openedSession = try await sessionProvider.openSession(
                socketPath: VRChatMemoryPolicyManifest.socketPath,
                timeout: VRChatMemoryPolicyManifest.handshakeTimeout,
                expectedSnapshot: snapshot
            )
            guard openedSession.selectedLimitMiB == snapshot.selectedLimitMiB,
                  openedSession.safeMaximumMiB == snapshot.safeMaximumMiB else {
                await openedSession.close()
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "WAITING limits differ from the immutable launch snapshot"
                )
            }
            session = openedSession
            state = .waiting(buildID: openedSession.buildID, snapshot: snapshot)
            return snapshot
        } catch {
            preparedBundleIdentity = nil
            state = .failed(code: Self.stableCode(for: error))
            throw error
        }
    }

    func launchWillBegin() async throws {
        guard case let .waiting(buildID, snapshot) = state,
              let preparedSession = session,
              let preparedIdentity = preparedBundleIdentity else {
            throw VRChatMemoryPolicyClientError.invalidTransition(
                "launch requires an authenticated PCVR/2 WAITING session"
            )
        }
        do {
            let currentIdentity = try bundleIdentityValidator.validate(
                appURL: preparedIdentity.appURL,
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier
            )
            guard currentIdentity == preparedIdentity else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "bundle_changed_after_authorization"
                )
            }
        } catch {
            do {
                try await preparedSession.cancelBeforeTargetBound()
            } catch {
                // The original identity failure remains authoritative. Closing
                // the WAITING session is still fail-closed for the controller.
            }
            session = nil
            preparedBundleIdentity = nil
            state = .failed(code: Self.stableCode(for: error))
            await preparedSession.close()
            throw error
        }
        state = .launching(buildID: buildID, snapshot: snapshot)
    }

    func bindLaunchServicesProcess(
        pid: pid_t,
        bundleURL: URL?,
        executableURL: URL?
    ) async throws {
        guard case let .launching(_, snapshot) = state,
              let monitoredSession = session,
              let preparedIdentity = preparedBundleIdentity else {
            throw VRChatMemoryPolicyClientError.invalidTransition(
                "LaunchServices success requires launching state"
            )
        }
        guard monitorTask == nil else {
            throw VRChatMemoryPolicyClientError.invalidTransition(
                "controller session is already being monitored"
            )
        }

        var targetWasBound = false
        do {
            guard pid > 0 else {
                throw VRChatCompatibleBundleIdentityError
                    .launchedProcessMismatch(reason: "returned_url_or_pid")
            }
            let canonicalPath: (URL) -> String = { value in
                value.standardizedFileURL.resolvingSymlinksInPath().path
            }
            if let returnedBundleURL = bundleURL,
               canonicalPath(returnedBundleURL) !=
                    canonicalPath(preparedIdentity.appURL) {
                throw VRChatCompatibleBundleIdentityError
                    .launchedProcessMismatch(reason: "returned_bundle_url")
            }
            if let returnedExecutableURL = executableURL,
               canonicalPath(returnedExecutableURL) !=
                    canonicalPath(preparedIdentity.executableURL) {
                throw VRChatCompatibleBundleIdentityError
                    .launchedProcessMismatch(reason: "returned_executable_url")
            }
            let currentIdentity = try bundleIdentityValidator.validate(
                appURL: preparedIdentity.appURL,
                bundleIdentifier: VRChatMemoryPolicyManifest.bundleIdentifier
            )
            guard currentIdentity == preparedIdentity else {
                throw VRChatCompatibleBundleIdentityError.identityMismatch(
                    reason: "bundle_changed_during_launch"
                )
            }
            let firstEvent = try await monitoredSession.nextEvent()
            guard case let .targetBound(boundPID) = firstEvent else {
                if case let .failed(code) = firstEvent {
                    throw VRChatMemoryPolicyClientError.protocolViolation(
                        "controller failed before TARGET_BOUND: \(code)"
                    )
                }
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "first post-launch event was not TARGET_BOUND"
                )
            }
            targetWasBound = true
            guard boundPID == pid else {
                throw VRChatCompatibleBundleIdentityError.targetPIDMismatch(
                    expected: pid,
                    found: boundPID
                )
            }
            state = .targetBound(pid: pid, snapshot: snapshot)
        } catch {
            if !targetWasBound {
                do {
                    try await monitoredSession.cancelBeforeTargetBound()
                } catch {
                    // Closing the session is the remaining fail-closed action.
                }
            }
            session = nil
            preparedBundleIdentity = nil
            state = .failed(code: Self.stableCode(for: error))
            await monitoredSession.close()
            throw error
        }

        monitorTask = Task { [weak self] in
            await self?.monitor(monitoredSession)
        }
    }

    func launchServicesFailedBeforeBinding() async throws {
        guard case .launching = state,
              let preparedSession = session else {
            throw VRChatMemoryPolicyClientError.invalidTransition(
                "pre-bind cancellation requires launching state"
            )
        }

        do {
            try await preparedSession.cancelBeforeTargetBound()
            state = .cancelRequested
        } catch {
            state = .failed(code: Self.stableCode(for: error))
            session = nil
            preparedBundleIdentity = nil
            await preparedSession.close()
            throw error
        }

        session = nil
        preparedBundleIdentity = nil
        await preparedSession.close()
    }

    private func monitor(_ monitoredSession: VRChatMemoryPolicySession) async {
        do {
            while !Task.isCancelled {
                let event = try await monitoredSession.nextEvent()
                if try apply(event) {
                    break
                }
            }
        } catch {
            if !Task.isCancelled {
                state = .failed(code: Self.stableCode(for: error))
            }
        }

        if session === monitoredSession {
            session = nil
        }
        preparedBundleIdentity = nil
        monitorTask = nil
        await monitoredSession.close()
    }

    /// Returns true after a terminal controller event.
    private func apply(_ event: VRChatMemoryPolicyServerEvent) throws -> Bool {
        switch event {
        case let .targetBound(pid):
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "duplicate or late TARGET_BOUND for PID \(pid)"
            )

        case let .leaseActive(pid, selectedLimitMiB):
            guard case let .targetBound(boundPID, snapshot) = state,
                  boundPID == pid,
                  selectedLimitMiB == snapshot.selectedLimitMiB else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "LEASE_ACTIVE did not match TARGET_BOUND and snapshot"
                )
            }
            state = .maintaining(
                pid: pid,
                snapshot: snapshot,
                metrics: nil
            )
            return false

        case let .metrics(metrics):
            guard case let .maintaining(pid, snapshot, _) = state,
                  pid == metrics.pid,
                  metrics.selectedLimitMiB == snapshot.selectedLimitMiB else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "METRICS did not match active PID and snapshot"
                )
            }
            state = .maintaining(
                pid: pid,
                snapshot: snapshot,
                metrics: metrics
            )
            return false

        case .completed:
            guard case .maintaining = state else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "COMPLETED arrived before LEASE_ACTIVE"
                )
            }
            state = .completed
            return true

        case let .failed(code):
            switch state {
            case .launching, .targetBound, .maintaining:
                state = .failed(code: code)
                return true
            default:
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "FAILED arrived outside an active launch"
                )
            }
        }
    }

    private static func stableCode(for error: Error) -> String {
        if let error = error as? VRChatMemoryPolicyClientError {
            return error.stableCode
        }
        if let error = error as? VRChatMemoryPolicyConfigurationError {
            return error.stableCode
        }
        if let error = error as? VRChatMemoryPolicyAuthorizationError {
            return error.stableCode
        }
        if let error = error as? VRChatCompatibleBundleIdentityError {
            return error.stableCode
        }
        return "session_provider_error"
    }
}

final class UnixSocketVRChatMemoryPolicySessionProvider:
    VRChatMemoryPolicySessionProvider {

    func openSession(
        socketPath: String,
        timeout: TimeInterval,
        expectedSnapshot: VRChatMemoryPolicySnapshot
    ) async throws -> VRChatMemoryPolicySession {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.connectAndHandshake(
                        socketPath: socketPath,
                        timeout: timeout,
                        expectedSnapshot: expectedSnapshot
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func connectAndHandshake(
        socketPath: String,
        timeout: TimeInterval,
        expectedSnapshot: VRChatMemoryPolicySnapshot
    ) throws -> VRChatMemoryPolicySession {
        let deadline = SocketDeadline(timeout: timeout)
        var descriptor: Int32 = -1
        var lastConnectError: Int32 = ECONNREFUSED

        while !deadline.isExpired {
            descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw VRChatMemoryPolicyClientError.connectionFailed(errno)
            }

            do {
                try configure(descriptor: descriptor)
                if try connect(descriptor: descriptor, socketPath: socketPath) {
                    break
                }
                lastConnectError = errno
                Darwin.close(descriptor)
                descriptor = -1

                guard lastConnectError == ENOENT
                        || lastConnectError == ECONNREFUSED else {
                    throw VRChatMemoryPolicyClientError
                        .connectionFailed(lastConnectError)
                }
                usleep(50_000)
            } catch {
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
                throw error
            }
        }

        guard descriptor >= 0 else {
            if deadline.isExpired {
                throw VRChatMemoryPolicyClientError.connectionTimedOut
            }
            throw VRChatMemoryPolicyClientError
                .connectionFailed(lastConnectError)
        }

        do {
            try verifyRootPeer(descriptor: descriptor)
            var buffer = Data()
            let helloLine = try SocketLineIO.readLine(
                descriptor: descriptor,
                buffer: &buffer,
                deadline: deadline
            )
            let buildID = try PCVRLineProtocol.parseHello(helloLine)
            guard VRChatMemoryPolicyManifest.matches(
                controllerBuildID: buildID
            ) else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "controller_build"
                )
            }

            let waitingLine = try SocketLineIO.readLine(
                descriptor: descriptor,
                buffer: &buffer,
                deadline: deadline
            )
            let waiting = try PCVRLineProtocol.parseWaiting(waitingLine)
            guard waiting.selectedLimitMiB
                    == expectedSnapshot.selectedLimitMiB,
                  waiting.safeMaximumMiB
                    == expectedSnapshot.safeMaximumMiB else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "WAITING limits differ from requested snapshot"
                )
            }

            return UnixSocketVRChatMemoryPolicySession(
                descriptor: descriptor,
                buildID: buildID,
                selectedLimitMiB: waiting.selectedLimitMiB,
                safeMaximumMiB: waiting.safeMaximumMiB,
                initialBuffer: buffer
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configure(descriptor: Int32) throws {
        if fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 {
            throw VRChatMemoryPolicyClientError.connectionFailed(errno)
        }

        var noSignal = Int32(1)
        if setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            throw VRChatMemoryPolicyClientError.connectionFailed(errno)
        }
    }

    private static func connect(
        descriptor: Int32,
        socketPath: String
    ) throws -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8) + [0]
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw VRChatMemoryPolicyClientError.socketPathTooLong
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            rawBuffer.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        return result == 0
    }

    private static func verifyRootPeer(descriptor: Int32) throws {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(
            descriptor,
            &effectiveUID,
            &effectiveGID
        ) == 0 else {
            throw VRChatMemoryPolicyClientError.peerCredentialUnavailable
        }
        guard effectiveUID == 0 else {
            throw VRChatMemoryPolicyClientError.peerIsNotRoot(effectiveUID)
        }
    }
}

private final class UnixSocketVRChatMemoryPolicySession:
    VRChatMemoryPolicySession, @unchecked Sendable {

    let buildID: String
    let selectedLimitMiB: UInt64
    let safeMaximumMiB: UInt64

    private let queue = DispatchQueue(
        label: "io.github.northstarxyzz.pcvrpatcher.playcover-session"
    )
    private var descriptor: Int32
    private var buffer: Data
    private var targetBound = false
    private var cancelSent = false

    init(
        descriptor: Int32,
        buildID: String,
        selectedLimitMiB: UInt64,
        safeMaximumMiB: UInt64,
        initialBuffer: Data
    ) {
        self.descriptor = descriptor
        self.buildID = buildID
        self.selectedLimitMiB = selectedLimitMiB
        self.safeMaximumMiB = safeMaximumMiB
        buffer = initialBuffer
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func nextEvent() async throws -> VRChatMemoryPolicyServerEvent {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.descriptor >= 0 else {
                        throw VRChatMemoryPolicyClientError.connectionClosed
                    }
                    let line = try SocketLineIO.readLine(
                        descriptor: self.descriptor,
                        buffer: &self.buffer,
                        deadline: nil
                    )
                    let event = try PCVRLineProtocol.parseEvent(line)
                    if case .targetBound = event {
                        self.targetBound = true
                    }
                    continuation.resume(returning: event)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancelBeforeTargetBound() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.descriptor >= 0 else {
                        throw VRChatMemoryPolicyClientError.connectionClosed
                    }
                    guard !self.targetBound else {
                        throw VRChatMemoryPolicyClientError.cancelAfterTargetBound
                    }
                    guard !self.cancelSent else {
                        throw VRChatMemoryPolicyClientError.invalidTransition(
                            "CANCEL was already sent"
                        )
                    }
                    try SocketLineIO.writeLine(
                        descriptor: self.descriptor,
                        line: "PCVR/2 CANCEL"
                    )
                    self.cancelSent = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.descriptor >= 0 {
                    Darwin.close(self.descriptor)
                    self.descriptor = -1
                }
                continuation.resume()
            }
        }
    }
}

private struct SocketDeadline {
    private let deadlineNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ timeoutNanoseconds
    }

    var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
    }

    var remainingPollMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else { return 0 }
        let remainingNanoseconds = deadlineNanoseconds - now
        let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
        return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
    }
}

private enum SocketLineIO {
    static let maximumLineBytes = 4_096

    static func readLine(
        descriptor: Int32,
        buffer: inout Data,
        deadline: SocketDeadline?
    ) throws -> String {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                guard lineData.count <= maximumLineBytes else {
                    throw VRChatMemoryPolicyClientError.lineTooLong
                }
                guard !lineData.contains(0), !lineData.contains(0x0d) else {
                    throw VRChatMemoryPolicyClientError.protocolViolation(
                        "line contains a forbidden byte"
                    )
                }
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw VRChatMemoryPolicyClientError.invalidUTF8
                }
                return line
            }

            guard buffer.count <= maximumLineBytes else {
                throw VRChatMemoryPolicyClientError.lineTooLong
            }

            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL),
                revents: 0
            )
            let timeout = deadline?.remainingPollMilliseconds ?? -1
            if deadline?.isExpired == true {
                throw VRChatMemoryPolicyClientError.handshakeTimedOut
            }

            let pollResult = Darwin.poll(&pollDescriptor, 1, timeout)
            if pollResult == 0 {
                throw VRChatMemoryPolicyClientError.handshakeTimedOut
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw VRChatMemoryPolicyClientError.connectionFailed(errno)
            }
            if pollDescriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw VRChatMemoryPolicyClientError.connectionClosed
            }

            let readCapacity = min(
                1_024,
                maximumLineBytes + 1 - buffer.count
            )
            var bytes = [UInt8](repeating: 0, count: readCapacity)
            let amount = Darwin.read(descriptor, &bytes, bytes.count)
            if amount == 0 {
                throw VRChatMemoryPolicyClientError.connectionClosed
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw VRChatMemoryPolicyClientError.connectionFailed(errno)
            }
            buffer.append(contentsOf: bytes.prefix(Int(amount)))
        }
    }

    static func writeLine(descriptor: Int32, line: String) throws {
        guard !line.contains("\n"),
              !line.contains("\r"),
              !line.contains("\0") else {
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "outbound line contains a forbidden byte"
            )
        }
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let amount = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    0
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw VRChatMemoryPolicyClientError.writeFailed(errno)
                }
                if amount == 0 {
                    throw VRChatMemoryPolicyClientError.connectionClosed
                }
                offset += amount
            }
        }
    }
}

enum PCVRLineProtocol {
    struct Waiting: Equatable {
        let selectedLimitMiB: UInt64
        let safeMaximumMiB: UInt64
    }

    static func parseHello(_ line: String) throws -> String {
        let values = fields(in: line)
        guard values.count == 3,
              values[0] == VRChatMemoryPolicyManifest.protocolVersion,
              values[1] == "HELLO",
              isStableToken(values[2]) else {
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "invalid HELLO line"
            )
        }
        return values[2]
    }

    static func parseWaiting(_ line: String) throws -> Waiting {
        let values = fields(in: line)
        guard values.count == 4,
              values[0] == VRChatMemoryPolicyManifest.protocolVersion,
              values[1] == "WAITING",
              let selectedLimitMiB = canonicalUInt64(values[2]),
              let safeMaximumMiB = canonicalUInt64(values[3]),
              selectedLimitMiB > 0,
              selectedLimitMiB <= safeMaximumMiB else {
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "invalid WAITING line"
            )
        }
        return Waiting(
            selectedLimitMiB: selectedLimitMiB,
            safeMaximumMiB: safeMaximumMiB
        )
    }

    static func parseEvent(
        _ line: String
    ) throws -> VRChatMemoryPolicyServerEvent {
        let values = fields(in: line)
        guard values.count >= 2,
              values[0] == VRChatMemoryPolicyManifest.protocolVersion else {
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "invalid protocol prefix"
            )
        }

        switch values[1] {
        case "TARGET_BOUND":
            guard values.count == 3,
                  let pid = positivePID(values[2]) else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "invalid TARGET_BOUND line"
                )
            }
            return .targetBound(pid: pid)

        case "LEASE_ACTIVE":
            guard values.count == 4,
                  let pid = positivePID(values[2]),
                  let selectedLimitMiB = canonicalUInt64(values[3]),
                  selectedLimitMiB > 0 else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "invalid LEASE_ACTIVE line"
                )
            }
            return .leaseActive(
                pid: pid,
                selectedLimitMiB: selectedLimitMiB
            )

        case "METRICS":
            guard values.count == 8,
                  let pid = positivePID(values[2]),
                  let selectedLimitMiB = canonicalUInt64(values[3]),
                  selectedLimitMiB > 0,
                  let footprintMiB = oneDecimalNonnegativeDouble(values[4]),
                  let headroomMiB = oneDecimalNonnegativeDouble(values[5]),
                  let reapplies = canonicalUInt64(values[6]),
                  isStableToken(values[7]) else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "invalid METRICS line"
                )
            }
            return .metrics(VRChatMemoryPolicyMetrics(
                pid: pid,
                selectedLimitMiB: selectedLimitMiB,
                footprintMiB: footprintMiB,
                headroomMiB: headroomMiB,
                reapplies: reapplies,
                pressure: values[7]
            ))

        case "COMPLETED":
            guard values.count == 2 else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "invalid COMPLETED line"
                )
            }
            return .completed

        case "FAILED":
            guard values.count == 3,
                  isStableToken(values[2]) else {
                throw VRChatMemoryPolicyClientError.protocolViolation(
                    "invalid FAILED line"
                )
            }
            return .failed(code: values[2])

        default:
            throw VRChatMemoryPolicyClientError.protocolViolation(
                "unknown server event"
            )
        }
    }

    private static func fields(in line: String) -> [String] {
        line.split(
            separator: " ",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    private static func positivePID(_ value: String) -> pid_t? {
        guard let parsed = canonicalUInt64(value),
              parsed > 0,
              parsed <= UInt64(Int32.max) else {
            return nil
        }
        return pid_t(parsed)
    }

    private static func canonicalUInt64(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              value == "0" || value.first != "0" else {
            return nil
        }
        return UInt64(value)
    }

    private static func oneDecimalNonnegativeDouble(
        _ value: String
    ) -> Double? {
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              canonicalUInt64(String(parts[0])) != nil,
              parts[1].utf8.count == 1,
              parts[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let parsed = Double(value),
              parsed.isFinite,
              parsed >= 0 else {
            return nil
        }
        return parsed
    }

    private static func isStableToken(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x5f
        }
    }
}

struct VRChatMemoryPolicySettingsView: View {
    @AppStorage(VRChatMemoryPolicySettingsKeys.mode)
    private var storedMode = VRChatMemoryPolicySettingsKeys.automaticValue

    @AppStorage(VRChatMemoryPolicySettingsKeys.customGiB)
    private var customGiB = Int(
        VRChatMemoryPolicyManifest.lowMemoryWarningBelowGiB
    )

    private var safeMaximumGiB: UInt16? {
        try? VRChatMemoryPolicySnapshot.safeMaximumGiB(
            physicalMemoryBytes:
                HostPhysicalMemoryProvider().physicalMemoryBytes()
        )
    }

    private var selectedGiB: Int? {
        guard let safeMaximumGiB else { return nil }
        if storedMode == VRChatMemoryPolicySettingsKeys.automaticValue {
            return Int(safeMaximumGiB)
        }
        guard storedMode == VRChatMemoryPolicySettingsKeys.customValue else {
            return nil
        }
        return customGiB
    }

    private var selectionIsValid: Bool {
        guard let safeMaximumGiB,
              let selectedGiB else {
            return false
        }
        return selectedGiB
            >= Int(VRChatMemoryPolicyManifest.minimumLimitGiB)
            && selectedGiB <= Int(safeMaximumGiB)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("vrchatMemoryPolicy.mode")
                        .font(.headline)
                    Picker("vrchatMemoryPolicy.mode", selection: $storedMode) {
                        Text("vrchatMemoryPolicy.mode.automatic")
                            .tag(VRChatMemoryPolicySettingsKeys.automaticValue)
                        Text("vrchatMemoryPolicy.mode.custom")
                            .tag(VRChatMemoryPolicySettingsKeys.customValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                }

                if let safeMaximumGiB {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("vrchatMemoryPolicy.safeMaximum")
                            .foregroundColor(.secondary)
                        Spacer(minLength: 12)
                        Text("\(safeMaximumGiB) GiB")
                            .font(.headline)
                            .monospacedDigit()
                    }

                    if storedMode == VRChatMemoryPolicySettingsKeys.customValue {
                        let allowedRange = Int(
                            VRChatMemoryPolicyManifest.minimumLimitGiB
                        )...Int(safeMaximumGiB)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("vrchatMemoryPolicy.customLimit")
                                .foregroundColor(.secondary)
                            Spacer(minLength: 12)
                            Stepper(value: $customGiB, in: allowedRange) {
                                Text("\(customGiB) GiB")
                                    .monospacedDigit()
                            }
                            .fixedSize()
                        }
                    }
                } else {
                    Label(
                        "vrchatMemoryPolicy.physicalMemoryUnavailable",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundColor(.red)
                }

                if !selectionIsValid {
                    Label(
                        "vrchatMemoryPolicy.invalidSelection",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundColor(.red)
                } else if let selectedGiB,
                          selectedGiB
                            < Int(VRChatMemoryPolicyManifest.lowMemoryWarningBelowGiB) {
                    Label(
                        "vrchatMemoryPolicy.lowMemoryWarning",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(.orange)
                }

                Text("vrchatMemoryPolicy.nextSession")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 280, alignment: .topLeading)
    }
}
