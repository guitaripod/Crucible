import CKiln
import Glibc

/// The main thread's run loop: one `poll` over every file descriptor Kiln listens to. libdispatch's main queue is one of
/// them, drained through the hooks CoreFoundation's run loop uses, so `@MainActor` work runs on this loop.
@MainActor
public final class EventLoop {
    public typealias Handler = @MainActor (_ readable: Bool) -> Void

    private struct Source {
        let fd: Int32
        let events: Int16
        let handler: Handler
    }

    private var sources: [Source] = [] { didSet { descriptors = sources.map { pollfd(fd: $0.fd, events: $0.events, revents: 0) } } }
    private var descriptors: [pollfd] = []
    private var turnEnds: [@MainActor () -> Void] = []
    private var stopRequested = false

    public init() {
        let queue = kiln_dispatch_main_queue_handle()
        add(fd: queue) { readable in
            if readable { kiln_dispatch_drain_main_queue() }
        }
    }

    public func add(fd: Int32, handler: @escaping Handler) {
        sources.append(Source(fd: fd, events: Int16(POLLIN), handler: handler))
    }

    /// Listens for urgent data on `fd` (POLLPRI), as pressure-stall triggers signal.
    public func add(urgentFD fd: Int32, handler: @escaping Handler) {
        sources.append(Source(fd: fd, events: Int16(POLLPRI), handler: handler))
    }

    /// Runs `handler` after every turn's sources, so work queued while handling them (a frame to draw) sees all of it.
    public func atEndOfEachTurn(_ handler: @escaping @MainActor () -> Void) {
        turnEnds.append(handler)
    }

    public func remove(fd: Int32) {
        sources.removeAll { $0.fd == fd }
    }

    public func stop() {
        stopRequested = true
    }

    /// Waits up to `timeoutMilliseconds` for any source and runs the handlers of those that became readable; a handler
    /// with nothing to read still runs once per turn so it can flush what it queued.
    public func runOnce(timeoutMilliseconds: Int32) {
        for index in descriptors.indices { descriptors[index].revents = 0 }
        let ready = poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds)
        let snapshot = sources
        let events = descriptors
        for (index, source) in snapshot.enumerated() {
            let readable = ready > 0 && index < events.count && (events[index].revents & source.events) != 0
            source.handler(readable)
        }
        for handler in turnEnds { handler() }
    }

    /// Turns until `finished` says so. Everything that changes the app arrives on a source (input, the display, the main
    /// queue that timers, tasks and `asyncAfter` run on, mpv's wakeups), so the loop sleeps until one of them is ready;
    /// `timeoutMilliseconds` only bounds how long a `finished` that depends on the clock goes unchecked, and how long a
    /// D-Bus connection waits to process its own timeouts. A 16 ms turn kept the CPU waking 60 times a second while
    /// nothing happened.
    public func run(timeoutMilliseconds: Int32 = 1000, until finished: @MainActor () -> Bool) {
        stopRequested = false
        while !stopRequested && !finished() {
            runOnce(timeoutMilliseconds: timeoutMilliseconds)
        }
    }
}
