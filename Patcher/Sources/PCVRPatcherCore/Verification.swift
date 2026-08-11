import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

public protocol RuntimeProviding: Sendable {
    func snapshot() throws -> RuntimeSnapshot
}

public protocol ProcessInspecting: Sendable {
    func runningProtectedApplications() -> [String]
}

public protocol TreeVerifying: Sendable {
    func identity(of appURL: URL) throws -> AppIdentity
}

public protocol VRChatVerifying: Sendable {
    func identity(
        of appURL: URL,
        expected: VRChatIdentity
    ) throws -> ObservedVRChatIdentity
}

public enum VRChatArtifactScanner {
    private static let forbiddenFragments = [
        "playchain",
        "memoryshim",
        "diagnosticempty",
        "playcovercompatempty",
        "playcovermemoryshim",
        "vrchatmemorypatch"
    ]

    public static func verifyClean(_ appURL: URL) throws {
        for entry in try PhysicalTree.entries(below: appURL) {
            let relative = entry.relativePath
            let lowered = relative.lowercased()
            let components = lowered.split(separator: "/").map(String.init)
            let forbiddenPlayTools = components.contains {
                $0 == "playtools" ||
                    $0 == "playtools.framework" ||
                    $0 == "playtools.dylib"
            }
            if forbiddenPlayTools {
                throw PatcherError.unknownModification(
                    "VRChat contains excluded PlayTools code at \(relative)"
                )
            }
            if let fragment = forbiddenFragments.first(where: lowered.contains) {
                throw PatcherError.unknownModification(
                    "VRChat contains excluded \(fragment) artifact at \(relative)"
                )
            }
        }
    }
}

public struct SystemRuntimeProvider: RuntimeProviding {
    public init() {}

    public func snapshot() throws -> RuntimeSnapshot {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        var uts = utsname()
        uname(&uts)
        let architecture = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        let xnu = withUnsafePointer(to: &uts.version) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return RuntimeSnapshot(
            macOSVersion: "\(version.majorVersion).\(version.minorVersion)" +
                (version.patchVersion == 0 ? "" : ".\(version.patchVersion)"),
            macOSBuild: Self.sysctlString("kern.osversion"),
            xnuVersion: xnu,
            architecture: architecture,
            physicalMemoryBytes: info.physicalMemory
        )
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

public struct WorkspaceProcessInspector: ProcessInspecting {
    public init() {}

    public func runningProtectedApplications() -> [String] {
        let protected: [String: String] = [
            "io.playcover.PlayCover": "PlayCover",
            "io.github.northstarxyzz.PlayCoverVRChat": "PlayCover VRChat",
            "com.vrchat.mobile": "VRChat"
        ]
        return Array(Set(NSWorkspace.shared.runningApplications.compactMap {
            application in
            guard let identifier = application.bundleIdentifier else { return nil }
            if let name = protected[identifier] { return name }
            if identifier.hasPrefix("com.vrchat.") { return "VRChat" }
            return nil
        })).sorted()
    }
}

public struct AppTreeVerifier: TreeVerifying {
    public init() {}

    public func identity(of appURL: URL) throws -> AppIdentity {
        _ = try SecureTreeAuditor.inspect(appURL)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              let buildVersion = plist["CFBundleVersion"] as? String,
              let executableName = plist["CFBundleExecutable"] as? String else {
            throw PatcherError.unknownModification("invalid or incomplete Info.plist")
        }
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        let codeResourcesURL = appURL.appendingPathComponent(
            "Contents/_CodeSignature/CodeResources"
        )
        return AppIdentity(
            bundleIdentifier: bundleID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: executableName,
            executableSHA256: try Self.fileSHA256(executableURL),
            executableUUID: try MachOInspector.uuid(from: executableURL).uuidString,
            treeSHA256: try Self.treeSHA256(appURL),
            infoPlistSHA256: try Self.fileSHA256(plistURL),
            codeResourcesSHA256: FileManager.default.fileExists(
                atPath: codeResourcesURL.path
            ) ? try Self.fileSHA256(codeResourcesURL) : nil
        )
    }

    public static func fileSHA256(_ url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadUnknown)
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if count == 0 { break }
            hasher.update(data: Data(bytes[0..<count]))
        }
        return hasher.finalize().hexString
    }

    public static func treeSHA256(_ root: URL) throws -> String {
        let fileManager = FileManager.default
        let entries = try PhysicalTree.entries(below: root).sorted {
            $0.relativePath.compare(
                $1.relativePath,
                options: .literal
            ) == .orderedAscending
        }
        var hasher = SHA256()
        func feed(_ string: String) {
            hasher.update(data: Data(string.utf8))
        }
        for entry in entries {
            let relative = entry.relativePath
            let url = entry.url
            let type = entry.status.st_mode & S_IFMT
            if type == S_IFLNK {
                feed(
                    "L\0\(relative)\0" +
                    "\(try fileManager.destinationOfSymbolicLink(atPath: url.path))\0"
                )
            } else if type == S_IFDIR {
                feed("D\0\(relative)\0")
            } else if type == S_IFREG {
                feed("F\0\(relative)\0\(try fileSHA256(url))\0")
            } else {
                throw PatcherError.unknownModification(
                    "unsupported file type at \(relative)"
                )
            }
        }
        return hasher.finalize().hexString
    }
}

public struct VRChatAppVerifier: VRChatVerifying {
    private let homeDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func identity(
        of appURL: URL,
        expected: VRChatIdentity
    ) throws -> ObservedVRChatIdentity {
        _ = try SecureTreeAuditor.inspect(appURL)
        let plistURL = appURL.appendingPathComponent("Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(
                from: plistData,
                format: nil
              ) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              let buildVersion = plist["CFBundleVersion"] as? String,
              let executableName = plist["CFBundleExecutable"] as? String else {
            throw PatcherError.unknownModification(
                "invalid or incomplete VRChat Info.plist"
            )
        }
        let executableURL = appURL.appendingPathComponent(executableName)
        let normalized = try MachOInspector.normalizedDigests(from: executableURL)
        let entitlementsSHA256 = try EntitlementsCanonicalizer.sha256(
            of: executableURL,
            homeDirectory: homeDirectory
        )
        let main = PortableMachOIdentity(
            uuid: normalized.uuid.uuidString,
            normalizedUnsignedSHA256: normalized.normalizedUnsignedSHA256,
            loadCommandsSHA256: normalized.loadCommandsSHA256,
            entitlementsSHA256: entitlementsSHA256,
            reviewedInstalledSHA256: try AppTreeVerifier.fileSHA256(executableURL)
        )
        let machoAllowlist = try MachOAllowlistVerifier.identity(of: appURL)
        return ObservedVRChatIdentity(
            bundleIdentifier: bundleID,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: executableName,
            mainIdentity: main,
            unityFramework: try binaryIdentity(
                at: appURL,
                relativePath: expected.unityFramework.relativePath
            ),
            appdomeLibloader: try binaryIdentity(
                at: appURL,
                relativePath: expected.appdomeLibloader.relativePath
            ),
            machoAllowlist: machoAllowlist,
            treeSHA256: try AppTreeVerifier.treeSHA256(appURL)
        )
    }

    private func binaryIdentity(
        at appURL: URL,
        relativePath: String
    ) throws -> ReviewedBinaryIdentity {
        let url = appURL.appendingPathComponent(relativePath)
        return ReviewedBinaryIdentity(
            relativePath: relativePath,
            sha256: try AppTreeVerifier.fileSHA256(url),
            uuid: try MachOInspector.uuid(from: url).uuidString
        )
    }
}

public enum MachOAllowlistVerifier {
    private static let magic64: UInt32 = 0xfeedfacf
    private static let recognizedMachOMagics: Set<UInt32> = [
        0xfeedface,
        0xcefaedfe,
        0xfeedfacf,
        0xcffaedfe,
        0xcafebabe,
        0xbebafeca,
        0xcafebabf,
        0xbfbafeca
    ]

    public static func identity(
        of appURL: URL
    ) throws -> MachOAllowlistIdentity {
        var entries: [(path: String, identity: PortableMachONormalizer.Digests)] = []
        for entry in try PhysicalTree.entries(below: appURL) {
            guard (entry.status.st_mode & S_IFMT) == S_IFREG else { continue }
            let relative = entry.relativePath
            let url = entry.url
            let handle = try FileHandle(forReadingFrom: url)
            let prefix: Data
            do {
                prefix = try handle.read(upToCount: 4) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard prefix.count == 4 else { continue }
            let magic = prefix.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            if magic == magic64 {
                entries.append((
                    path: relative,
                    identity: try MachOInspector.normalizedDigests(from: url)
                ))
            } else if recognizedMachOMagics.contains(magic) {
                throw PatcherError.unknownModification(
                    "VRChat contains an unsupported non-thin-arm64 Mach-O at \(relative)"
                )
            }
        }
        entries.sort {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        guard !entries.isEmpty, entries.count <= Int(UInt16.max) else {
            throw PatcherError.unknownModification(
                "VRChat Mach-O allowlist is empty or excessive"
            )
        }
        var canonical = Data("PCVR-MACHO-ALLOWLIST/1\n".utf8)
        for entry in entries {
            let uuid = entry.identity.uuid.uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            canonical.append(contentsOf: (
                "M \(entry.path.utf8.count) \(entry.path) \(uuid) " +
                "\(entry.identity.normalizedUnsignedSHA256) " +
                "\(entry.identity.loadCommandsSHA256)\n"
            ).utf8)
        }
        return MachOAllowlistIdentity(
            format: "PCVR-MACHO-ALLOWLIST/1",
            digestSHA256: SHA256.hash(data: canonical).hexString,
            count: UInt16(entries.count)
        )
    }
}

public enum EntitlementsCanonicalizer {
    public static func sha256(
        of executableURL: URL,
        homeDirectory: URL
    ) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw PatcherError.unknownModification(
                "cannot read VRChat code signature (OSStatus \(createStatus))"
            )
        }
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            throw PatcherError.unknownModification(
                "cannot read VRChat signing information (OSStatus \(infoStatus))"
            )
        }
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSStrictValidate |
                    kSecCSCheckAllArchitectures |
                    kSecCSDoNotValidateResources
            ),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw PatcherError.unknownModification(
                "VRChat main signature is invalid (OSStatus \(validityStatus))"
            )
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String]
            as? [String: Any] ?? [:]
        return try canonicalSHA256(
            of: entitlements,
            homeDirectory: homeDirectory
        )
    }

    public static func canonicalSHA256(
        of entitlements: [String: Any],
        homeDirectory: URL
    ) throws -> String {
        let home = homeDirectory.standardizedFileURL.path
        var data = Data("PCVR-ENTITLEMENTS/1\n".utf8)
        let keys = entitlements.keys.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        var arrayCount = 0
        for key in keys {
            guard let value = entitlements[key] else { continue }
            let keyBytes = Data(key.utf8)
            if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                let boolean = value as! CFBoolean
                guard CFBooleanGetValue(boolean) else {
                    throw PatcherError.unknownModification(
                        "false entitlement values are outside PCVR-ENTITLEMENTS/1"
                    )
                }
                appendASCII("B \(keyBytes.count) ", to: &data)
                data.append(keyBytes)
                data.append(0x0a)
                continue
            }
            guard let values = value as? [String] else {
                throw PatcherError.unknownModification(
                    "unsupported entitlement value for \(key)"
                )
            }
            arrayCount += 1
            guard arrayCount == 1 else {
                throw PatcherError.unknownModification(
                    "PCVR-ENTITLEMENTS/1 permits one ordered string array"
                )
            }
            appendASCII("A \(keyBytes.count) ", to: &data)
            data.append(keyBytes)
            appendASCII(" \(values.count)\n", to: &data)
            for value in values {
                let normalized = normalizeHome(in: value, home: home)
                let bytes = Data(normalized.utf8)
                appendASCII("S \(bytes.count) ", to: &data)
                data.append(bytes)
                data.append(0x0a)
            }
        }
        guard arrayCount == 1 else {
            throw PatcherError.unknownModification(
                "PCVR-ENTITLEMENTS/1 requires one ordered string array"
            )
        }
        return SHA256.hash(data: data).hexString
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func normalizeHome(in string: String, home: String) -> String {
        guard !home.isEmpty else { return string }
        return string.replacingOccurrences(
            of: home,
            with: "@CONSOLE_HOME@"
        )
    }
}

public enum PortableMachONormalizer {
    public struct Digests: Sendable, Equatable {
        public let uuid: UUID
        public let normalizedUnsignedSHA256: String
        public let loadCommandsSHA256: String
    }

    public static func digests(of executableURL: URL) throws -> Digests {
        try MachOInspector.normalizedDigests(from: executableURL)
    }
}

private enum MachOInspector {
    private static let magic64: UInt32 = 0xfeedfacf
    private static let swappedMagic64: UInt32 = 0xcffaedfe
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let cpuTypeARM64: UInt32 = 0x0100000c
    private static let loadCommandUUID: UInt32 = 0x1b
    private static let loadCommandCodeSignature: UInt32 = 0x1d
    private static let loadCommandSegment64: UInt32 = 0x19

    static func uuid(from url: URL) throws -> UUID {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try parseThin(selectArm64Slice(from: data)).uuid
    }

    static func normalizedDigests(
        from url: URL
    ) throws -> PortableMachONormalizer.Digests {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let bigEndianMagic = data.count >= 4 ? readBigEndianUInt32(data, 0) : 0
        guard bigEndianMagic != fatMagic, bigEndianMagic != fatMagic64 else {
            throw PatcherError.unknownModification(
                "VRChat main must be a thin arm64 Mach-O, matching the controller"
            )
        }
        var thin = data
        let parsed = try parseThin(thin)
        guard let codeSignature = parsed.codeSignature else {
            throw PatcherError.unknownModification(
                "VRChat main executable has no LC_CODE_SIGNATURE"
            )
        }
        guard codeSignature.dataOffset >= parsed.commandsEnd,
              codeSignature.dataOffset <= thin.count,
              codeSignature.dataSize > 0,
              codeSignature.dataSize <= thin.count - codeSignature.dataOffset else {
            throw PatcherError.unknownModification(
                "VRChat code-signature range is invalid"
            )
        }

        zero(&thin, at: codeSignature.commandOffset + 8, count: 4)
        zero(&thin, at: codeSignature.commandOffset + 12, count: 4)
        if let linkedit = parsed.linkeditCommandOffset {
            // __LINKEDIT includes signing-dependent size values. The file offset
            // and LC_CODE_SIGNATURE data offset remain stable identity inputs.
            zero(&thin, at: linkedit + 32, count: 8) // vmsize
            zero(&thin, at: linkedit + 48, count: 8) // filesize
        }

        let commandBytes = thin.prefix(parsed.commandsEnd)
        var normalizedUnsigned = Data(commandBytes)
        normalizedUnsigned.append(
            thin[parsed.commandsEnd..<codeSignature.dataOffset]
        )
        let signatureEnd = codeSignature.dataOffset + codeSignature.dataSize
        normalizedUnsigned.append(thin[signatureEnd..<thin.count])
        return PortableMachONormalizer.Digests(
            uuid: parsed.uuid,
            normalizedUnsignedSHA256: SHA256.hash(
                data: normalizedUnsigned
            ).hexString,
            loadCommandsSHA256: SHA256.hash(data: commandBytes).hexString
        )
    }

    private struct ParsedThin {
        let uuid: UUID
        let commandsEnd: Int
        let linkeditCommandOffset: Int?
        let codeSignature: (
            commandOffset: Int,
            dataOffset: Int,
            dataSize: Int
        )?
    }

    private static func parseThin(_ data: Data) throws -> ParsedThin {
        guard data.count >= 32 else {
            throw PatcherError.unknownModification("truncated Mach-O")
        }
        let magic = readUInt32(data, 0, swap: false)
        let swap: Bool
        switch magic {
        case magic64: swap = false
        case swappedMagic64: swap = true
        default:
            throw PatcherError.unknownModification(
                "expected a thin 64-bit Mach-O executable"
            )
        }
        guard readUInt32(data, 4, swap: swap) == cpuTypeARM64 else {
            throw PatcherError.unknownModification(
                "expected an arm64 Mach-O executable"
            )
        }
        let commandCount = Int(readUInt32(data, 16, swap: swap))
        let commandsSize = Int(readUInt32(data, 20, swap: swap))
        guard commandCount > 0,
              commandCount <= 65_535,
              commandsSize >= 8,
              32 + commandsSize <= data.count else {
            throw PatcherError.unknownModification("invalid Mach-O load commands")
        }

        var offset = 32
        var uuid: UUID?
        var uuidCount = 0
        var linkedit: Int?
        var linkeditCount = 0
        var codeSignature: (Int, Int, Int)?
        var codeSignatureCount = 0
        for _ in 0..<commandCount {
            guard offset + 8 <= 32 + commandsSize else {
                throw PatcherError.unknownModification("truncated Mach-O load command")
            }
            let command = readUInt32(data, offset, swap: swap)
            let size = Int(readUInt32(data, offset + 4, swap: swap))
            guard size >= 8, offset + size <= 32 + commandsSize else {
                throw PatcherError.unknownModification("invalid Mach-O load command")
            }
            if command == loadCommandUUID, size >= 24 {
                let bytes = [UInt8](data[(offset + 8)..<(offset + 24)])
                let tuple: uuid_t = (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
                uuid = UUID(uuid: tuple)
                uuidCount += 1
            } else if command == loadCommandSegment64, size >= 72 {
                let nameBytes = data[(offset + 8)..<(offset + 24)]
                let name = String(
                    decoding: nameBytes.prefix { $0 != 0 },
                    as: UTF8.self
                )
                if name == "__LINKEDIT" {
                    linkedit = offset
                    linkeditCount += 1
                }
            } else if command == loadCommandCodeSignature, size >= 16 {
                codeSignature = (
                    offset,
                    Int(readUInt32(data, offset + 8, swap: swap)),
                    Int(readUInt32(data, offset + 12, swap: swap))
                )
                codeSignatureCount += 1
            }
            offset += size
        }
        guard offset == 32 + commandsSize,
              uuidCount == 1,
              codeSignatureCount == 1,
              linkeditCount == 1,
              let uuid else {
            throw PatcherError.unknownModification(
                "Mach-O UUID is missing or load-command size is inconsistent"
            )
        }
        return ParsedThin(
            uuid: uuid,
            commandsEnd: offset,
            linkeditCommandOffset: linkedit,
            codeSignature: codeSignature
        )
    }

    private static func selectArm64Slice(from data: Data) throws -> Data {
        guard data.count >= 8 else {
            throw PatcherError.unknownModification("truncated Mach-O")
        }
        let bigEndianMagic = readBigEndianUInt32(data, 0)
        guard bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 else {
            return data
        }
        let is64 = bigEndianMagic == fatMagic64
        let count = Int(readBigEndianUInt32(data, 4))
        let entrySize = is64 ? 32 : 20
        guard count > 0,
              count <= 64,
              8 + count * entrySize <= data.count else {
            throw PatcherError.unknownModification(
                "invalid universal Mach-O header"
            )
        }
        for index in 0..<count {
            let entry = 8 + index * entrySize
            guard readBigEndianUInt32(data, entry) == cpuTypeARM64 else { continue }
            let offset = is64
                ? Int(readBigEndianUInt64(data, entry + 8))
                : Int(readBigEndianUInt32(data, entry + 8))
            let size = is64
                ? Int(readBigEndianUInt64(data, entry + 16))
                : Int(readBigEndianUInt32(data, entry + 12))
            guard offset >= 0,
                  size >= 32,
                  offset <= data.count,
                  size <= data.count - offset else {
                throw PatcherError.unknownModification(
                    "invalid arm64 universal Mach-O slice"
                )
            }
            return data.subdata(in: offset..<(offset + size))
        }
        throw PatcherError.unknownModification(
            "universal Mach-O contains no arm64 slice"
        )
    }

    private static func zero(_ data: inout Data, at offset: Int, count: Int) {
        data.replaceSubrange(
            offset..<(offset + count),
            with: repeatElement(UInt8(0), count: count)
        )
    }

    private static func readUInt32(
        _ data: Data,
        _ offset: Int,
        swap: Bool
    ) -> UInt32 {
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return swap ? value.byteSwapped : value
    }

    private static func readBigEndianUInt32(
        _ data: Data,
        _ offset: Int
    ) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(
                fromByteOffset: offset,
                as: UInt32.self
            ))
        }
    }

    private static func readBigEndianUInt64(
        _ data: Data,
        _ offset: Int
    ) -> UInt64 {
        data.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(
                fromByteOffset: offset,
                as: UInt64.self
            ))
        }
    }
}

extension AppIdentity {
    func mismatch(from expected: AppIdentity) -> String? {
        if bundleIdentifier != expected.bundleIdentifier {
            return "bundle identifier \(bundleIdentifier)"
        }
        if shortVersion != expected.shortVersion { return "version \(shortVersion)" }
        if buildVersion != expected.buildVersion { return "build \(buildVersion)" }
        if executableName != expected.executableName {
            return "executable \(executableName)"
        }
        if executableSHA256.caseInsensitiveCompare(expected.executableSHA256) !=
            .orderedSame {
            return "executable SHA-256 \(executableSHA256)"
        }
        if executableUUID.caseInsensitiveCompare(expected.executableUUID) !=
            .orderedSame {
            return "Mach-O UUID \(executableUUID)"
        }
        if treeSHA256.caseInsensitiveCompare(expected.treeSHA256) != .orderedSame {
            return "tree SHA-256 \(treeSHA256)"
        }
        if let expectedInfo = expected.infoPlistSHA256,
           infoPlistSHA256?.caseInsensitiveCompare(expectedInfo) != .orderedSame {
            return "Info.plist SHA-256 \(infoPlistSHA256 ?? "missing")"
        }
        if let expectedResources = expected.codeResourcesSHA256,
           codeResourcesSHA256?.caseInsensitiveCompare(expectedResources) !=
            .orderedSame {
            return "CodeResources SHA-256 \(codeResourcesSHA256 ?? "missing")"
        }
        return nil
    }
}

extension ObservedVRChatIdentity {
    func mismatch(from expected: VRChatIdentity) -> String? {
        if bundleIdentifier != expected.bundleIdentifier {
            return "bundle identifier \(bundleIdentifier)"
        }
        if shortVersion != expected.shortVersion { return "version \(shortVersion)" }
        if buildVersion != expected.buildVersion { return "build \(buildVersion)" }
        if executableName != expected.executableName {
            return "executable \(executableName)"
        }
        let actualMain = mainIdentity
        let expectedMain = expected.mainIdentity
        if actualMain.uuid.caseInsensitiveCompare(expectedMain.uuid) != .orderedSame {
            return "main UUID \(actualMain.uuid)"
        }
        if actualMain.normalizedUnsignedSHA256.caseInsensitiveCompare(
            expectedMain.normalizedUnsignedSHA256
        ) != .orderedSame {
            return "normalized main SHA-256 \(actualMain.normalizedUnsignedSHA256)"
        }
        if actualMain.loadCommandsSHA256.caseInsensitiveCompare(
            expectedMain.loadCommandsSHA256
        ) != .orderedSame {
            return "load-command SHA-256 \(actualMain.loadCommandsSHA256)"
        }
        if actualMain.entitlementsSHA256.caseInsensitiveCompare(
            expectedMain.entitlementsSHA256
        ) != .orderedSame {
            return "entitlements SHA-256 \(actualMain.entitlementsSHA256)"
        }
        if let mismatch = unityFramework.mismatch(
            from: expected.unityFramework,
            label: "UnityFramework"
        ) { return mismatch }
        if let mismatch = appdomeLibloader.mismatch(
            from: expected.appdomeLibloader,
            label: "Appdome libloader"
        ) { return mismatch }
        if machoAllowlist != expected.machoAllowlist {
            return "Mach-O allowlist \(machoAllowlist.count)/\(machoAllowlist.digestSHA256)"
        }
        return nil
    }
}

private extension ReviewedBinaryIdentity {
    func mismatch(from expected: Self, label: String) -> String? {
        if relativePath != expected.relativePath {
            return "\(label) path \(relativePath)"
        }
        if sha256.caseInsensitiveCompare(expected.sha256) != .orderedSame {
            return "\(label) SHA-256 \(sha256)"
        }
        if uuid.caseInsensitiveCompare(expected.uuid) != .orderedSame {
            return "\(label) UUID \(uuid)"
        }
        return nil
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
