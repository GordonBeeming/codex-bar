import Foundation
import XCTest
@testable import CodexBarCore

final class BarTelemetryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "codexbar-bar-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func result(_ json: String) throws -> RateLimitsResult {
        try JSONDecoder().decode(RateLimitsResult.self, from: Data(json.utf8))
    }

    private func weekly(_ percent: Double, resetsAt: Int) throws -> RateLimitsResult {
        try result(#"{"accountId":"a","rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":\#(percent),"windowDurationMins":10080,"resetsAt":\#(resetsAt)}}}}"#)
    }

    private func recorder(_ sink: RecordingSink, stateFile: String = "state.json") -> TelemetryRecorder {
        TelemetryRecorder(sink: sink, retentionDays: 90, serviceVersion: "9.8", intervalMinutes: 5,
                          stateURL: home.appending(path: stateFile), scanner: SessionTokenScanner(codexHome: home.appending(path: "codex")))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func attributes(_ list: Any?) -> [String: Any] {
        var values: [String: Any] = [:]
        for item in list as? [[String: Any]] ?? [] {
            guard let key = item["key"] as? String, let value = item["value"] as? [String: Any] else { continue }
            values[key] = value["stringValue"] ?? value["intValue"] ?? value["doubleValue"] ?? value["boolValue"]
        }
        return values
    }

    private func records(_ lines: [Data]) throws -> [[String: Any]] {
        try lines.flatMap { line -> [[String: Any]] in
            let object = try json(line)
            let resourceLogs = object["resourceLogs"] as? [[String: Any]] ?? []
            return resourceLogs.flatMap { ($0["scopeLogs"] as? [[String: Any]] ?? []).flatMap { $0["logRecords"] as? [[String: Any]] ?? [] } }
        }
    }

    private func eventNames(_ lines: [Data]) throws -> [String] {
        try records(lines).compactMap { $0["eventName"] as? String }
    }

    func testResourceScopeAndLimitMetricsFollowTheSpec() async throws {
        let sink = RecordingSink()
        let usage = try result(#"""
        {"rateLimitsByLimitId":{
          "codex":{"secondary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":1800000000}},
          "codex_spark":{"limitName":"gpt_spark","primary":{"usedPercent":7}}}}
        """#)
        try await recorder(sink).recordSample(result: usage, planType: "pro", observedAt: Date(), at: Date(timeIntervalSince1970: 1_799_000_000))
        let lines = await sink.lines
        let metrics = try json(lines[0])
        let resource = try XCTUnwrap((metrics["resourceMetrics"] as? [[String: Any]])?.first)
        let resourceAttributes = attributes((resource["resource"] as? [String: Any])?["attributes"])
        XCTAssertEqual(resourceAttributes["service.name"] as? String, "codexbar")
        XCTAssertEqual(resourceAttributes["service.version"] as? String, "9.8")
        XCTAssertEqual(resourceAttributes["os.type"] as? String, "darwin")
        XCTAssertEqual(resourceAttributes["bar.spec.version"] as? String, "1")
        XCTAssertNotNil(resourceAttributes["host.name"])
        let scopeMetrics = try XCTUnwrap((resource["scopeMetrics"] as? [[String: Any]])?.first)
        let scope = try XCTUnwrap(scopeMetrics["scope"] as? [String: Any])
        XCTAssertEqual(scope["name"] as? String, "com.gordonbeeming.CodexBar.telemetry")
        XCTAssertEqual(scope["version"] as? String, "9.8")

        let all = try XCTUnwrap(scopeMetrics["metrics"] as? [[String: Any]])
        let utilization = try XCTUnwrap(all.first { $0["name"] as? String == "bar.limit.utilization" })
        let points = try XCTUnwrap((utilization["gauge"] as? [String: Any])?["dataPoints"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: points.map { (attributes($0["attributes"])["limit.id"] as? String ?? "", $0) })
        let weekly = try XCTUnwrap(byID["codex:10080"])
        XCTAssertEqual(weekly["asDouble"] as? Double, 42.5)
        XCTAssertEqual(attributes(weekly["attributes"])["limit.name"] as? String, "Weekly")
        XCTAssertEqual(attributes(weekly["attributes"])["limit.window.duration_minutes"] as? String, "10080")
        let spark = try XCTUnwrap(byID["codex_spark:primary"], "A window with no length still gets a stable ID")
        XCTAssertNil(attributes(spark["attributes"])["limit.window.duration_minutes"])
        XCTAssertEqual(attributes(spark["attributes"])["limit.name"] as? String, "Primary · Gpt Spark")
        let resets = try XCTUnwrap(all.first { $0["name"] as? String == "bar.limit.resets_at" })
        let resetPoints = try XCTUnwrap((resets["gauge"] as? [String: Any])?["dataPoints"] as? [[String: Any]])
        XCTAssertEqual(resetPoints.map { $0["asInt"] as? String }, ["1800000000"])

        let logs = try records([lines[1]])
        XCTAssertTrue(logs.allSatisfy { $0["body"] == nil && $0["eventName"] is String && $0["severityNumber"] as? Int == 9 })
        XCTAssertEqual(logs.first?["eventName"] as? String, "bar.tracking.started")
        XCTAssertEqual(attributes(logs.first?["attributes"])["tracking.interval_minutes"] as? String, "5")
        XCTAssertEqual(try eventNames([lines[1]]).filter { $0 == "bar.limit.appeared" }.count, 2)
    }

    func testLimitResetAndDisappearanceEventsSurviveARelaunch() async throws {
        let sink = RecordingSink()
        let start = Date(timeIntervalSince1970: 1_799_000_000)
        try await recorder(sink).recordSample(result: try weekly(80, resetsAt: 1_800_000_000), planType: nil, observedAt: start, at: start)
        // A relaunch reads the persisted observation, so it neither re-announces the Limit
        // nor restarts tracking.
        let relaunched = recorder(sink)
        try await relaunched.recordSample(result: try weekly(81, resetsAt: 1_800_000_004), planType: nil, observedAt: start, at: start)
        try await relaunched.recordSample(result: try weekly(2, resetsAt: 1_800_604_800), planType: nil, observedAt: start, at: start)
        try await relaunched.recordSample(result: try result(#"{"rateLimitsByLimitId":{}}"#), planType: nil, observedAt: start, at: start)
        let lines = await sink.lines
        let names = try eventNames(lines).filter { $0.hasPrefix("bar.") }
        XCTAssertEqual(names, ["bar.tracking.started", "bar.limit.appeared", "bar.limit.reset", "bar.limit.disappeared"])
        let reset = try XCTUnwrap(try records(lines).first { $0["eventName"] as? String == "bar.limit.reset" })
        XCTAssertEqual(attributes(reset["attributes"])["limit.utilization.last"] as? Double, 81)
        XCTAssertEqual(attributes(reset["attributes"])["limit.resets_at.next"] as? String, "1800604800")
    }

    func testTokensAreACumulativeSumThatRestartsWithANewStartTimeAfterDiscard() async throws {
        let sink = RecordingSink()
        let session = home.appending(path: "codex/sessions/rollout-2026-10-12T10-00-00-019C40FB-7BDB-76F1-A673-5D915C6FA0E0.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = recorder(sink)
        try await first.recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 100))
        try Data(#"""
        {"timestamp":"2026-10-12T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"timestamp":"2026-10-12T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":9,"reasoning_output_tokens":4,"total_tokens":129},"last_token_usage":{"input_tokens":120,"cached_input_tokens":100,"output_tokens":9,"reasoning_output_tokens":4,"total_tokens":129}}}}

        """#.utf8).write(to: session)
        try await first.recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 200))
        let lines = await sink.lines
        let sum = try XCTUnwrap(try tokenMetric(lines.last { (try? json($0))?["resourceMetrics"] != nil }))
        XCTAssertEqual(sum["aggregationTemporality"] as? Int, 2)
        XCTAssertEqual(sum["isMonotonic"] as? Bool, true)
        let points = try XCTUnwrap(sum["dataPoints"] as? [[String: Any]])
        var values: [String: String] = [:]
        for point in points {
            let attrs = attributes(point["attributes"])
            XCTAssertEqual(attrs["model"] as? String, "gpt-5.5")
            XCTAssertEqual(point["startTimeUnixNano"] as? String, "100000000000")
            values[attrs["token.type"] as? String ?? ""] = point["asInt"] as? String
        }
        XCTAssertEqual(values, ["input": "20", "cache_read": "100", "cache_write": "0", "output": "9", "reasoning": "4"])

        first.stop()
        try TelemetryRecorder.discardState(at: home.appending(path: "state.json"))
        let second = recorder(sink)
        try await second.recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 300))
        let restarted = await sink.lines
        XCTAssertEqual(try eventNames(restarted).filter { $0 == "bar.tracking.started" }.count, 2)
        XCTAssertNil(try tokenMetric(restarted.last { (try? json($0))?["resourceMetrics"] != nil }),
                     "A restarted count has nothing to report until new tokens arrive")
    }

    func testFailedFirstLogWriteKeepsTheBaselineAndRetriesTheStartEvent() async throws {
        let sink = RecordingSink()
        await sink.failLogs(true)
        let first = recorder(sink)
        do {
            try await first.recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 100))
            XCTFail("Expected the log write to fail")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        await sink.failLogs(false)
        // Even across a relaunch, the retry keeps the original start time and announces it.
        try await recorder(sink).recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 200))
        try await recorder(sink).recordSample(result: nil, planType: nil, observedAt: nil, at: Date(timeIntervalSince1970: 300))
        let lines = await sink.lines
        XCTAssertEqual(try eventNames(lines), ["bar.tracking.started"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let saved = try decoder.decode(TelemetryState.self, from: Data(contentsOf: home.appending(path: "state.json")))
        XCTAssertEqual(saved.scan?.countingSince.timeIntervalSince1970, 100)
        XCTAssertEqual(saved.startAnnounced, true)
    }

    func testTrackingStartsBeforeTheFirstPerkEventsAndPerksFollowTheAccount() async throws {
        let sink = RecordingSink()
        let rec = recorder(sink)
        let first = try result(#"{"accountId":"a","rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"x","status":"available","resetType":"r","grantedAt":1},{"id":"y","status":"available","resetType":"r","grantedAt":1}]}}"#)
        try await rec.observeResetCredits(result: first, planType: nil, at: Date())
        let other = try result(#"{"accountId":"b","rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#)
        try await rec.observeResetCredits(result: other, planType: nil, at: Date())
        try await rec.recordSample(result: nil, planType: nil, observedAt: nil, at: Date())
        let names = try eventNames(await sink.lines).filter { $0.hasPrefix("bar.") }
        // Switching to an account without credits isn't the first account's credits going.
        XCTAssertEqual(names, ["bar.tracking.started", "bar.perk.available", "bar.perk.available"])
    }

    func testAnUnreadableSessionsFolderDoesNotStopAccountTelemetry() async throws {
        let sessions = home.appending(path: "codex/sessions/2026")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessions.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path) }
            catch { XCTFail("Couldn't restore fixture permissions: \(error)") }
        }
        let sink = RecordingSink()
        let rec = recorder(sink)
        try await rec.recordSample(result: try weekly(10, resetsAt: 1_800_000_000), planType: nil, observedAt: Date(), at: Date())
        let lines = await sink.lines
        XCTAssertTrue(String(decoding: lines[0], as: UTF8.self).contains("bar.limit.utilization"))
        let warnings = await rec.exportWarnings()
        XCTAssertTrue(warnings.contains { $0.hasPrefix("Couldn't start counting Codex tokens") })
    }

    private func tokenMetric(_ line: Data?) throws -> [String: Any]? {
        guard let line else { return nil }
        let resource = (try json(line)["resourceMetrics"] as? [[String: Any]])?.first
        let metrics = (resource?["scopeMetrics"] as? [[String: Any]])?.first?["metrics"] as? [[String: Any]] ?? []
        return metrics.first { $0["name"] as? String == "bar.tokens" }?["sum"] as? [String: Any]
    }

    func testPerkEventsTellUsedFromExpired() {
        let now = Date(timeIntervalSince1970: 1_000)
        func summary(_ count: Int, _ credits: [(String, String, TimeInterval?)]?) -> ResetCreditsSummary {
            ResetCreditsSummary(availableCount: count, credits: credits?.map {
                ResetCredit(id: $0.0, status: $0.1, resetType: "codexRateLimits", grantedAt: 1, expiresAt: $0.2, title: nil, description: nil)
            })
        }
        let first = BarEvents.perkEvents(previous: nil, summary: summary(2, [("a", "available", 2_000), ("b", "available", 500)]), now: now)
        XCTAssertEqual(first.events.map(\.name), ["bar.perk.available", "bar.perk.available"])
        XCTAssertTrue(first.events[0].attributes.contains { $0.key == "perk.expires_at" && $0.value.intValue == "2000" })

        let used = BarEvents.perkEvents(previous: first.observed, summary: summary(1, [("a", "redeemed", 2_000), ("b", "available", 500)]), now: now)
        XCTAssertEqual(used.events.map(\.name), ["bar.perk.gone"])
        XCTAssertTrue(used.events[0].attributes.contains { $0.key == "perk.gone.reason" && $0.value.stringValue == "used" })

        let expired = BarEvents.perkEvents(previous: used.observed, summary: summary(0, []), now: now)
        XCTAssertEqual(expired.events.map(\.name), ["bar.perk.gone"])
        XCTAssertTrue(expired.events[0].attributes.contains { $0.key == "perk.id" && $0.value.stringValue == "b" })
        XCTAssertTrue(expired.events[0].attributes.contains { $0.key == "perk.gone.reason" && $0.value.stringValue == "expired" })

        // A capped list that drops a row while the count holds is not a perk going.
        let capped = BarEvents.perkEvents(previous: first.observed, summary: summary(2, [("a", "available", 2_000)]), now: now)
        XCTAssertTrue(capped.events.isEmpty)
        // A capped list rotating to a credit it hid before is not a new perk.
        let rotated = BarEvents.perkEvents(previous: ObservedPerks(scope: nil, count: 1, available: ["a": 2_000]),
                                           summary: summary(1, [("z", "available", 3_000)]), now: now)
        XCTAssertTrue(rotated.events.isEmpty)
        // An expiry Codex reports only later is the one a disappearance is judged by.
        let noExpiry = BarEvents.perkEvents(previous: nil, summary: summary(1, [("c", "available", nil)]), now: now)
        let laterExpiry = BarEvents.perkEvents(previous: noExpiry.observed, summary: summary(1, [("c", "available", 900)]), now: now)
        XCTAssertTrue(laterExpiry.events.isEmpty)
        let gone = BarEvents.perkEvents(previous: laterExpiry.observed, summary: summary(0, []), now: now)
        XCTAssertTrue(gone.events[0].attributes.contains { $0.key == "perk.gone.reason" && $0.value.stringValue == "expired" })

        let countOnly = BarEvents.perkEvents(previous: ObservedPerks(count: 1, available: [:]), summary: summary(3, nil), now: now)
        XCTAssertEqual(countOnly.events.map(\.name), ["bar.perk.available"])
        // An unnamed event stands for every credit the count moved by; a named one is one credit.
        XCTAssertTrue(countOnly.events[0].attributes.contains { $0.key == "perk.quantity" && $0.value.intValue == "2" })
        XCTAssertFalse(first.events.contains { $0.attributes.contains { $0.key == "perk.quantity" } })
        let countDrop = BarEvents.perkEvents(previous: ObservedPerks(count: 3, available: ["a": 2_000]), summary: summary(0, nil), now: now)
        XCTAssertEqual(countDrop.events.map(\.name), ["bar.perk.gone", "bar.perk.gone"])
        XCTAssertFalse(countDrop.events[0].attributes.contains { $0.key == "perk.quantity" })
        XCTAssertTrue(countDrop.events[1].attributes.contains { $0.key == "perk.quantity" && $0.value.intValue == "2" })
    }

    /// The `bar.perk.available` points as (value, attributes by key), in the order they were written.
    private func perkPoints(_ json: String) throws -> [(value: String, attributes: [String: String])] {
        let usage = try result(json)
        let data = try OTLPTelemetryEncoder.metrics(result: usage, planType: nil, observedAt: nil, capturedAt: Date(), serviceVersion: "t")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap(((((root["resourceMetrics"] as? [[String: Any]])?.first?["scopeMetrics"]) as? [[String: Any]])?
            .flatMap { ($0["metrics"] as? [[String: Any]]) ?? [] }))
        let metric = try XCTUnwrap(metrics.first { $0["name"] as? String == "bar.perk.available" })
        let points = try XCTUnwrap((metric["gauge"] as? [String: Any])?["dataPoints"] as? [[String: Any]])
        return points.map { point in
            var attributes: [String: String] = [:]
            for attribute in (point["attributes"] as? [[String: Any]]) ?? [] {
                let value = attribute["value"] as? [String: Any]
                attributes[attribute["key"] as? String ?? ""] = (value?["stringValue"] ?? value?["intValue"]) as? String
            }
            return (point["asInt"] as? String ?? "", attributes)
        }
    }

    func testPerkGaugeWritesOnePointPerAvailableCredit() throws {
        let points = try perkPoints(#"""
        {"rateLimitResetCredits":{"availableCount":2,"credits":[
          {"id":"a","status":"available","resetType":"x","grantedAt":1,"expiresAt":2000},
          {"id":"b","status":"available","resetType":"x","grantedAt":1,"expiresAt":1500},
          {"id":"c","status":"redeemed","resetType":"x","grantedAt":1,"expiresAt":100}]}}
        """#)
        XCTAssertEqual(points.map(\.value), ["1", "1"])
        XCTAssertEqual(points.map { $0.attributes["perk.id"] }, ["a", "b"])
        XCTAssertEqual(points.map { $0.attributes["perk.expires_at"] }, ["2000", "1500"])
        XCTAssertEqual(points.map { $0.attributes["perk.kind"] }, ["reset_credit", "reset_credit"])
    }

    func testPerkGaugeKeepsTheTotalWhenTheListIsShorterThanTheCount() throws {
        let points = try perkPoints(#"""
        {"rateLimitResetCredits":{"availableCount":3,"credits":[
          {"id":"a","status":"available","resetType":"x","grantedAt":1,"expiresAt":2000}]}}
        """#)
        XCTAssertEqual(points.map(\.value), ["1", "2"])
        XCTAssertEqual(points[0].attributes["perk.id"], "a")
        XCTAssertNil(points[1].attributes["perk.id"])
        XCTAssertNil(points[1].attributes["perk.expires_at"])
    }

    func testPerkGaugeStillWritesZeroWhenThereAreNoCredits() throws {
        let points = try perkPoints(#"{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#)
        XCTAssertEqual(points.map(\.value), ["0"])
        XCTAssertNil(points[0].attributes["perk.id"])
        XCTAssertEqual(points[0].attributes["perk.kind"], "reset_credit")
    }

    func testTelemetryURLAcceptsAnySubsetAndRejectsTheWholeRequestOnABadValue() throws {
        let all = try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "codexbar://telemetry?enabled=1&interval=7&retention=0&folder=%2FUsers%2Fme%2FMy%20Telemetry%2F&utm=x")))
        XCTAssertEqual(all, .telemetry(.init(enabled: true, intervalMinutes: 7, retentionDays: 0, directory: "/Users/me/My Telemetry")))
        XCTAssertEqual(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "codexbar://telemetry?retention=3650"))),
                       .telemetry(.init(retentionDays: 3_650)))
        XCTAssertEqual(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "codexbar://settings"))), .settings)
        for bad in ["codexbar://telemetry?interval=0", "codexbar://telemetry?interval=1441&enabled=1",
                    "codexbar://telemetry?retention=3651", "codexbar://telemetry?enabled=yes",
                    "codexbar://telemetry?folder=relative/path", "codexbar://telemetry?interval=5&interval=6",
                    "codexbar://telemetry?interval=5.5", "codexbar://nope", "claudebar://settings"] {
            XCTAssertThrowsError(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: bad))), bad)
        }
    }

    func testConfirmationListsOnlyRealChangesOldValueFirst() {
        let current = TelemetryConfiguration(enabled: false, intervalMinutes: 5, retentionDays: 90, directory: URL(fileURLWithPath: "/a"))
        let change = TelemetrySettingsChange(enabled: true, intervalMinutes: 15, retentionDays: 0, directory: "/a")
        XCTAssertEqual(change.changeLines(from: current), ["Tracking: off → on", "Interval: 5 min → 15 min", "Retention: 90 days → forever"])
        XCTAssertTrue(TelemetrySettingsChange(intervalMinutes: 5).changeLines(from: current).isEmpty)
    }
}

actor RecordingSink: TelemetrySink {
    var lines: [Data] = []
    private var logsFail = false
    func failLogs(_ fail: Bool) { logsFail = fail }
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int, activity: TelemetryActivity?) async throws {
        try activity?.check()
        if signal == .logs, logsFail { throw CocoaError(.fileWriteNoPermission) }
        lines.append(data)
    }
}
