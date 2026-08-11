import CryptoKit
import Darwin
import Foundation

public struct VRChatConfigurationIdentity: Sendable, Equatable {
    public let sha256: String

    public init(sha256: String) {
        self.sha256 = sha256.lowercased()
    }
}

public enum VRChatConfigurationState: Sendable, Equatable {
    case absent
    case partial
    case complete(VRChatConfigurationIdentity)
}

public protocol VRChatConfigurationMigrating: Sendable {
    /// Performs the complete source-side validation without writing anything.
    func validateSource(
        in originalLibrary: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity

    /// Creates a self-contained migration tree below `stagingRoot`.
    func stageConfiguration(
        from originalLibrary: URL,
        to stagingRoot: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity

    /// Classifies and verifies the three selectively migrated configuration
    /// units. Unrelated configuration for other apps is deliberately ignored.
    func inspectConfiguration(
        at root: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationState
}

public struct SelectiveVRChatConfigurationMigrator: VRChatConfigurationMigrating {
    public static let entitlementRelativePath =
        "Entitlements/com.vrchat.mobile.plist"
    public static let appSettingsRelativePath =
        "App Settings/com.vrchat.mobile.plist"
    public static let keymappingRelativePath =
        "Keymapping/com.vrchat.mobile"

    public static let safeAppSettingKeys: Set<String> = [
        "aspectRatio",
        "bundleIdentifier",
        "customScaler",
        "disableBuiltinMouse",
        "displayRotation",
        "enableScrollWheel",
        "floatingWindow",
        "hideTitleBar",
        "inverseScreenValues",
        "keymapping",
        "noKMOnInput",
        "notch",
        "resizableAspectRatioHeight",
        "resizableAspectRatioType",
        "resizableAspectRatioWidth",
        "resolution",
        "sensitivity",
        "version",
        "windowHeight",
        "windowWidth"
    ]

    public static let publishedRelativePaths = [
        entitlementRelativePath,
        appSettingsRelativePath,
        keymappingRelativePath
    ]

    private static let booleanKeys: Set<String> = [
        "disableBuiltinMouse",
        "enableScrollWheel",
        "floatingWindow",
        "hideTitleBar",
        "inverseScreenValues",
        "keymapping",
        "noKMOnInput",
        "notch"
    ]
    private static let integralKeys: Set<String> = [
        "aspectRatio",
        "displayRotation",
        "resizableAspectRatioHeight",
        "resizableAspectRatioType",
        "resizableAspectRatioWidth",
        "resolution",
        "windowHeight",
        "windowWidth"
    ]
    private static let numericKeys: Set<String> = [
        "customScaler",
        "sensitivity"
    ]
    private static let stringKeys: Set<String> = [
        "bundleIdentifier",
        "version"
    ]

    public init() {}

    public func validateSource(
        in originalLibrary: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity {
        let artifacts = try migrationArtifacts(
            from: originalLibrary,
            destinationLibrary: destinationLibrary
        )
        return Self.identity(of: artifacts)
    }

    public func stageConfiguration(
        from originalLibrary: URL,
        to stagingRoot: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationIdentity {
        guard Self.nodeKind(stagingRoot) == nil else {
            throw PatcherError.unknownModification(
                "configuration staging already exists"
            )
        }
        let artifacts = try migrationArtifacts(
            from: originalLibrary,
            destinationLibrary: destinationLibrary
        )
        try SecureFileSystem.createDirectories(stagingRoot)
        try SecureFileSystem.createDirectories(
            stagingRoot.appendingPathComponent(
                Self.keymappingRelativePath,
                isDirectory: true
            )
        )
        for artifact in artifacts {
            let destination = stagingRoot.appendingPathComponent(
                artifact.relativePath
            )
            try SecureFileSystem.createDirectories(
                destination.deletingLastPathComponent()
            )
            try SecureFileSystem.writeFileExclusive(
                artifact.data,
                to: destination
            )
        }
        let expected = Self.identity(of: artifacts)
        guard case .complete(let actual) = try inspectConfiguration(
            at: stagingRoot,
            destinationLibrary: destinationLibrary
        ), actual == expected else {
            throw PatcherError.transactionFailed(
                "staged VRChat configuration did not verify"
            )
        }
        return expected
    }

    public func inspectConfiguration(
        at root: URL,
        destinationLibrary: URL
    ) throws -> VRChatConfigurationState {
        let entitlement = root.appendingPathComponent(
            Self.entitlementRelativePath
        )
        let appSettings = root.appendingPathComponent(
            Self.appSettingsRelativePath
        )
        let keymapping = root.appendingPathComponent(
            Self.keymappingRelativePath,
            isDirectory: true
        )
        let kinds = [
            Self.nodeKind(entitlement),
            Self.nodeKind(appSettings),
            Self.nodeKind(keymapping)
        ]
        let count = kinds.compactMap { $0 }.count
        if count == 0 { return .absent }
        if count != kinds.count { return .partial }
        try Self.requireDirectory(root, label: "patched PlayCover library")
        try Self.requireDirectory(
            entitlement.deletingLastPathComponent(),
            label: "patched Entitlements directory"
        )
        try Self.requireDirectory(
            appSettings.deletingLastPathComponent(),
            label: "patched App Settings directory"
        )
        try Self.requireDirectory(
            keymapping.deletingLastPathComponent(),
            label: "patched Keymapping directory"
        )
        guard kinds[0] == .regularFile,
              kinds[1] == .regularFile,
              kinds[2] == .directory else {
            throw PatcherError.unknownModification(
                "VRChat configuration contains a symlink or unsupported node type"
            )
        }

        let entitlementData = try SecureFileSystem.readRegularFile(entitlement)
        guard try Self.propertyListDictionary(entitlementData) != nil else {
            throw PatcherError.unknownModification(
                "VRChat entitlement profile is not a property-list dictionary"
            )
        }

        let settingsData = try SecureFileSystem.readRegularFile(appSettings)
        guard let settings = try Self.propertyListDictionary(settingsData) else {
            throw PatcherError.unknownModification(
                "VRChat App Settings is not a property-list dictionary"
            )
        }
        try Self.validateSanitizedSettings(settings)

        let keymapArtifacts = try Self.readKeymappingArtifacts(
            at: keymapping,
            expectedLibrary: destinationLibrary,
            rewriteFrom: nil
        )
        var artifacts = [
            Artifact(
                relativePath: Self.entitlementRelativePath,
                data: entitlementData
            ),
            Artifact(
                relativePath: Self.appSettingsRelativePath,
                data: settingsData
            )
        ]
        artifacts.append(contentsOf: keymapArtifacts)
        return .complete(Self.identity(of: artifacts))
    }

    private func migrationArtifacts(
        from originalLibrary: URL,
        destinationLibrary: URL
    ) throws -> [Artifact] {
        let entitlement = originalLibrary.appendingPathComponent(
            Self.entitlementRelativePath
        )
        let appSettings = originalLibrary.appendingPathComponent(
            Self.appSettingsRelativePath
        )
        let keymapping = originalLibrary.appendingPathComponent(
            Self.keymappingRelativePath,
            isDirectory: true
        )

        try Self.requireDirectory(
            originalLibrary,
            label: "original PlayCover library"
        )
        try Self.requireDirectory(
            entitlement.deletingLastPathComponent(),
            label: "source Entitlements directory"
        )
        try Self.requireDirectory(
            appSettings.deletingLastPathComponent(),
            label: "source App Settings directory"
        )
        try Self.requireDirectory(
            keymapping.deletingLastPathComponent(),
            label: "source Keymapping directory"
        )

        let entitlementData = try Self.requiredRegularFile(entitlement)
        guard try Self.propertyListDictionary(entitlementData) != nil else {
            throw PatcherError.unknownModification(
                "source VRChat entitlement profile is not a property-list dictionary"
            )
        }
        let sourceSettingsData = try Self.requiredRegularFile(appSettings)
        guard let sourceSettings = try Self.propertyListDictionary(
            sourceSettingsData
        ) else {
            throw PatcherError.unknownModification(
                "source VRChat App Settings is not a property-list dictionary"
            )
        }
        let sanitizedSettings = try Self.sanitize(settings: sourceSettings)
        let sanitizedData = try PropertyListSerialization.data(
            fromPropertyList: sanitizedSettings,
            format: .xml,
            options: 0
        )

        guard Self.nodeKind(keymapping) == .directory else {
            if Self.nodeKind(keymapping) == nil {
                throw PatcherError.vrChatConfigurationMissing(keymapping)
            }
            throw PatcherError.unknownModification(
                "source VRChat keymapping is a symlink or unsupported node type"
            )
        }
        var artifacts = [
            Artifact(
                relativePath: Self.entitlementRelativePath,
                data: entitlementData
            ),
            Artifact(
                relativePath: Self.appSettingsRelativePath,
                data: sanitizedData
            )
        ]
        artifacts.append(contentsOf: try Self.readKeymappingArtifacts(
            at: keymapping,
            expectedLibrary: destinationLibrary,
            rewriteFrom: originalLibrary
        ))
        return artifacts
    }

    private struct Artifact {
        let relativePath: String
        let data: Data
    }

    private enum NodeKind: Equatable {
        case regularFile
        case directory
        case symbolicLink
        case unsupported
    }

    private static func nodeKind(_ url: URL) -> NodeKind? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            return nil
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .unsupported
        }
    }

    private static func requiredRegularFile(_ url: URL) throws -> Data {
        guard let kind = nodeKind(url) else {
            throw PatcherError.vrChatConfigurationMissing(url)
        }
        guard kind == .regularFile else {
            throw PatcherError.unknownModification(
                "VRChat configuration is a symlink or unsupported node: \(url.path)"
            )
        }
        return try SecureFileSystem.readRegularFile(url)
    }

    private static func requireDirectory(_ url: URL, label: String) throws {
        guard let kind = nodeKind(url) else {
            throw PatcherError.vrChatConfigurationMissing(url)
        }
        guard kind == .directory else {
            throw PatcherError.unknownModification(
                "\(label) is a symlink or unsupported node type"
            )
        }
    }

    private static func propertyListDictionary(
        _ data: Data
    ) throws -> [String: Any]? {
        try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func sanitize(
        settings: [String: Any]
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in safeAppSettingKeys {
            guard let value = settings[key] else {
                throw PatcherError.unknownModification(
                    "source VRChat App Settings is missing safe field \(key)"
                )
            }
            try validateSetting(value, for: key)
            result[key] = value
        }
        try validateSanitizedSettings(result)
        return result
    }

    private static func validateSanitizedSettings(
        _ settings: [String: Any]
    ) throws {
        // PlayCover expands this plist as it runs. Only the small subset copied
        // during initial import is required here; additional settings remain
        // ordinary user data and do not turn the installation into an error.
        for key in safeAppSettingKeys {
            guard let value = settings[key] else {
                throw PatcherError.unknownModification(
                    "VRChat App Settings is missing safe field \(key)"
                )
            }
            try validateSetting(value, for: key)
        }
        guard settings["bundleIdentifier"] as? String == "com.vrchat.mobile" else {
            throw PatcherError.unknownModification(
                "VRChat App Settings has an unexpected bundle identifier"
            )
        }
    }

    private static func validateSetting(_ value: Any, for key: String) throws {
        let valid: Bool
        if booleanKeys.contains(key) {
            valid = isBoolean(value)
        } else if integralKeys.contains(key) {
            valid = isIntegralNumber(value)
        } else if numericKeys.contains(key) {
            valid = isNumber(value)
        } else if stringKeys.contains(key) {
            valid = value is String
        } else {
            valid = false
        }
        guard valid else {
            throw PatcherError.unknownModification(
                "VRChat App Settings field \(key) has an invalid type"
            )
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() &&
            number.doubleValue.isFinite
    }

    private static func isIntegralNumber(_ value: Any) -> Bool {
        guard isNumber(value), let number = value as? NSNumber else {
            return false
        }
        let double = number.doubleValue
        return double.rounded(.towardZero) == double
    }

    private static func readKeymappingArtifacts(
        at directory: URL,
        expectedLibrary: URL,
        rewriteFrom originalLibrary: URL?
    ) throws -> [Artifact] {
        guard nodeKind(directory) == .directory else {
            throw PatcherError.unknownModification(
                "VRChat keymapping is a symlink or unsupported node type"
            )
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .literal
            ) == .orderedAscending
        }
        var artifacts: [Artifact] = []
        for child in children {
            guard child.deletingLastPathComponent().standardizedFileURL ==
                    directory.standardizedFileURL,
                  !child.lastPathComponent.isEmpty,
                  child.lastPathComponent != ".",
                  child.lastPathComponent != "..",
                  nodeKind(child) == .regularFile else {
                throw PatcherError.unknownModification(
                    "VRChat keymapping contains a symlink, directory, or unsupported node"
                )
            }
            var data = try SecureFileSystem.readRegularFile(child)
            if child.pathExtension == "plist" &&
                child.lastPathComponent.hasSuffix(".config.plist") {
                let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                )
                let rewritten = try rewriteFileURLs(
                    in: plist,
                    expectedLibrary: expectedLibrary,
                    rewriteFrom: originalLibrary
                )
                data = try PropertyListSerialization.data(
                    fromPropertyList: rewritten,
                    format: .xml,
                    options: 0
                )
            }
            artifacts.append(Artifact(
                relativePath:
                    "\(keymappingRelativePath)/\(child.lastPathComponent)",
                data: data
            ))
        }
        return artifacts
    }

    private static func rewriteFileURLs(
        in value: Any,
        expectedLibrary: URL,
        rewriteFrom originalLibrary: URL?
    ) throws -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in dictionary {
                result[key] = try rewriteFileURLs(
                    in: nested,
                    expectedLibrary: expectedLibrary,
                    rewriteFrom: originalLibrary
                )
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map {
                try rewriteFileURLs(
                    in: $0,
                    expectedLibrary: expectedLibrary,
                    rewriteFrom: originalLibrary
                )
            }
        }
        guard let string = value as? String,
              string.lowercased().hasPrefix("file:") else {
            return value
        }
        guard let fileURL = URL(string: string), fileURL.isFileURL else {
            throw PatcherError.unknownModification(
                "VRChat keymapping contains an invalid file URL"
            )
        }
        if let originalLibrary {
            let relative = try relativePath(
                of: fileURL,
                below: originalLibrary
            )
            return expectedLibrary.appendingPathComponent(relative).absoluteString
        }
        _ = try relativePath(of: fileURL, below: expectedLibrary)
        return string
    }

    private static func relativePath(of url: URL, below root: URL) throws -> String {
        let candidate = url.path
        let base = root.path
        guard candidate.hasPrefix(base + "/") else {
            throw PatcherError.unknownModification(
                "VRChat keymapping file URL escapes its PlayCover library"
            )
        }
        let relative = String(candidate.dropFirst(base.count + 1))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains("..") else {
            throw PatcherError.unknownModification(
                "VRChat keymapping file URL has an unsafe relative path"
            )
        }
        return relative
    }

    private static func identity(
        of artifacts: [Artifact]
    ) -> VRChatConfigurationIdentity {
        var hasher = SHA256()
        hasher.update(data: Data("PCVR-CONFIGURATION/1\n".utf8))
        for artifact in artifacts.sorted(by: {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }) {
            let path = Data(artifact.relativePath.utf8)
            let digest = hex(SHA256.hash(data: artifact.data))
            hasher.update(data: Data("F \(path.count) ".utf8))
            hasher.update(data: path)
            hasher.update(data: Data(" \(artifact.data.count) \(digest)\n".utf8))
        }
        return VRChatConfigurationIdentity(
            sha256: hex(hasher.finalize())
        )
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
