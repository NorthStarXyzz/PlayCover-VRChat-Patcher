import Darwin
import Foundation

public protocol VRChatTreeImporting: Sendable {
    func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy
}

/// Imports an app tree without ever linking destination files to the source.
/// APFS clone-on-write is attempted first; an ordinary metadata-preserving copy
/// is used only after the failed clone attempt has been removed completely.
public struct CloneFirstVRChatImporter: VRChatTreeImporting {
    public init() {}

    public func copyTree(
        from source: URL,
        to destination: URL
    ) throws -> VRChatImportStrategy {
        _ = try SecureTreeAuditor.inspect(source)
        try SecureFileSystem.requireNoSymlinkComponents(
            destination.deletingLastPathComponent(),
            allowMissingSuffix: false
        )
        guard !nodeExists(destination) else {
            throw PatcherError.invalidOperation(
                "VRChat import destination already exists"
            )
        }
        let reviewedCopyFlags =
            COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_STAT | COPYFILE_RECURSIVE
        let cloneFlags = copyfile_flags_t(
            reviewedCopyFlags | COPYFILE_CLONE_FORCE
        )
        if copyfile(source.path, destination.path, nil, cloneFlags) == 0 {
            _ = try SecureTreeAuditor.inspect(destination)
            try Self.rejectHardLinks(from: source, to: destination)
            return .clone
        }

        let cloneError = errno
        if nodeExists(destination) {
            throw PatcherError.transactionFailed(
                "VRChat clone left a partial destination; Repair is required " +
                "before fallback (\(Self.errnoDescription(cloneError)))"
            )
        }
        let copyFlags = copyfile_flags_t(reviewedCopyFlags)
        guard copyfile(source.path, destination.path, nil, copyFlags) == 0 else {
            let copyError = errno
            throw PatcherError.transactionFailed(
                "VRChat clone failed (\(Self.errnoDescription(cloneError))); " +
                "copy fallback failed (\(Self.errnoDescription(copyError)))"
            )
        }
        _ = try SecureTreeAuditor.inspect(destination)
        try Self.rejectHardLinks(from: source, to: destination)
        return .copyFallback
    }

    public static func rejectHardLinks(
        from source: URL,
        to destination: URL
    ) throws {
        for entry in try PhysicalTree.entries(below: source) {
            let relative = entry.relativePath
            let sourceStatus = entry.status
            guard (sourceStatus.st_mode & S_IFMT) == S_IFREG else { continue }

            let destinationEntry = destination.appendingPathComponent(relative)
            var destinationStatus = stat()
            guard destinationEntry.path.withCString({
                lstat($0, &destinationStatus)
            }) == 0 else {
                throw PatcherError.transactionFailed(
                    "imported VRChat is missing \(relative)"
                )
            }
            guard (destinationStatus.st_mode & S_IFMT) == S_IFREG else {
                throw PatcherError.transactionFailed(
                    "imported VRChat changed the file type at \(relative)"
                )
            }
            if sourceStatus.st_dev == destinationStatus.st_dev,
               sourceStatus.st_ino == destinationStatus.st_ino {
                throw PatcherError.hardLinkDetected(relative)
            }
        }
    }

    private static func errnoDescription(_ value: Int32) -> String {
        "errno \(value): \(String(cString: strerror(value)))"
    }

    private func nodeExists(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString { lstat($0, &status) == 0 }
    }
}
