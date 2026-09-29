import Foundation

/// Tells its owner when a project package changes on disk, whoever changed it: another app, an agent, a sync
/// client, a git checkout. It listens to the kernel's file system events for the package folder, its manifest and
/// its images folder, so there is no polling and no dependency on the writer using file coordination (which
/// `NSFilePresenter` needs and most other writers skip). Events are coalesced, and the handler runs on the main actor.
///
/// A package is replaced atomically by renaming a sibling over it, which retires the file descriptors being watched;
/// every event therefore re-arms the watch by path, so the new package is watched after the swap.
@MainActor
final class ProjectWatcher {
    let url: URL
    private let onChange: @MainActor () -> Void
    private let sources = SourceBox()
    private var delivery: Task<Void, Never>?
    private var rearm: Task<Void, Never>?
    /// How long to wait after the last event before reporting, so a save that touches several files reports once.
    static let coalescing: Duration = .milliseconds(300)

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { sources.cancelAll() }

    func stop() {
        delivery?.cancel(); delivery = nil
        rearm?.cancel(); rearm = nil
        sources.cancelAll()
    }

    private var watchedPaths: [String] {
        [url.path, url.appendingPathComponent("manifest.json").path, url.appendingPathComponent("images", isDirectory: true).path]
    }

    private func arm() {
        sources.cancelAll()
        for path in watchedPaths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .link, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.noteEvent() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    /// The dispatch sources, kept outside the actor so `deinit` can cancel them from any context.
    private nonisolated final class SourceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [DispatchSourceFileSystemObject] = []
        var count: Int { lock.withLock { list.count } }
        func append(_ source: DispatchSourceFileSystemObject) { lock.withLock { list.append(source) } }
        func cancelAll() {
            let cancelled = lock.withLock { let l = list; list.removeAll(); return l }
            for source in cancelled { source.cancel() }
        }
    }

    private func noteEvent() {
        // Re-arm by path once the writer has finished swapping files, retrying briefly while the package
        // is mid-replacement and a path does not exist yet.
        rearm?.cancel()
        rearm = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.arm()
                if self.sources.count == self.watchedPaths.count { return }
            }
        }
        delivery?.cancel()
        delivery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescing)
            guard let self, !Task.isCancelled else { return }
            self.onChange()
        }
    }
}
