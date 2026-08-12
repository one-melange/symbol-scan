import Testing
import Foundation
@testable import SymbolScan

/// Exercises `LlamaServer`'s lifecycle with a fake launcher + handle — the delayed-startup,
/// concurrent-start, cancellation, and termination paths that a real binary would otherwise gate.

/// A fake server handle. `terminate()` just records that it happened (no real process to wait on).
final class FakeProcessHandle: LlamaProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminated = false
    private var _alive = true

    var terminated: Bool { lock.withLock { _terminated } }

    func markDead() { lock.withLock { _alive = false } }

    var isRunning: Bool { lock.withLock { _alive } }
    func terminate() { lock.withLock { _terminated = true; _alive = false } }
}

/// Counts launcher invocations across concurrent callers.
actor LaunchCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite struct LlamaServerTests {

    private let anyURL = URL(string: "http://127.0.0.1:9999")!

    @Test func concurrentEnsureRunningLaunchesExactlyOnce() async throws {
        let counter = LaunchCounter()
        let handle = FakeProcessHandle()
        let server = LlamaServer(launch: { [anyURL] in
            await counter.bump()
            try await Task.sleep(nanoseconds: 150_000_000)   // hold both callers inside startup
            return (handle, anyURL)
        })

        async let a = server.ensureRunning()
        async let b = server.ensureRunning()
        async let c = server.ensureRunning()
        let urls = try await [a, b, c]

        #expect(urls == [anyURL, anyURL, anyURL])
        #expect(await counter.count == 1)   // coalesced — one process, not three
    }

    @Test func liveServerShortCircuitsWithoutRelaunch() async throws {
        let counter = LaunchCounter()
        let handle = FakeProcessHandle()
        let server = LlamaServer(launch: { [anyURL] in
            await counter.bump()
            return (handle, anyURL)
        })
        _ = try await server.ensureRunning()
        _ = try await server.ensureRunning()
        _ = try await server.ensureRunning()
        #expect(await counter.count == 1)   // reused, not relaunched
    }

    @Test func deadHandleTriggersRelaunch() async throws {
        let counter = LaunchCounter()
        let handle = FakeProcessHandle()
        let server = LlamaServer(launch: { [anyURL] in
            await counter.bump()
            return (handle, anyURL)
        })
        _ = try await server.ensureRunning()
        handle.markDead()                    // process died out from under us
        _ = try await server.ensureRunning()
        #expect(await counter.count == 2)
    }

    @Test func shutdownTerminatesRunningServer() async throws {
        let handle = FakeProcessHandle()
        let server = LlamaServer(launch: { [anyURL] in (handle, anyURL) })
        _ = try await server.ensureRunning()
        await server.shutdown()
        #expect(handle.terminated == true)
    }

    @Test func shutdownCancelsInFlightStartupAndCleansUp() async throws {
        let handle = FakeProcessHandle()
        let server = LlamaServer(launch: { [anyURL] in
            // A cancellation-aware launcher that terminates the child it spawned on abort — the
            // contract the real launcher upholds in its catch block.
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                handle.terminate()
                throw error
            }
            return (handle, anyURL)
        })

        let starter = Task { try await server.ensureRunning() }
        try await Task.sleep(nanoseconds: 100_000_000)   // let startup begin
        await server.shutdown()                          // cancels the in-flight start
        _ = try? await starter.value

        #expect(handle.terminated == true)               // no orphaned child
    }

    @Test func failedStartupIsRetryable() async throws {
        let counter = LaunchCounter()
        let good = FakeProcessHandle()
        // Fail the first launch, succeed the second.
        let server = LlamaServer(launch: { [anyURL] in
            let n = await counter.count
            await counter.bump()
            if n == 0 { throw LLMError.serverFailedToStart("boom") }
            return (good, anyURL)
        })

        await #expect(throws: LLMError.self) { _ = try await server.ensureRunning() }
        let url = try await server.ensureRunning()       // startup was cleared → retry works
        #expect(url == anyURL)
        #expect(await counter.count == 2)
    }
}
