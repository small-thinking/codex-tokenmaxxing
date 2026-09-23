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
        let tokenActivity = TokenActivityTests()
        let tokenUsage = TokenUsageTests()
        let audit = QuotaAuditTests()
        let login = LoginItemTests()
        let history = QuotaHistoryTests()
        let paceHistory = PaceHistoryTests()
        let core = QuotaSnapshotTests()
        let connection = CodexConnectionTests()
        let resets = ResetCreditTests()
        let rings = RingIconTests()
        let hourlyActivity = HourlyActivityViewTests()
        let checks: [(String, () async throws -> Void)] = [
            ("hourly chart caps extreme pace without flattening bars", { try hourlyActivity.extremePaceDoesNotFlattenHourlyBars() }),
            ("official price-equivalent token weights", { try tokenUsage.officialPriceEquivalentWeights() }),
            ("token chart hourly window and model effort grouping", { try tokenActivity.chartWindowAndModelEffortGrouping() }),
            ("token reasoning follows turns and distinct groups", { try await tokenUsage.reasoningLevelsFollowTurnsAndRemainDistinct() }),
            ("token reasoning migration preserves totals on restart", { try await tokenUsage.legacyReasoningMigrationPreservesTotalsAcrossRestart() }),
            ("token reasoning migration keeps missing or changed sources unknown", { try await tokenUsage.legacyReasoningMigrationKeepsMissingAndChangedSourcesUnknown() }),
            ("token modern counters deduplicate and preserve breakdown", { try await tokenUsage.modernCountersDeduplicateAndPreserveBreakdown() }),
            ("token restart and unchanged scan do not rewrite", { try await tokenUsage.restartAndUnchangedScanDoNotRewrite() }),
            ("token partial lines and byte budgets", { try await tokenUsage.partialLinesAndByteBudgets() }),
            ("token truncation and rotation deduplicate", { try await tokenUsage.truncationAndRotationDoNotCountDuplicates() }),
            ("token legacy invalid and model scope explicit", { try await tokenUsage.legacyInvalidAndModelScopeAreExplicit() }),
            ("token retention and discovery respect coverage", { try await tokenUsage.retentionAndDiscoveryRespectCoverage() }),
            ("token large irrelevant lines bounded progress", { try await tokenUsage.largeIrrelevantLinesMakeBoundedProgress() }),
            ("quota audit append dedup partial recovery and privacy", { try await audit.appendDeduplicationPartialRecoveryAndPrivacy() }),
            ("pace history immutable half-hour samples and reload", { try await paceHistory.immutableHalfHourlySamplesAndPersistence() }),
            ("pace history intermediate continuity breaks", { try await paceHistory.continuityIncludesInterveningReadings() }),
            ("pace recovery estimate formula persistence and usage isolation", { try await paceHistory.matchingWakeRecoversEstimatesWithoutInventingUsage() }),
            ("pace recovery rejects ambiguous endpoints", { try await paceHistory.recoveryRejectsAmbiguousEndpointsAndHonorsSessionBreaks() }),
            ("pace recovery version two migration and short sleep", { try await paceHistory.recoveryPreservesVersionTwoAndHandlesShortSleep() }),
            ("pace legacy migration wake and retention", { try await paceHistory.legacyHistoryAndRecoveredPaceRetention() }),
            ("pace recovery never extends past retention", { try await paceHistory.recoveryNeverExtendsPastRetention() }),
            ("pace write failure retains immutable memory", { try await paceHistory.writeFailureKeepsImmutablePaceInMemory() }),
            ("hourly allocation", { try await history.hourlyBoundaryAllocation() }),
            ("delayed quota jump weighted attribution", { try await history.delayedQuotaJumpUsesWeightedTokenAttribution() }),
            ("unknown model attribution is partial", { try await history.attributionMarksUnknownModelCoveragePartial() }),
            ("off-chart attribution stays in denominator", { try await history.attributionDenominatorIncludesOffChartActivity() }),
            ("dynamic required pace and validity boundaries", { try core.testRequiredPacePerHour() }),
            ("login item reflects initial and external system state", { try login.initialStateAndExternalChangesAreReadOnly() }),
            ("login item registration approval and failure states", { try login.registrationApprovalAndErrorsReflectSystemState() }),
            ("history gaps resets and corrections", { try await history.gapsResetsAndCorrectionsRemainUnknown() }),
            ("history account scoping and restart continuity", { try await history.accountScopingAndRestartContinuity() }),
            ("history persistence validation and retention", { try await history.persistenceValidationDeduplicationAndRetention() }),
            ("history write failure retains memory", { try await history.writeFailurePreservesObservedMemory() }),
            ("opaque stable account digest", { try await connection.accountDigestIsStableAndOpaque() }),
            ("missing identity never shares history", { try await connection.missingIdentityDoesNotCreateSharedHistoryKey() }),
            ("quota ring threshold colors in light and dark", { try rings.thresholdColors() }),
            ("unknown and stale rings", { try rings.unknownAndStale() }),
            ("inverse time colors and weekly pace", { try rings.inverseTimeColorsAndPace() }),
            ("adaptive inner ring offset", { try rings.adaptiveInnerRingOffset() }),
            ("missing or malformed reset banks preserve quota", { try resets.missingAndMalformedBanksPreserveWeeklyUsage() }),
            ("reset counts survive partial details", { try resets.countsRemainAuthoritativeWithMissingOrPartialDetails() }),
            ("reset expiry ordering and unknown dates", { try resets.earliestExpiryFirstAndUnknownDatesRemainUnknown() }),
            ("reset expiry lifetime and local expiry boundaries", { try resets.expiryProgressRequiresValidLifetimeAndKeepsReportedCount() }),
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
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--render-rings=") }) {
            do { try rings.writePreview(to: String(argument.dropFirst("--render-rings=".count))) }
            catch {
                failures += 1
                print("FAIL ring preview: \(error.localizedDescription)")
            }
        }
        if failures != 0 { exit(1) }
    }
}
