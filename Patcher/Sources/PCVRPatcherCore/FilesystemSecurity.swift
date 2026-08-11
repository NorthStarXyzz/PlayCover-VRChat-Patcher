import CryptoKit
import Darwin
import Foundation

struct SecureNodeBinding: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let ownerUID: UInt32
    let mode: UInt32
    let contentSHA256: String
    let metadataSHA256: String

    func validateShape() -> Bool {
        inode != 0 &&
            AppIdentity.isSHA256(contentSHA256) &&
            AppIdentity.isSHA256(metadataSHA256)
    }
}

enum SecureFileSystem {
    static func requireNoSymlinkComponents(
        _ url: URL,
        allowMissingSuffix: Bool
    ) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw PatcherError.unsafePath(url)
        }
        let components = try safeComponents(url)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            var status = stat()
            let result = current.path.withCString { lstat($0, &status) }
            if result != 0 {
                if errno == ENOENT && allowMissingSuffix { return }
                throw PatcherError.unsafePath(current)
            }
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw PatcherError.unsafePath(current)
            }
            if index < components.count - 1 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw PatcherError.unsafePath(current)
                }
            }
        }
    }

    static func createDirectories(_ url: URL, mode: mode_t = 0o700) throws {
        let components = try safeComponents(url)
        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("open filesystem root") }
        defer { close(descriptor) }
        for component in components {
            var next = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if next < 0 && errno == ENOENT {
                let created = component.withCString {
                    mkdirat(descriptor, $0, mode)
                }
                guard created == 0 || errno == EEXIST else {
                    throw posixError("create secure directory \(component)")
                }
                next = component.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard next >= 0 else {
                throw posixError("open secure directory \(component)")
            }
            close(descriptor)
            descriptor = next
        }
    }

    static func renameExclusive(_ source: URL, _ destination: URL) throws {
        try withParentDirectory(of: source, createMissing: false) {
            sourceParent, sourceName in
            try withParentDirectory(of: destination, createMissing: false) {
                destinationParent, destinationName in
                let result = sourceName.withCString { sourcePointer in
                    destinationName.withCString { destinationPointer in
                        renameatx_np(
                            sourceParent,
                            sourcePointer,
                            destinationParent,
                            destinationPointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else {
                    throw posixError("secure atomic rename")
                }
            }
        }
    }

    static func status(of url: URL) throws -> stat {
        try withParentDirectory(of: url, createMissing: false) {
            parent, name in
            var status = stat()
            let result = name.withCString {
                fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { throw posixError("inspect secure node") }
            return status
        }
    }

    /// A security-sensitive presence check. Only an absent leaf (`ENOENT`)
    /// or ancestor is reported as absent; an inaccessible/invalid component
    /// or any other filesystem error is propagated instead of being mistaken
    /// for absence.
    static func nodeExistsStrict(_ url: URL) throws -> Bool {
        let components = try safeComponents(url)
        guard let leaf = components.last else {
            throw PatcherError.unsafePath(url)
        }
        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("open filesystem root") }
        defer { close(descriptor) }
        for component in components.dropLast() {
            let next = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if next < 0 && errno == ENOENT { return false }
            guard next >= 0 else {
                throw posixError("open security-sensitive path component")
            }
            close(descriptor)
            descriptor = next
        }
        var status = stat()
        let result = leaf.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError("inspect security-sensitive node")
    }

    /// Enumerates one already-existing directory through a descriptor opened
    /// with `O_NOFOLLOW`. Callers compare this closed set with their reviewed
    /// protocol state before accepting any installed root tree.
    static func directEntryNames(in directory: URL) throws -> Set<String> {
        try withParentDirectory(of: directory, createMissing: false) {
            parent, name in
            let descriptor = name.withCString {
                openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw posixError("open reviewed directory for enumeration")
            }
            guard let stream = fdopendir(descriptor) else {
                close(descriptor)
                throw posixError("enumerate reviewed directory")
            }
            defer { closedir(stream) }

            var names = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else {
                        throw posixError("read reviewed directory entry")
                    }
                    break
                }
                let entryName = withUnsafePointer(to: entry.pointee.d_name) {
                    pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) { String(cString: $0) }
                }
                if entryName == "." || entryName == ".." { continue }
                guard !entryName.isEmpty,
                      !entryName.contains("/") else {
                    throw PatcherError.unknownModification(
                        "unsafe direct entry in reviewed directory"
                    )
                }
                guard names.insert(entryName).inserted else {
                    throw PatcherError.unknownModification(
                        "duplicate direct entry in reviewed directory"
                    )
                }
            }
            return names
        }
    }

    static func nodeExists(_ url: URL) -> Bool {
        do {
            _ = try status(of: url)
            return true
        } catch {
            return false
        }
    }

    static func unlinkRegularFileIfPresent(
        _ url: URL,
        expectedOwnerUID: uid_t = getuid()
    ) throws {
        try withParentDirectory(of: url, createMissing: false) {
            parent, name in
            var status = stat()
            let inspected = name.withCString {
                fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if inspected != 0 && errno == ENOENT { return }
            guard inspected == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == expectedOwnerUID,
                  status.st_nlink == 1,
                  status.st_mode & 0o022 == 0 else {
                throw PatcherError.unknownModification(
                    "refusing to unlink an unsafe transaction file"
                )
            }
            let result = name.withCString { unlinkat(parent, $0, 0) }
            guard result == 0 else {
                throw posixError("unlink transaction file")
            }
        }
    }

    static func writeFileExclusive(
        _ data: Data,
        to url: URL,
        mode: mode_t = 0o600
    ) throws {
        try withParentDirectory(of: url, createMissing: false) {
            parent, name in
            let descriptor = name.withCString {
                openat(
                    parent,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode
                )
            }
            guard descriptor >= 0 else {
                throw posixError("create exclusive reviewed file")
            }
            var completed = false
            defer {
                close(descriptor)
                if !completed {
                    _ = name.withCString { unlinkat(parent, $0, 0) }
                }
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let amount = write(
                        descriptor,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else {
                        throw posixError("write exclusive reviewed file")
                    }
                    offset += amount
                }
            }
            guard fsync(descriptor) == 0 else {
                throw posixError("sync exclusive reviewed file")
            }
            completed = true
        }
    }

    static func readRegularFile(
        _ url: URL,
        maximumBytes: Int = 16 * 1_024 * 1_024
    ) throws -> Data {
        try withParentDirectory(of: url, createMissing: false) {
            parent, name in
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw posixError("open reviewed file without following links")
            }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0,
                  before.st_size <= maximumBytes else {
                throw PatcherError.unknownModification(
                    "reviewed file has an unsafe type or size"
                )
            }
            var data = Data()
            data.reserveCapacity(Int(before.st_size))
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let amount = read(descriptor, &buffer, buffer.count)
                if amount < 0 && errno == EINTR { continue }
                guard amount >= 0 else {
                    throw posixError("read reviewed file")
                }
                if amount == 0 { break }
                guard data.count <= maximumBytes - amount else {
                    throw PatcherError.unknownModification(
                        "reviewed file exceeds its size limit"
                    )
                }
                data.append(contentsOf: buffer[0..<amount])
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  data.count == Int(before.st_size) else {
                throw PatcherError.unknownModification(
                    "reviewed file changed while it was read"
                )
            }
            return data
        }
    }

    static func requireNoExtendedACL(_ url: URL) throws {
        errno = 0
        let acl = url.path.withCString {
            acl_get_file($0, ACL_TYPE_EXTENDED)
        }
        if acl == nil, errno == ENOENT { return }
        guard let acl else {
            throw PatcherError.unknownModification(
                "cannot inspect ACL at \(url.path)"
            )
        }
        acl_free(UnsafeMutableRawPointer(acl))
        // On Darwin, absence is reported as nil + ENOENT. Any returned
        // extended ACL object therefore means an ACL is present.
        throw PatcherError.unknownModification(
            "extended ACL is not allowed at \(url.path)"
        )
    }

    static func withParentDirectory<T>(
        of url: URL,
        createMissing: Bool,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let components = try safeComponents(url)
        guard let leaf = components.last else {
            throw PatcherError.unsafePath(url)
        }
        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("open filesystem root") }
        defer { close(descriptor) }
        for component in components.dropLast() {
            var next = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if next < 0 && errno == ENOENT && createMissing {
                let created = component.withCString {
                    mkdirat(descriptor, $0, 0o700)
                }
                guard created == 0 || errno == EEXIST else {
                    throw posixError("create secure parent \(component)")
                }
                next = component.withCString {
                    openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard next >= 0 else {
                throw PatcherError.unsafePath(url)
            }
            close(descriptor)
            descriptor = next
        }
        return try body(descriptor, leaf)
    }

    private static func safeComponents(_ url: URL) throws -> [String] {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("//"),
              url.path != "/" else {
            throw PatcherError.unsafePath(url)
        }
        let components = url.pathComponents.dropFirst()
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
              }) else {
            throw PatcherError.unsafePath(url)
        }
        return Array(components)
    }

    private static func posixError(_ action: String) -> PatcherError {
        .transactionFailed(
            "\(action): errno \(errno): \(String(cString: strerror(errno)))"
        )
    }
}

struct SecureMetadataIdentity: Sendable, Equatable {
    let sha256: String
}

struct PhysicalTreeEntry {
    let relativePath: String
    let url: URL
    let status: stat
}

enum PhysicalTree {
    static func entries(
        below root: URL,
        includeRoot: Bool = false
    ) throws -> [PhysicalTreeEntry] {
        try SecureFileSystem.requireNoSymlinkComponents(
            root,
            allowMissingSuffix: false
        )
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw PatcherError.unknownModification(
                "cannot physically enumerate \(root.path)"
            )
        }
        var entries: [PhysicalTreeEntry] = []
        if includeRoot {
            entries.append(PhysicalTreeEntry(
                relativePath: ".",
                url: root,
                status: try SecureFileSystem.status(of: root)
            ))
        }
        while let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard url.path.withCString({ lstat($0, &status) }) == 0 else {
                throw PatcherError.unknownModification(
                    "tree entry disappeared during physical enumeration"
                )
            }
            // FileManager's URL enumerator does not traverse symbolic links.
            // Calling skipDescendants() for a framework alias such as
            // Sparkle.framework/Resources can instead prune later real
            // siblings (notably Versions/B) from the physical tree.
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(prefix) else {
                throw PatcherError.unknownModification(
                    "physical enumeration escaped its root"
                )
            }
            let relative = String(url.path.dropFirst(prefix.count))
            guard isSafeRelativePath(relative) else {
                throw PatcherError.unknownModification(
                    "unsafe relative path in reviewed tree"
                )
            }
            entries.append(PhysicalTreeEntry(
                relativePath: relative,
                url: url,
                status: status
            ))
        }
        if let traversalError { throw traversalError }
        entries.sort {
            $0.relativePath.utf8.lexicographicallyPrecedes(
                $1.relativePath.utf8
            )
        }
        return entries
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty &&
            !path.hasPrefix("/") &&
            !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains("..")
    }
}

enum SecureTreeAuditor {
    static func inspect(
        _ root: URL,
        expectedOwnerUID: uid_t = getuid()
    ) throws -> SecureMetadataIdentity {
        try SecureFileSystem.requireNoSymlinkComponents(
            root,
            allowMissingSuffix: false
        )
        var hasher = SHA256()
        hasher.update(data: Data("PCVR-METADATA/1\n".utf8))
        for entry in try PhysicalTree.entries(below: root, includeRoot: true) {
            let relative = entry.relativePath
            let url = entry.url
            let status = entry.status
            let type = status.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG || type == S_IFLNK else {
                throw PatcherError.unknownModification(
                    "unsupported node type at \(relative)"
                )
            }
            guard status.st_uid == expectedOwnerUID else {
                throw PatcherError.unknownModification(
                    "unexpected owner at \(relative)"
                )
            }
            guard status.st_mode & 0o022 == 0 else {
                throw PatcherError.unknownModification(
                    "group/other-writable node at \(relative)"
                )
            }
            let dangerousFlags = UInt32(
                UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
            )
            guard status.st_flags & dangerousFlags == 0 else {
                throw PatcherError.unknownModification(
                    "unsafe filesystem flags at \(relative)"
                )
            }
            if type == S_IFREG || type == S_IFLNK {
                guard status.st_nlink == 1 else {
                    throw PatcherError.unknownModification(
                        "unexpected link count at \(relative)"
                    )
                }
            }
            if type == S_IFLNK {
                let target = try FileManager.default
                    .destinationOfSymbolicLink(atPath: url.path)
                guard !target.hasPrefix("/") else {
                    throw PatcherError.unknownModification(
                        "absolute symlink is not allowed at \(relative)"
                    )
                }
                let resolved = url.deletingLastPathComponent()
                    .appendingPathComponent(target).standardizedFileURL.path
                let reviewedRoot = root.standardizedFileURL.path
                guard resolved == reviewedRoot ||
                        resolved.hasPrefix(reviewedRoot + "/") else {
                    throw PatcherError.unknownModification(
                        "symlink escapes the reviewed tree at \(relative)"
                    )
                }
            }
            if type == S_IFLNK {
                try requireNoACLOnSymbolicLink(url)
            } else {
                try SecureFileSystem.requireNoExtendedACL(url)
            }

            let pathData = Data(relative.utf8)
            let kind = type == S_IFDIR ? "D" : (type == S_IFREG ? "F" : "L")
            let record =
                "N \(pathData.count) \(relative) \(kind) " +
                "\(status.st_mode & 0o7777) \(status.st_uid) \(status.st_gid) " +
                "\(status.st_flags) \(status.st_nlink)\n"
            hasher.update(data: Data(record.utf8))
        }
        return SecureMetadataIdentity(
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    static func binding(
        for root: URL,
        expectedOwnerUID: uid_t = getuid()
    ) throws -> SecureNodeBinding {
        let status = try SecureFileSystem.status(of: root)
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == expectedOwnerUID else {
            throw PatcherError.unknownModification(
                "owned staging root has an unexpected type or owner"
            )
        }
        let metadata = try inspect(root, expectedOwnerUID: expectedOwnerUID)
        return SecureNodeBinding(
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            ownerUID: status.st_uid,
            mode: UInt32(status.st_mode),
            contentSHA256: try AppTreeVerifier.treeSHA256(root),
            metadataSHA256: metadata.sha256
        )
    }

    static func requireBinding(
        _ expected: SecureNodeBinding,
        for root: URL
    ) throws {
        guard expected.validateShape() else {
            throw PatcherError.unknownModification(
                "transaction journal contains an invalid staging binding"
            )
        }
        let actual = try binding(
            for: root,
            expectedOwnerUID: expected.ownerUID
        )
        guard actual == expected else {
            throw PatcherError.unknownModification(
                "owned staging node was replaced or modified"
            )
        }
    }

    private static func requireNoACLOnSymbolicLink(_ url: URL) throws {
        errno = 0
        let acl = url.path.withCString {
            acl_get_link_np($0, ACL_TYPE_EXTENDED)
        }
        if acl == nil, errno == ENOENT { return }
        guard let acl else {
            throw PatcherError.unknownModification(
                "cannot inspect ACL at \(url.path)"
            )
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw PatcherError.unknownModification(
            "extended ACL is not allowed at \(url.path)"
        )
    }
}
