import Foundation
import Testing

@testable import CrucibleCore

private actor Probe {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var finished = 0

    func began() { started += 1 }
    func wasCancelled() { cancelled += 1 }
    func completed() { finished += 1 }

    func wait(started wantedStarts: Int? = nil, cancelled wantedCancels: Int? = nil) async {
        for _ in 0..<400 {
            let startsReached = wantedStarts.map { started >= $0 } ?? true
            let cancelsReached = wantedCancels.map { cancelled >= $0 } ?? true
            if startsReached && cancelsReached { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func operation(_ probe: Probe, value: Int, duration: Duration) -> @Sendable () async -> Int? {
    {
        await probe.began()
        do {
            try await Task.sleep(for: duration)
        } catch {
            await probe.wasCancelled()
            return nil
        }
        await probe.completed()
        return value
    }
}

struct InFlightCoalescerTests {
    @Test func overlappingRequestsShareOneOperation() async {
        let coalescer = InFlightCoalescer<String, Int>()
        let probe = Probe()
        let first = Task { await coalescer.value(for: "poster", operation: operation(probe, value: 7, duration: .milliseconds(150))) }
        await probe.wait(started: 1)
        let second = Task { await coalescer.value(for: "poster", operation: operation(probe, value: 99, duration: .milliseconds(150))) }
        #expect(await first.value == 7)
        #expect(await second.value == 7)
        #expect(await probe.started == 1)
    }

    @Test func requestAfterCompletionStartsANewOperation() async {
        let coalescer = InFlightCoalescer<String, Int>()
        let probe = Probe()
        #expect(await coalescer.value(for: "a", operation: operation(probe, value: 1, duration: .milliseconds(10))) == 1)
        #expect(await coalescer.value(for: "a", operation: operation(probe, value: 2, duration: .milliseconds(10))) == 2)
        #expect(await probe.started == 2)
        #expect(await coalescer.inFlightCount == 0)
    }

    @Test func cancellingTheLastWaiterCancelsTheOperation() async {
        let coalescer = InFlightCoalescer<String, Int>()
        let probe = Probe()
        let waiter = Task { await coalescer.value(for: "poster", operation: operation(probe, value: 1, duration: .seconds(30))) }
        await probe.wait(started: 1)
        waiter.cancel()
        await probe.wait(cancelled: 1)
        #expect(await probe.cancelled == 1)
        #expect(await probe.finished == 0)
        #expect(await coalescer.inFlightCount == 0)
    }

    @Test func cancellingOneOfTwoWaitersKeepsTheOperationRunning() async {
        let coalescer = InFlightCoalescer<String, Int>()
        let probe = Probe()
        let first = Task { await coalescer.value(for: "poster", operation: operation(probe, value: 5, duration: .milliseconds(300))) }
        await probe.wait(started: 1)
        let second = Task { await coalescer.value(for: "poster", operation: operation(probe, value: 5, duration: .milliseconds(300))) }
        try? await Task.sleep(for: .milliseconds(30))
        first.cancel()
        #expect(await second.value == 5)
        #expect(await probe.cancelled == 0)
        #expect(await probe.started == 1)
    }

    @Test func cancelAllStopsEverythingInFlight() async {
        let coalescer = InFlightCoalescer<String, Int>()
        let probe = Probe()
        let one = Task { await coalescer.value(for: "a", operation: operation(probe, value: 1, duration: .seconds(30))) }
        let two = Task { await coalescer.value(for: "b", operation: operation(probe, value: 2, duration: .seconds(30))) }
        await probe.wait(started: 2)
        await coalescer.cancelAll()
        await probe.wait(cancelled: 2)
        #expect(await probe.cancelled == 2)
        #expect(await one.value == nil)
        #expect(await two.value == nil)
    }
}
