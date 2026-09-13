import Foundation

struct CheckFailure: LocalizedError {
    let message: String
    let file: String
    let line: UInt

    var errorDescription: String? { "\(file):\(line): \(message)" }
}

func expect(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String = "Expected condition to be true",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard try condition() else {
        throw CheckFailure(message: message, file: String(describing: file), line: line)
    }
}

func expectThrows(
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) throws {
    do { try operation() } catch { return }
    throw CheckFailure(message: "Expected an error, but the operation succeeded",
                       file: String(describing: file), line: line)
}

func expectThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) throws {
    let actual: Error
    do {
        try operation()
    } catch {
        actual = error
        try expect(actual as? E == expected, "Expected \(expected), received \(actual)",
                   file: file, line: line)
        return
    }
    throw CheckFailure(message: "Expected \(expected), but the operation succeeded",
                       file: String(describing: file), line: line)
}

/// The missing-error failure is thrown outside the catch, so it cannot satisfy the check.
func captureError(
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async throws -> Error {
    do { try await operation() } catch { return error }
    throw CheckFailure(message: "Expected an error, but the operation succeeded",
                       file: String(describing: file), line: line)
}

@main
struct TestMain {
    static func main() async {
        let core = QuotaSnapshotTests()
        let connection = CodexConnectionTests()
        let checks: [(String, () async throws -> Void)] = [
            ("weekly window in primary", { try core.testWeeklyWindowMayBePrimary() }),
            ("weekly secondary and map precedence", { try core.testWeeklyWindowMayBeSecondaryAndMapTakesPrecedence() }),
            ("unrelated map blocks legacy fallback", { try core.testUnrelatedMapBucketDoesNotFallBackToLegacy() }),
            ("empty or null map allows legacy fallback", { try core.testEmptyOrNullMapAllowsLegacyFallback() }),
            ("missing duration is not guessed", { try core.testMissingDurationDoesNotGuessAWeeklyWindow() }),
            ("ambiguous weekly windows rejected", { try core.testAmbiguousWeeklyWindowsAreRejected() }),
            ("remaining percentage clamps", { try core.testRemainingPercentageClampsOutOfBoundsInput() }),
            ("invalid numeric values rejected", { try core.testInvalidNumericValuesAreRejected() }),
            ("malformed JSON and shapes rejected", { try core.testMalformedShapesAndJSONAreRejected() }),
            ("expiry and freshness boundaries", { try core.testExpiryAndFreshnessBoundaries() }),
            ("remaining time clamps", { try core.testTimeFractionClampsResetBeyondAFullWindow() }),
            ("snapshot Codable round trip", { try core.testSnapshotCodableRoundTrip() }),
            ("fragmented RPC and notifications", { try await connection.fragmentedResponsesAndNotificationsStillProduceWeeklySnapshot() }),
            ("numeric RPC error preserves privacy", { try await connection.rpcErrorRetainsNumericCodeWithoutRawMessage() }),
            ("timeout then reconnect", { try await connection.timeoutDiscardsOldStreamAndNextReadReconnects() }),
            ("disconnect then reconnect", { try await connection.childDisconnectFailsReadAndNextReadReconnects() }),
            ("invalid and changed accounts rejected", { try await connection.invalidAndChangedAccountsDoNotReturnQuota() }),
            ("stop resolves pending read promptly", { try await connection.stopFailsPendingReadPromptly() }),
            ("concurrent reads share one request", { try await connection.concurrentReadsShareOneQuotaRequest() }),
            ("account switch invalidates before quota failure", { try await connection.accountSwitchBetweenRefreshesIsReportedBeforeQuotaFailure() })
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error.localizedDescription)")
            }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures != 0 { exit(1) }
    }
}
