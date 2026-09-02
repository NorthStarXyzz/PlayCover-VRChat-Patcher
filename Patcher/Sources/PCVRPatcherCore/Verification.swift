import AppKit
import CryptoKit
import Darwin
import Foundation

public protocol RuntimeProviding: Sendable {
    func snapshot() throws -> RuntimeSnapshot
}

public protocol ProcessInspecting: Sendable {
    func runningProtectedApplications() -> [String]
}

public protocol TreeVerifying: Sendable {
    func identity(of appURL: URL) throws -> AppIdentity
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

private enum MachOInspector {
    private static let magic64: UInt32 = 0xfeedfacf
    private static let swappedMagic64: UInt32 = 0xcffaedfe
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let cpuTypeARM64: UInt32 = 0x0100000c
    private static let loadCommandUUID: UInt32 = 0x1b

    /// PlayCover identity includes the executable UUID.  This parser is kept
    /// deliberately small: it only extracts a UUID from the executable used
    /// for PlayCover's own identity and never examines VRChat binaries.
    static func uuid(from url: URL) throws -> UUID {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try parseThin(selectArm64Slice(from: data))
    }

    private static func parseThin(_ data: Data) throws -> UUID {
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
        var found: UUID?
        var count = 0
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
                found = UUID(uuid: tuple)
                count += 1
            }
            offset += size
        }
        guard offset == 32 + commandsSize, count == 1, let found else {
            throw PatcherError.unknownModification(
                "Mach-O UUID is missing or load-command size is inconsistent"
            )
        }
        return found
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

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
