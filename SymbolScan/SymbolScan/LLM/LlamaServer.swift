import Foundation

// MARK: - Locating the runtime + weights

/// Resolves where the `llama-server` binary and the GGUF model live. Pure path logic (Bundle +
/// FileManager, no process), split out so it's inspectable and the server actor stays about
/// lifecycle. `binaryURL()`/`modelURL()` return nil when the asset is absent, which the launcher
/// turns into a clear user-facing `LLMError`.
///
/// NOTE (T28 packaging): this build does not yet ship the binary or weights. The intended delivery is
/// to bundle the small `llama-server` executable as an app resource (located here via `Bundle.main`,
/// following the Tree-sitter `.bundle` resource precedent) and download the multi-GB `.gguf` on first
/// run into `defaultModelDirectory()`, with a Preferences path override for a pre-placed model. Until
/// then both lookups return nil and the picker shows "runtime isn't bundled / no model file".
enum LlamaServerLocator {

    /// The bundled server binary, or nil if this build shipped without it. Lives under
    /// `Contents/Helpers/llama/` alongside its dylibs (the "Bundle llama runtime" build phase stages
    /// it there from `scripts/fetch-llama.sh`'s output). Co-location matters: `llama-server` resolves
    /// its dylibs via `LC_RPATH=@loader_path`, i.e. its own directory.
    nonisolated static func binaryURL() -> URL? {
        let u = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/llama/llama-server")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// `~/Library/Application Support/SymbolScan/models/` — where a downloaded model is kept.
    nonisolated static func defaultModelDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SymbolScan/models", isDirectory: true)
    }

    /// The resolved model file, honoring override-then-default precedence. Thin wrapper over
    /// `resolveModel` so **launch and provisioning share one resolver** and never disagree about which
    /// file counts.
    nonisolated static func modelURL() -> URL? {
        resolveModel(override: LLMPreferences.modelPathOverride,
                     defaultModel: defaultModelDirectory().appendingPathComponent(LLMPreferences.defaultModelFileName))
    }

    /// Pure resolution: a valid (existing) override wins; otherwise the default model if present;
    /// otherwise nil. Crucially, a nonempty-but-**missing** override *falls through* to the default —
    /// without this, launch returned nil for a stale override even after the default had downloaded,
    /// so ⌘E failed with "no model file found" despite a ready model.
    nonisolated static func resolveModel(override: String?, defaultModel: URL) -> URL? {
        if let override, !override.isEmpty, FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.fileExists(atPath: defaultModel.path) ? defaultModel : nil
    }
}

// MARK: - Process handle abstraction

/// A terminable, liveness-checkable server handle. Abstracted from `Process` so the lifecycle logic
/// in `LlamaServer` (start coalescing, cancellation cleanup, shutdown) can be unit-tested with a fake
/// handle — the reviewer's point that the real paths (delayed startup, cancellation, termination) go
/// otherwise untested. `Sendable` so it can be stored across the actor and returned from a launcher.
protocol LlamaProcessHandle: Sendable {
    var isRunning: Bool { get }
    /// Terminate the process and block until it has actually exited (so the port is freed and no child
    /// outlives the app). Idempotent.
    func terminate()
}

/// The real `Process`-backed handle. `@unchecked Sendable`: `Process` isn't `Sendable`, but every
/// access here is confined to the owning actor / the launcher that created it, so there is no shared
/// mutable access. `llama-server` exits cleanly on SIGTERM, so `terminate()` + `waitUntilExit()` is a
/// bounded, orphan-free stop.
final class LlamaProcessHandleImpl: LlamaProcessHandle, @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }

    nonisolated var isRunning: Bool { process.isRunning }

    nonisolated func terminate() {
        guard process.isRunning else { return }
        process.terminate()        // SIGTERM — llama-server handles it and exits
        process.waitUntilExit()    // wait so the child is truly gone before we return
    }
}

// MARK: - Server process lifecycle

/// Owns a long-lived `llama-server` child process. An `actor` because it guards mutable process
/// state. Reuses the deadlock-safe `Process` handling proven in `RepoScanner` (the launcher sinks the
/// server's output so a chatty log never blocks it on a full pipe); the difference is that this
/// process is long-lived, so we health-poll `/health` instead of `waitUntilExit`.
///
/// **Startup is coalesced.** Actors are re-entrant at every `await`, so a naive `ensureRunning()`
/// that suspended inside a health check could be entered again and spawn a *second* server on the
/// same port, orphaning the first. Instead the in-flight startup is memoized as a single `Task`;
/// concurrent callers await that same task, so exactly one process is ever launched per start.
actor LlamaServer {
    /// Spawns the server and returns once it's healthy. Must be cancellation-aware and must terminate
    /// the process it spawned if it throws (including on cancellation), so a failed/aborted start
    /// never leaks a child. Injectable so tests can drive startup timing without a real binary.
    typealias Launcher = @Sendable () async throws -> (handle: any LlamaProcessHandle, url: URL)

    private var running: (handle: any LlamaProcessHandle, url: URL)?
    private var startup: Task<URL, Error>?
    private let launch: Launcher

    init(launch: @escaping Launcher = LlamaServer.realLaunch) {
        self.launch = launch
    }

    /// Ensure a healthy server is running and return its base URL. Idempotent and concurrency-safe:
    /// a live server short-circuits; an in-flight start is shared; only the first caller launches.
    func ensureRunning() async throws -> URL {
        if let running, running.handle.isRunning { return running.url }
        running = nil                                     // drop a dead handle before (re)starting

        if let startup { return try await startup.value } // coalesce onto the in-flight start

        let task = Task<URL, Error> {
            let (handle, url) = try await launch()
            self.running = (handle, url)                  // actor-isolated: set before we resolve
            return url
        }
        startup = task
        do {
            let url = try await task.value
            startup = nil
            return url
        } catch {
            startup = nil                                 // let the next caller retry a fresh start
            throw error
        }
    }

    /// Terminate the server and wait for it to exit. Cancels an in-flight start (whose launcher then
    /// cleans up the half-spawned child) and terminates a running one. Safe when nothing is running.
    func shutdown() async {
        startup?.cancel()
        if let startup { _ = try? await startup.value }   // let its cancellation cleanup complete
        running?.handle.terminate()
        running = nil
        startup = nil
    }

    // MARK: Real launcher

    /// The production launcher: spawn `llama-server`, then health-poll until it's ready. Terminates
    /// the child on any failure or cancellation so a stalled/aborted start never orphans a process.
    static let realLaunch: Launcher = {
        guard LLMRuntime.isSupported else {
            throw LLMError.modelUnavailable(LLMRuntime.unsupportedMessage)
        }
        guard let binary = LlamaServerLocator.binaryURL() else {
            throw LLMError.modelUnavailable("the model runtime isn't bundled with this build yet")
        }
        guard let model = LlamaServerLocator.modelURL() else {
            throw LLMError.modelUnavailable("no model file found — set a model path in Preferences or download one")
        }

        let port = LLMPreferences.serverPort
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "--model", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", "4096",
        ]
        // Sink stdout/stderr so a chatty server never blocks on a full pipe (the trap `RepoScanner`
        // documents); `nullDevice` drains it with no reader thread.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            throw LLMError.serverFailedToStart(error.localizedDescription)
        }

        let handle = LlamaProcessHandleImpl(proc)
        let url = URL(string: "http://127.0.0.1:\(port)")!
        do {
            try await waitUntilHealthy(url, handle: handle)
        } catch {
            handle.terminate()   // failed OR cancelled start → never leave an orphan on the port
            throw error
        }
        return (handle, url)
    }

    /// Poll `GET /health` until it returns 200, the process dies, or we time out. Cancellation-aware:
    /// `checkCancellation()` + a throwing `sleep` propagate an aborted start immediately instead of
    /// spinning to the deadline (the swallowed-`try?` bug), letting the launcher's cleanup run.
    private static func waitUntilHealthy(_ base: URL, handle: any LlamaProcessHandle, timeout: TimeInterval = 30) async throws {
        let healthURL = base.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if !handle.isRunning {
                throw LLMError.serverFailedToStart("the server exited on launch (check the model file and runtime)")
            }
            try await Task.sleep(nanoseconds: 300_000_000)   // throws on cancellation — intentional
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
        }
        throw LLMError.serverFailedToStart("timed out waiting for it to become ready")
    }
}

// MARK: - The v1 client

/// The concrete `LLMClient` for v1: it makes sure the managed `LlamaServer` is up, then streams the
/// completion through `OpenAIChatStream`. `Sendable` — its state is an actor plus immutable config —
/// so the `@MainActor` view model can hold it and iterate its stream. `nonisolated explain(...)`
/// returns a cold stream; the server-start + request run on a detached task.
final class LlamaServerClient: LLMClient {
    private let server: LlamaServer
    private let model: String
    private let session: URLSession

    init(server: LlamaServer = LlamaServer(),
         model: String = LLMPreferences.modelName,
         session: URLSession = .shared) {
        self.server = server
        self.model = model
        self.session = session
    }

    nonisolated func explain(_ prompt: LLMPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [server, model, session] in
                do {
                    let base = try await server.ensureRunning()
                    for try await token in OpenAIChatStream.stream(baseURL: base, model: model, prompt: prompt, session: session) {
                        try Task.checkCancellation()
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stop the underlying server and wait for it to exit. `await`-ed from `applicationShouldTerminate`
    /// so the child is gone before the app quits (a fire-and-forget `Task` during termination may
    /// never be scheduled, orphaning a multi-GB process holding the port).
    func shutdown() async {
        await server.shutdown()
    }
}
