import Foundation

/// Moving an existing model cache out of `~/Documents` (gh#34).
///
/// Deliberately a command the user runs, never something warm-up does behind
/// their back: on an iCloud-synced Documents folder a plain `mv` of the cache
/// hangs for minutes, because every evicted file has to be pulled down from
/// iCloud before it can be moved, with nothing on screen to say so.
///
/// So we copy file by file: ask iCloud for each dataless file explicitly, wait
/// for it with a timeout rather than blocking forever inside `copyItem`, and
/// report progress as we go. The old copy is removed only after every file has
/// been verified at the destination.
enum CacheMigration {
    struct Item {
        let source: URL
        let destination: URL
        /// Path relative to the cache root, for progress lines.
        let relativePath: String
        let size: Int64
        /// iCloud has evicted the contents; reading it forces a download.
        let evicted: Bool
    }

    struct Plan {
        let source: URL
        let destination: URL
        let items: [Item]

        var isEmpty: Bool { items.isEmpty }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var evictedCount: Int { items.filter(\.evicted).count }
    }

    enum Failure: Error, CustomStringConvertible {
        case materializeTimedOut(URL)
        case verificationFailed(URL)

        var description: String {
            switch self {
            case .materializeTimedOut(let url):
                return """
                    timed out waiting for iCloud to download \(url.lastPathComponent).
                    Nothing was deleted — check your network and re-run `parrot models migrate`.
                    """
            case .verificationFailed(let url):
                return """
                    \(url.lastPathComponent) did not copy across intact.
                    The old cache was left in place; re-run `parrot models migrate`.
                    """
            }
        }
    }

    /// Every file under the legacy cache, with its destination under the new
    /// base. The whole tree moves — model weights and the tokenizer repos
    /// beside them — so a migrated install never has half its cache in each
    /// place.
    static func plan(
        source: URL = ModelCache.documentsBase,
        destination: URL = ModelCache.applicationSupportBase
    ) -> Plan {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let walker = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: keys
        ) else {
            return Plan(source: source, destination: destination, items: [])
        }
        var items: [Item] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let relative = relativePath(of: file, under: source)
            items.append(Item(
                source: file,
                destination: destination.appendingPathComponent(relative),
                relativePath: relative,
                size: Int64(values?.fileSize ?? 0),
                evicted: values?.ubiquitousItemDownloadingStatus == .notDownloaded
            ))
        }
        return Plan(source: source, destination: destination, items: items.sorted { $0.relativePath < $1.relativePath })
    }

    /// Copies every planned file, then — unless `keepOld` — removes the legacy
    /// tree. Progress goes to stderr; `\r`-overwritten, like the download bar.
    static func run(_ plan: Plan, keepOld: Bool = false) throws {
        var copied: Int64 = 0
        let progress = ProgressReporter(totalBytes: plan.totalBytes)
        for item in plan.items {
            if item.evicted {
                progress.note("materialising \(item.relativePath)")
                try materialize(item.source)
            }
            try FileManager.default.createDirectory(
                at: item.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: item.destination.path) {
                // A previous run got this far; only re-copy a short file.
                if fileSize(item.destination) == item.size {
                    copied += item.size
                    progress.update(copied, item.relativePath)
                    continue
                }
                try FileManager.default.removeItem(at: item.destination)
            }
            try FileManager.default.copyItem(at: item.source, to: item.destination)
            copied += item.size
            progress.update(copied, item.relativePath)
        }
        progress.finish()

        for item in plan.items where fileSize(item.destination) != item.size {
            throw Failure.verificationFailed(item.destination)
        }
        guard !keepOld else { return }
        try FileManager.default.removeItem(at: plan.source)
    }

    /// Ask iCloud for a dataless file and wait for it, rather than letting the
    /// first read block indefinitely inside the kernel.
    private static func materialize(_ url: URL, timeout: TimeInterval = 300) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus != .notDownloaded { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Failure.materializeTimedOut(url)
    }

    /// Via FileManager rather than `URL.resourceValues`, which caches what it
    /// read on the URL — the same URL is asked twice per file here, once
    /// before the copy and once to verify it, and a stale answer would report
    /// a good copy as a failure.
    private static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    static func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    /// Same `\r` discipline as the download bar: throttled, and it clears the
    /// line before printing anything the user should keep.
    private final class ProgressReporter {
        private let totalBytes: Int64
        private var lastWrite = Date.distantPast
        private var lastPercent = -1

        init(totalBytes: Int64) {
            self.totalBytes = totalBytes
        }

        func update(_ copiedBytes: Int64, _ label: String) {
            let percent = totalBytes > 0 ? Int(Double(copiedBytes) / Double(totalBytes) * 100) : 100
            let now = Date()
            guard percent != lastPercent, now.timeIntervalSince(lastWrite) > 0.2 || percent == 100 else {
                return
            }
            lastWrite = now
            lastPercent = percent
            let width = 25
            let filled = min(max(percent, 0), 100) * width / 100
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: width - filled)
            write("\r→ \(bar) \(percent)%  \(CacheMigration.formatBytes(copiedBytes))")
        }

        /// For the slow steps — an evicted file can take a while, and a frozen
        /// percentage with no explanation is exactly the hang we're fixing.
        func note(_ message: String) {
            clear()
            write("  \(message)\n")
            lastPercent = -1
        }

        func finish() {
            clear()
        }

        private func clear() {
            write("\r" + String(repeating: " ", count: 72) + "\r")
        }

        private func write(_ s: String) {
            FileHandle.standardError.write(Data(s.utf8))
        }
    }
}
