import Foundation
import PCVRPatcherCore

private enum ToolError: LocalizedError {
    case usage
    case missingPatchedIdentity
    case identityMismatch(String)
    case malformedManifest

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            Usage:
              pcvr-manifest-tool identity <PlayCover.app>
              pcvr-manifest-tool verify <manifest.json> <original|patched> <PlayCover.app>
              pcvr-manifest-tool propose <base-manifest.json> <patched-PlayCover.app> <reviewed-controller-package.json> <candidate-output.json>
            """
        case .missingPatchedIdentity:
            return "The manifest has no patchedPlayCover identity."
        case let .identityMismatch(reason):
            return "Application identity mismatch: \(reason)"
        case .malformedManifest:
            return "The compatibility manifest is not a JSON object."
        }
    }
}

@main
private enum ManifestTool {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(error is ToolError ? 64 : 1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw ToolError.usage }
        switch command {
        case "identity" where arguments.count == 2:
            let identity = try AppTreeVerifier().identity(of: appURL(arguments[1]))
            try writeJSON(identity, to: FileHandle.standardOutput)

        case "verify" where arguments.count == 4:
            let manifest = try PatcherEngine.loadManifest(from: fileURL(arguments[1]))
            let expected: AppIdentity
            switch arguments[2] {
            case "original": expected = manifest.playCover
            case "patched":
                guard let patched = manifest.patchedPlayCover else {
                    throw ToolError.missingPatchedIdentity
                }
                expected = patched
            default: throw ToolError.usage
            }
            let actual = try AppTreeVerifier().identity(of: appURL(arguments[3]))
            try requireMatch(actual: actual, expected: expected)
            print("verified \(arguments[2]) PlayCover: \(actual.treeSHA256)")

        case "propose" where arguments.count == 5:
            let sourceURL = fileURL(arguments[1])
            let app = appURL(arguments[2])
            let packageManifestURL = fileURL(arguments[3])
            let outputURL = fileURL(arguments[4])
            let manifest = try PatcherEngine.loadManifest(from: sourceURL)
            let identity = try AppTreeVerifier().identity(of: app)
            guard identity.bundleIdentifier == "io.github.northstarxyzz.PlayCoverVRChat",
                  identity.shortVersion == manifest.playCover.shortVersion,
                  identity.buildVersion == manifest.playCover.buildVersion,
                  identity.executableName == "PlayCover VRChat" else {
                throw ToolError.identityMismatch(
                    "parallel payload changed the locked customized PlayCover metadata"
                )
            }

            let sourceData = try Data(contentsOf: sourceURL)
            guard var object = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
                throw ToolError.malformedManifest
            }
            let identityData = try JSONEncoder().encode(identity)
            guard let identityObject = try JSONSerialization.jsonObject(with: identityData) as? [String: Any] else {
                throw ToolError.malformedManifest
            }
            let packageData = try Data(contentsOf: packageManifestURL)
            guard let packageDocument = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
                  let controllerPackage = packageDocument["controllerPackage"] as? [String: Any] else {
                throw ToolError.malformedManifest
            }
            object["patchedPlayCover"] = identityObject
            object["controllerPackage"] = controllerPackage
            let outputData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) + Data("\n".utf8)
            try outputData.write(to: outputURL, options: .atomic)
            let candidate = try PatcherEngine.loadManifest(from: outputURL)
            guard candidate.patchedPlayCover != nil else { throw ToolError.missingPatchedIdentity }
            FileHandle.standardError.write(Data("UNTRUSTED CANDIDATE: independently review the payload and manifest before committing this identity.\n".utf8))
            print("proposed patched tree \(identity.treeSHA256)")

        default:
            throw ToolError.usage
        }
    }

    private static func requireMatch(actual: AppIdentity, expected: AppIdentity) throws {
        let comparisons: [(String, String, String)] = [
            ("bundle identifier", actual.bundleIdentifier, expected.bundleIdentifier),
            ("version", actual.shortVersion, expected.shortVersion),
            ("build", actual.buildVersion, expected.buildVersion),
            ("executable", actual.executableName, expected.executableName),
            ("executable SHA-256", actual.executableSHA256.lowercased(), expected.executableSHA256.lowercased()),
            ("Mach-O UUID", actual.executableUUID.uppercased(), expected.executableUUID.uppercased()),
            ("tree SHA-256", actual.treeSHA256.lowercased(), expected.treeSHA256.lowercased())
        ]
        if let mismatch = comparisons.first(where: { $0.1 != $0.2 }) {
            throw ToolError.identityMismatch("\(mismatch.0): \(mismatch.1), expected \(mismatch.2)")
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        handle.write(try encoder.encode(value) + Data("\n".utf8))
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func appURL(_ path: String) -> URL {
        // Preserve the caller's physical `/private/tmp` spelling. Foundation's
        // standardizedFileURL rewrites it to the `/tmp` symlink, which the
        // no-follow tree auditor must correctly reject.
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
