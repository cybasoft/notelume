import Foundation

/// Source of "something in the notes folder changed" hints. Events are only
/// hints: they may be coalesced, delayed or missed, so callers must reconcile
/// the directory rather than trusting them as a change log (requirements §10).
public protocol DirectoryChangeMonitor: AnyObject, Sendable {
    func start()
    func stop()
}

#if os(macOS)
import CoreServices

public final class DirectoryWatcher: DirectoryChangeMonitor, @unchecked Sendable {
    private let path: String
    private let latency: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "notelume.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(directory: URL, latency: TimeInterval = 0.75, handler: @escaping @Sendable () -> Void) {
        self.path = directory.path
        self.latency = latency
        self.handler = handler
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler()
            }
            let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit { stop() }
}
#endif
