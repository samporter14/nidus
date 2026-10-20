import Foundation

/// Keeps the chosen file's security scope alive while Foundation observes it.
/// The callback never reads or parses data; BrickCompanion serializes those
/// reads and retains its freshness/replay checks. A recovery poll remains for
/// providers and writers that do not deliver coordinated notifications.
final class BrickFileObservation: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var location: URL
    private var isRegistered = true
    private let scopedURL: URL
    private let onChange: @Sendable () -> Void
    let presentedItemOperationQueue: OperationQueue

    var presentedItemURL: URL? {
        lock.withLock { location }
    }

    init?(bookmark: Data, onChange: @escaping @Sendable () -> Void) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        location = url
        scopedURL = url
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "local.sam.nidus.brick-observation"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    deinit { invalidate() }

    /// Explicit teardown matters even if Foundation retains a presenter.
    func invalidate() {
        let remove = lock.withLock {
            guard isRegistered else { return false }
            isRegistered = false
            return true
        }
        if remove {
            NSFileCoordinator.removeFilePresenter(self)
            scopedURL.stopAccessingSecurityScopedResource()
        }
    }

    func presentedItemDidChange() { onChange() }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { location = newURL }
        onChange()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        onChange()
    }
}
