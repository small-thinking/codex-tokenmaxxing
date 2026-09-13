import Foundation
import QuotaCore

public enum ConnectionError: LocalizedError, Equatable {
    case executableNotFound, launchFailed, disconnected, timedOut, invalidResponse
    case signInRequired, accountChanged, remote(Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Codex CLI not found. Install Codex or set its executable path."
        case .launchFailed: return "Could not start the local Codex process."
        case .disconnected: return "The local Codex connection closed. Retry to reconnect."
        case .timedOut: return "Codex did not respond in time. Retry when your connection is available."
        case .invalidResponse: return "This Codex version returned an unsupported response."
        case .signInRequired: return "Sign in to Codex with your ChatGPT account, then refresh."
        case .accountChanged: return "Your Codex account changed during refresh. Please refresh again."
        case .remote(let code): return "Codex could not read usage (error \(code)). Check your Codex login and connection."
        }
    }
}

/// Owns one child process. Only account reads are exposed; no model turns or reset writes.
public actor CodexConnection {
    private let executable: URL?
    private let timeoutNanoseconds: UInt64
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var generation = UUID()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var initialized = false
    private var reading: Task<WeeklySnapshot, Error>?
    private var readerTask: Task<Void, Never>?
    private var knownAccount: Data?

    public init(executable: URL? = nil, timeoutSeconds: Double = 20) {
        self.executable = executable
        self.timeoutNanoseconds = UInt64(max(0.01, timeoutSeconds) * 1_000_000_000)
    }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let override = UserDefaults.standard.string(forKey: "codexExecutablePath")
        let candidates = [override, ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"]].compactMap { $0 } + [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    public func readWeekly() async throws -> WeeklySnapshot {
        if let reading { return try await reading.value }
        let task = Task { try await self.performReadWeekly() }
        reading = task
        defer { reading = nil }
        return try await task.value
    }

    private func performReadWeekly() async throws -> WeeklySnapshot {
        try Task.checkCancellation()
        try await connectIfNeeded()
        // Keep account data in memory only. A second read prevents mixing a mid-refresh switch.
        let before = try accountIdentity(await request("account/read", params: ["refreshToken": false]))
        if let knownAccount, knownAccount != before {
            self.knownAccount = before
            throw ConnectionError.accountChanged
        }
        knownAccount = before
        let quota = try await request("account/rateLimits/read")
        let after = try accountIdentity(await request("account/read", params: ["refreshToken": false]))
        guard before == after else {
            knownAccount = after
            throw ConnectionError.accountChanged
        }
        return try QuotaParser.parse(data: quota, at: Date())
    }

    private func accountIdentity(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let type = account["type"] as? String,
              ["chatgpt", "chatgptAuthTokens"].contains(type) else {
            throw ConnectionError.signInRequired
        }
        return try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
    }

    private func connectIfNeeded() async throws {
        if initialized, process?.isRunning == true { return }
        resetTransport()
        guard let executable = executable ?? Self.findExecutable() else { throw ConnectionError.executableNotFound }
        let child = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.executableURL = executable
        child.arguments = ["-c", "analytics.enabled=false", "app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        child.environment = environment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errors = stderrPipe.fileHandleForReading
        process = child
        let currentGeneration = generation
        let stream = AsyncStream<Data> { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                continuation.yield(data)
                if data.isEmpty { continuation.finish() }
            }
        }
        // One consumer preserves pipe chunk order; independent Tasks can reorder fragments.
        readerTask = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(data, generation: currentGeneration)
            }
        }
        // Drain stderr so it cannot block the child. Never persist raw authentication diagnostics.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in
            Task { await self?.childExited(generation: currentGeneration) }
        }
        do { try child.run() } catch { resetTransport(); throw ConnectionError.launchFailed }
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "codex_tokenmaxxing", "title": "Codex Tokenmaxxing", "version": "0.1.0"]
            ])
            try write(["method": "initialized"])
            initialized = true
        } catch {
            resetTransport()
            throw error
        }
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw ConnectionError.disconnected }
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self, timeoutNanoseconds] in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                await self?.requestTimedOut(id)
            }
            do { try write(message) } catch { finish(id, result: .failure(ConnectionError.disconnected)) }
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw ConnectionError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, generation receivedGeneration: UUID) {
        guard receivedGeneration == generation else { return }
        guard !data.isEmpty else { resetTransport(); return }
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else { resetTransport(); return }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let id = object["id"] as? Int else { continue } // Unsolicited notifications are not cross-process guarantees.
            if let error = object["error"] as? [String: Any] {
                finish(id, result: .failure(ConnectionError.remote(error["code"] as? Int ?? -1)))
            } else if let result = object["result"], JSONSerialization.isValidJSONObject(result),
                      let encoded = try? JSONSerialization.data(withJSONObject: result) {
                finish(id, result: .success(encoded))
            } else { finish(id, result: .failure(ConnectionError.invalidResponse)) }
        }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func requestTimedOut(_ id: Int) {
        guard pending[id] != nil else { return }
        finish(id, result: .failure(ConnectionError.timedOut))
        resetTransport() // A timed-out stream must not be reused with late responses.
    }

    private func childExited(generation exitedGeneration: UUID) {
        guard exitedGeneration == generation else { return }
        resetTransport()
    }

    public func stop() {
        reading?.cancel()
        resetTransport()
    }

    private func resetTransport() {
        generation = UUID()
        initialized = false
        output?.readabilityHandler = nil
        readerTask?.cancel()
        readerTask = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        let child = process
        process = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil; output = nil; errors = nil
        buffer.removeAll(keepingCapacity: false)
        for id in Array(pending.keys) { finish(id, result: .failure(ConnectionError.disconnected)) }
        if let child, child.isRunning {
            child.terminate()
            // Only this owned Process can be killed; never touch the user's Codex host.
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
