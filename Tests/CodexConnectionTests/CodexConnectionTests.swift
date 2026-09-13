import Foundation
import CodexConnection

struct CodexConnectionTests {
    private struct Fixture {
        let directory: URL
        let executable: URL
        var marker: URL { directory.appendingPathComponent("quota-reached") }
    }

    private func fixture(_ scenario: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-quota-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time
        from pathlib import Path

        scenario = "\(scenario)"
        directory = Path(__file__).parent
        marker = directory / "quota-reached"
        first_attempt = directory / "first-attempt"
        account_reads = 0
        quota_reads = 0

        def send(message):
            data = (json.dumps(message) + "\\n").encode()
            if scenario == "fragmented":
                # Split within JSON tokens and leave the newline in its own write.
                for piece in [data[:7], data[7:-1], data[-1:]]:
                    os.write(1, piece)
            else:
                os.write(1, data)

        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"userAgent": "fake-codex"}
            elif method == "account/read":
                account_reads += 1
                account = {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "plus"}
                if scenario == "anonymous-account":
                    account = {"type": "chatgpt", "planType": "plus"}
                elif scenario == "null-account":
                    account = None
                elif scenario == "api-key-account":
                    account = {"type": "apiKey"}
                elif scenario == "account-change" and account_reads > 1:
                    account["email"] = "other-fixture@example.invalid"
                elif scenario == "between-refresh-account-change" and account_reads >= 3:
                    account["email"] = "other-fixture@example.invalid"
                result = {"account": account}
            elif method == "account/rateLimits/read":
                quota_reads += 1
                marker.touch()
                with (directory / "quota-count").open("a") as counts:
                    counts.write("read\\n")
                if scenario == "remote-error" or (scenario == "between-refresh-account-change" and quota_reads >= 2):
                    send({"id": request["id"], "error": {"code": -32001, "message": "DO_NOT_SURFACE_RAW_SERVER_TEXT"}})
                    continue
                if scenario in ["timeout-reconnect", "disconnect-reconnect"] and not first_attempt.exists():
                    first_attempt.touch()
                    if scenario == "disconnect-reconnect":
                        os._exit(0)
                    time.sleep(30)
                    continue
                if scenario == "pending-stop":
                    time.sleep(30)
                    continue
                result = {"rateLimitsByLimitId": {"codex": {
                    "primary": {"usedPercent": 8, "windowDurationMins": 300},
                    "secondary": {"usedPercent": 37.5, "windowDurationMins": 10080,
                                  "resetsAt": int(time.time()) + 302400}}}}
                result["rateLimitResetCredits"] = {"availableCount": 3, "credits": [
                    {"id": "fixture-credit", "resetType": "codexRateLimits", "status": "available",
                     "grantedAt": int(time.time()) - 100, "expiresAt": int(time.time()) + 100}]}
            else:
                send({"id": request["id"], "error": {"code": -32601, "message": "Unexpected method"}})
                continue
            if scenario == "fragmented":
                # Notifications and unrelated IDs must not resolve the pending request.
                os.write(1, b'{"method":"test/notification","params":{}}\\n{"id":999999,"result":{}}\\n')
            send({"id": request["id"], "result": result})
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(directory: directory, executable: executable)
    }

    private func withConnection(
        _ scenario: String,
        timeout: Double = 5,
        operation: (Fixture, CodexConnection) async throws -> Void
    ) async throws {
        let fixture = try fixture(scenario)
        let connection = CodexConnection(executable: fixture.executable, timeoutSeconds: timeout)
        do {
            try await operation(fixture, connection)
            await connection.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await connection.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    func fragmentedResponsesAndNotificationsStillProduceWeeklySnapshot() async throws {
        try await withConnection("fragmented") { _, connection in
            let snapshot = try await connection.readWeekly()
            try expect(snapshot.usedPercent == 37.5)
            try expect(snapshot.remainingPercent == 62.5)
            try expect(snapshot.windowDurationMins == 10_080)
            try expect(snapshot.resetsAt != nil)
            try expect(!snapshot.isStale(at: Date()))
        }
    }

    func accountDigestIsStableAndOpaque() async throws {
        try await withConnection("fragmented") { _, connection in
            let first = try await connection.readUsage()
            let second = try await connection.readUsage()
            try expect(first.accountKey == second.accountKey)
            try expect(first.accountKey?.count == 64)
            try expect(first.accountKey?.allSatisfy { $0.isHexDigit } == true)
            try expect(first.accountKey?.contains("fixture") == false)
        }
    }

    func missingIdentityDoesNotCreateSharedHistoryKey() async throws {
        try await withConnection("anonymous-account") { _, connection in
            let usage = try await connection.readUsage()
            try expect(usage.weekly.usedPercent == 37.5)
            try expect(usage.accountKey == nil)
        }
    }

    func rpcErrorRetainsNumericCodeWithoutRawMessage() async throws {
        try await withConnection("remote-error") { _, connection in
            let error = try await captureError {
                _ = try await connection.readWeekly()
            }
            try expect(error as? ConnectionError == .remote(-32001))
            try expect(error.localizedDescription.contains("-32001"))
            try expect(!error.localizedDescription.contains("DO_NOT_SURFACE_RAW_SERVER_TEXT"))
        }
    }

    func timeoutDiscardsOldStreamAndNextReadReconnects() async throws {
        try await withConnection("timeout-reconnect", timeout: 1) { fixture, connection in
            let error = try await captureError {
                _ = try await connection.readWeekly()
            }
            try expect(error as? ConnectionError == .timedOut)
            try expect(FileManager.default.fileExists(atPath: fixture.marker.path),
                    "The fake server must reach the quota read before timing out")
            let snapshot = try await connection.readWeekly()
            try expect(snapshot.usedPercent == 37.5)
        }
    }

    func childDisconnectFailsReadAndNextReadReconnects() async throws {
        try await withConnection("disconnect-reconnect") { _, connection in
            let error = try await captureError {
                _ = try await connection.readWeekly()
            }
            try expect(error as? ConnectionError == .disconnected)
            let snapshot = try await connection.readWeekly()
            try expect(snapshot.usedPercent == 37.5)
        }
    }

    func invalidAndChangedAccountsDoNotReturnQuota() async throws {
        for scenario in ["null-account", "api-key-account", "account-change"] {
            try await withConnection(scenario) { fixture, connection in
                let error = try await captureError {
                    _ = try await connection.readUsage()
                }
                let expected: ConnectionError = scenario == "account-change" ? .accountChanged : .signInRequired
                try expect(error as? ConnectionError == expected)
                if scenario != "account-change" {
                    try expect(!FileManager.default.fileExists(atPath: fixture.marker.path),
                            "Invalid accounts must be rejected before requesting quota")
                }
            }
        }
    }

    func stopFailsPendingReadPromptly() async throws {
        try await withConnection("pending-stop", timeout: 10) { fixture, connection in
            let reading = Task { try await connection.readWeekly() }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: fixture.marker.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(FileManager.default.fileExists(atPath: fixture.marker.path),
                    "The read must be pending before stop is tested")
            let stoppedAt = Date()
            await connection.stop()
            let error = try await captureError {
                _ = try await reading.value
            }
            try expect(error as? ConnectionError == .disconnected)
            try expect(Date().timeIntervalSince(stoppedAt) < 1,
                    "Stopping should resolve pending requests without waiting for their timeout")
        }
    }
    func concurrentReadsShareOneQuotaRequest() async throws {
        try await withConnection("fragmented") { fixture, connection in
            async let first = connection.readWeekly()
            async let second = connection.readUsage()
            let (firstSnapshot, secondSnapshot) = try await (first, second)
            try expect(firstSnapshot == secondSnapshot.weekly,
                       "Concurrent weekly and aggregate reads should receive the same coalesced snapshot")
            try expect(secondSnapshot.resetCredits?.availableCount == 3)
            try expect(secondSnapshot.resetCredits?.availableCredits.count == 1)
            try expect(secondSnapshot.resetCredits?.fetchedAt == firstSnapshot.fetchedAt)
            let requests = try String(contentsOf: fixture.directory.appendingPathComponent("quota-count"),
                                      encoding: .utf8)
            try expect(requests.split(separator: "\n").count == 1,
                       "Concurrent reads should issue only one quota request")
        }
    }

    func accountSwitchBetweenRefreshesIsReportedBeforeQuotaFailure() async throws {
        try await withConnection("between-refresh-account-change") { fixture, connection in
            let first = try await connection.readUsage()
            try expect(first.weekly.usedPercent == 37.5)
            try expect(first.resetCredits?.availableCount == 3)

            let changed = try await captureError { _ = try await connection.readUsage() }
            try expect(changed as? ConnectionError == .accountChanged,
                       "The first read after switching accounts must invalidate the previous reading")
            let countAfterChange = try String(
                contentsOf: fixture.directory.appendingPathComponent("quota-count"), encoding: .utf8)
            try expect(countAfterChange.split(separator: "\n").count == 1,
                       "An account change must be reported before querying the new account's quota")

            let failedQuota = try await captureError { _ = try await connection.readWeekly() }
            try expect(failedQuota as? ConnectionError == .remote(-32001),
                       "A retry must use the new account identity and expose its quota failure")
            let countAfterRetry = try String(
                contentsOf: fixture.directory.appendingPathComponent("quota-count"), encoding: .utf8)
            try expect(countAfterRetry.split(separator: "\n").count == 2,
                       "Retrying after the account-change signal should issue the new quota request")
        }
    }
}
