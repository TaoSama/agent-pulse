import CoreServices
import Foundation

public struct RuntimeFileChanges: Sendable {
    public let paths: Set<String>
    public let requiresFullRescan: Bool

    public init(paths: Set<String> = [], requiresFullRescan: Bool = false) {
        self.paths = paths
        self.requiresFullRescan = requiresFullRescan
    }
}

/// Injectable notifications keep fixture clocks independent of OS event delivery.
public protocol RuntimeFileChangeMonitoring: Sendable {
    func takeChanges() -> RuntimeFileChanges
}

final class RuntimeFileDiscoveryIndex {
    struct Entry {
        let url: URL
        let size: Int
        let modifiedAt: Date
    }

    private let roots: [URL]
    private let monitor: any RuntimeFileChangeMonitoring
    private var files: [String: [String: Entry]] = [:]
    private var readableRoots = Set<String>()
    private var failedRoots = Set<String>()
    private var failedPathsByRoot: [String: Set<String>] = [:]
    private var initialized = false
    private(set) var fullScanCount = 0
    private(set) var metadataReads = 0
    private var changedPaths = Set<String>()
    private var fullyRefreshed = false
    private var canonicalFiles = Set<String>()

    init(roots: [URL], monitor: (any RuntimeFileChangeMonitoring)?) throws {
        self.roots = roots
        self.monitor = try monitor ?? RuntimeFSEventMonitor(roots: roots)
    }

    /// Only changed paths touch the filesystem after the initial inventory.
    /// Changes to already tracked files need no reconstruction of the discovery list.
    func refresh(ignoringUpdatesFor trackedPaths: Set<String>) -> Bool {
        let changes = monitor.takeChanges()
        metadataReads = 0
        let sourcePaths = Set(changes.paths.map(normalizedSourcePath))
        changedPaths = sourcePaths
        fullyRefreshed = !initialized || changes.requiresFullRescan
        if !initialized || changes.requiresFullRescan {
            fullScanCount += 1
            for root in roots { rebuild(root) }
            updateCanonicalFiles()
            initialized = true
            return true
        }
        var membershipChanged = false
        var recoveredRoots = Set<String>()
        for root in roots {
            guard let failedPaths = failedPathsByRoot[root.path], sourcePaths.contains(where: { changed in
                failedPaths.contains { failed in
                    changed == failed || changed.hasPrefix(failed + "/") || failed.hasPrefix(changed + "/")
                }
            }) else { continue }
            // Reconcile only a root whose failing subtree changed. Unrelated
            // active-file appends must not repeatedly rescan an inaccessible tree.
            rebuild(root)
            fullScanCount += 1
            changedPaths.insert(root.path)
            recoveredRoots.insert(root.path)
            membershipChanged = true
        }
        for path in sourcePaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard !url.pathComponents.contains("subagents") else { continue }
            for root in roots where !recoveredRoots.contains(root.path) {
                if root.path == path || root.path.hasPrefix(path + "/") {
                    rebuild(root)
                    membershipChanged = true
                } else if path.hasPrefix(root.path + "/") {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    if exists && isDirectory.boolValue {
                        // Directory rename/create can deliver just the directory event.
                        removeSubtree(path, root: root)
                        enumerate(url, root: root)
                        membershipChanged = true
                    } else if let entry = entry(at: url) {
                        let previous = files[root.path]?[path]
                        files[root.path, default: [:]][path] = entry
                        changedPaths.insert(entry.url.path)
                        if let previous { changedPaths.insert(previous.url.path) }
                        membershipChanged = membershipChanged || previous?.url != entry.url
                            || !trackedPaths.contains(entry.url.path)
                    } else {
                        let removed = removeSubtree(path, root: root)
                        membershipChanged = membershipChanged || removed
                    }
                }
            }
        }
        if membershipChanged { updateCanonicalFiles() }
        return membershipChanged
    }

    func entries(in root: URL) -> [Entry] { Array(files[root.path, default: [:]].values) }
    func isReadable(_ root: URL) -> Bool { readableRoots.contains(root.path) }
    func enumerationFailed(_ root: URL) -> Bool { failedRoots.contains(root.path) }
    func containsFile(_ path: String) -> Bool { canonicalFiles.contains(path) }
    func requiresSignatureCheck(_ path: String) -> Bool {
        fullyRefreshed || changedPaths.contains(path) || changedPaths.contains { path.hasPrefix($0 + "/") }
    }

    private func rebuild(_ root: URL) {
        files[root.path] = [:]
        readableRoots.remove(root.path)
        failedRoots.remove(root.path)
        failedPathsByRoot[root.path] = nil
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
              directory.boolValue, FileManager.default.isReadableFile(atPath: root.path) else { return }
        readableRoots.insert(root.path)
        enumerate(root, root: root)
    }

    private func updateCanonicalFiles() {
        canonicalFiles = Set(files.values.flatMap { $0.values.map { $0.url.path } })
    }

    /// Resolve directory aliases while preserving the final filename as the
    /// inventory identity. Walking to an existing ancestor also handles deletes.
    private static func sourcePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/" else { return url.path }
        var ancestor = url.deletingLastPathComponent()
        var missing = [url.lastPathComponent]
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.path
    }

    private func normalizedSourcePath(_ path: String) -> String {
        let resolved = Self.sourcePath(path)
        let dataVolumePrefix = "/System/Volumes/Data"
        if resolved.hasPrefix(dataVolumePrefix + "/") {
            let publicPath = String(resolved.dropFirst(dataVolumePrefix.count))
            if roots.contains(where: { publicPath == $0.path || publicPath.hasPrefix($0.path + "/")
                || $0.path.hasPrefix(publicPath + "/") }) { return publicPath }
        }
        return resolved
    }

    private func enumerate(_ directory: URL, root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [], errorHandler: { [self] failedURL, _ in
                failedRoots.insert(root.path)
                failedPathsByRoot[root.path, default: []].insert(normalizedSourcePath(failedURL.path))
                return true
            }
        ) else {
            failedRoots.insert(root.path)
            failedPathsByRoot[root.path, default: []].insert(normalizedSourcePath(directory.path))
            return
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "subagents" { enumerator.skipDescendants(); continue }
            if let entry = entry(at: url) { files[root.path, default: [:]][Self.sourcePath(url.path)] = entry }
        }
    }

    private func entry(at url: URL) -> Entry? {
        guard url.pathExtension.lowercased() == "jsonl" else { return nil }
        metadataReads += 1
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard !canonical.pathComponents.contains("subagents"),
              let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize,
              let modifiedAt = values.contentModificationDate else { return nil }
        return Entry(url: canonical, size: size, modifiedAt: modifiedAt)
    }

    @discardableResult
    private func removeSubtree(_ path: String, root: URL) -> Bool {
        guard var entries = files[root.path] else { return false }
        let matching = entries.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
        for key in matching {
            if let removed = entries.removeValue(forKey: key) { changedPaths.insert(removed.url.path) }
        }
        files[root.path] = entries
        return !matching.isEmpty
    }
}

/// FSEvents callbacks only enqueue paths; parsing remains on the collector actor.
private final class RuntimeFSEventMonitor: RuntimeFileChangeMonitoring, @unchecked Sendable {
    private static let maximumPendingPaths = 8_192
    private final class Pending: @unchecked Sendable {
        let lock = NSLock()
        var paths = Set<String>()
        var recovery = false
        var rootPrefixes: [String] = []
    }
    private let pending = Pending()
    private let queue = DispatchQueue(label: "com.agentpulse.runtime-file-events", qos: .utility)
    private var stream: FSEventStreamRef?

    init(roots: [URL]) throws {
        // FSEvents may spell boot-volume paths through the public /var, /tmp
        // aliases or the Data-volume mount. Compute lexical prefixes once;
        // callbacks perform no filesystem resolution and reject unrelated writes.
        let systemAliases = [("/private/var", "/var"), ("/private/tmp", "/tmp"), ("/private/etc", "/etc")]
        let dataVolumePrefix = "/System/Volumes/Data"
        var prefixes = Set(roots.map(\.path))
        for root in roots {
            for (canonical, alias) in systemAliases {
                if root.path == canonical || root.path.hasPrefix(canonical + "/") {
                    prefixes.insert(alias + root.path.dropFirst(canonical.count))
                } else if root.path == alias || root.path.hasPrefix(alias + "/") {
                    prefixes.insert(canonical + root.path.dropFirst(alias.count))
                }
            }
        }
        for path in Array(prefixes) {
            if path.hasPrefix(dataVolumePrefix + "/") {
                prefixes.insert(String(path.dropFirst(dataVolumePrefix.count)))
            } else {
                prefixes.insert(dataVolumePrefix + path)
            }
        }
        pending.rootPrefixes = Array(prefixes)
        // Watching the nearest existing ancestor also discovers a missing root
        // when it is created later. Collector-side root filtering limits scope.
        let watchPaths = Set(roots.map { root in
            var candidate = root.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
                candidate.deleteLastPathComponent()
            }
            return candidate.path
        })
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(pending).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Pending>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<Pending>.fromOpaque(info).release() }
            }, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let pending = Unmanaged<Pending>.fromOpaque(info).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            pending.lock.withLock {
                for index in 0..<count {
                    let path = String(cString: paths[index])
                    let relevant = pending.rootPrefixes.contains {
                        path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
                    }
                    let streamRecoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
                    let pathRecoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagRootChanged)
                    if flags[index] & streamRecoveryFlags != 0
                        || (relevant && flags[index] & pathRecoveryFlags != 0) { pending.recovery = true }
                    guard relevant else { continue }
                    let directory = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                    let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
                        | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagItemInodeMetaMod)
                    if directory && flags[index] & structural == 0 { continue }
                    if !pending.recovery {
                        pending.paths.insert(path)
                        if pending.paths.count > RuntimeFSEventMonitor.maximumPendingPaths {
                            pending.paths.removeAll(keepingCapacity: true)
                            pending.recovery = true
                        }
                    }
                }
            }
        }, &context, Array(watchPaths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                throw MonitoringError.cannotStart
            }
        } else {
            throw MonitoringError.cannotCreate
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func takeChanges() -> RuntimeFileChanges {
        pending.lock.withLock {
            let result = RuntimeFileChanges(paths: pending.paths,
                                            requiresFullRescan: pending.recovery)
            pending.paths.removeAll(keepingCapacity: true)
            pending.recovery = false
            return result
        }
    }

    private enum MonitoringError: Error { case cannotCreate, cannotStart }
}
