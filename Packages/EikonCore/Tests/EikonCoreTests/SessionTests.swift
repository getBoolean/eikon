import CEikonSession
import Foundation
import Testing
import EikonCore

// MARK: Helpers

private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

private func record(game: GameID = GameID(uuid: UUID()), startedAt: Date = Date(),
                    phase: SessionRecord.Phase = .running) -> SessionRecord {
    SessionRecord(gameID: game, engine: .unity, architecture: .amd64, route: "wine-fex", appBuild: "1",
                  startedAt: startedAt, phase: phase)
}

private func crumb(_ seq: UInt64, _ event: BreadcrumbEvent, at time: Date) -> Breadcrumb {
    Breadcrumb(seq: seq, time: time, event: event)
}

private let device = CrashIssue.Device(appVersion: "0.2", appBuild: "7", appCommit: "abc1234",
                                       modelIdentifier: "iPad13,1", osVersion: "17.0", osBuild: "21A1",
                                       installMethod: "trollstore", jitUsable: true, jitSource: "trollstore",
                                       jitReasonCode: nil)
private let repository = URL(string: "https://github.com/example/eikon")!

private func entry(game: GameID = GameID(uuid: UUID()), crumbs: Int = 3) -> CrashEntry {
    let rec = record(game: game)
    let breadcrumbs = (1...max(crumbs, 1)).prefix(crumbs).map {
        Breadcrumb(seq: UInt64($0), time: rec.startedAt + Double($0), event: .memorySample(availableMB: Int64($0)))
    }
    return CrashEntry(id: rec.sessionID, record: rec, outcome: .endedUnexpectedly, breadcrumbs: breadcrumbs,
                      fault: FaultRecord(signal: 11, pc: 0x1000, address: 0), recordedAt: Date())
}

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

// MARK: Tests touching the process-wide C descriptors run one at a time

@Suite(.serialized) struct SessionFileTests {
    @Test func armThenConsumeReturnsTheRecordOnce() throws {
        try withTempDir { dir in
            let sentinel = SessionSentinel(directory: dir), rec = record()
            try sentinel.arm(rec)
            #expect(sentinel.consumeAtLaunch()?.record == rec)
            #expect(sentinel.consumeAtLaunch() == nil)
        }
    }

    @Test func disarmLeavesNothingToConsume() throws {
        try withTempDir { dir in
            let sentinel = SessionSentinel(directory: dir), rec = record()
            try sentinel.arm(rec)
            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
            Breadcrumbs.append(.sessionStart)
            Breadcrumbs.close()
            try FaultRecord.open(at: sentinel.faultURL, sessionID: rec.sessionID)
            FaultRecord.close()

            sentinel.disarm()
            #expect(sentinel.consumeAtLaunch() == nil)
            #expect(!FileManager.default.fileExists(atPath: sentinel.breadcrumbsURL.path))
            #expect(!FileManager.default.fileExists(atPath: sentinel.faultURL.path))
        }
    }

    enum Evidence: CaseIterable { case fault, memoryWarning, nothing, background }

    @Test(arguments: Evidence.allCases)
    func outcomeFollowsTheEvidence(evidence: Evidence) throws {
        try withTempDir { dir in
            let sentinel = SessionSentinel(directory: dir), rec = record()
            try sentinel.arm(rec)
            try Breadcrumbs.open(at: sentinel.breadcrumbsURL)
            Breadcrumbs.append(.sessionStart)
            switch evidence {
            case .fault:
                try FaultRecord.open(at: sentinel.faultURL, sessionID: rec.sessionID)
                eikon_session_fault_record(11, 0x4000, 0x10)
                FaultRecord.close()
            case .memoryWarning:
                Breadcrumbs.append(.memoryWarning)
                Breadcrumbs.append(.sessionPaused)
            case .nothing:
                Breadcrumbs.append(.memorySample(availableMB: SessionOutcome.lowMemoryThresholdMB * 10))
            case .background:
                try sentinel.setPhase(.background)
            }
            Breadcrumbs.close()

            let outcome = SessionOutcome.classify(try #require(sentinel.consumeAtLaunch()))
            switch evidence {
            case .fault: #expect(outcome == .crashed(signal: 11, pc: 0x4000))
            case .memoryWarning: #expect(outcome == .likelyMemoryKill)
            case .nothing: #expect(outcome == .endedUnexpectedly)
            case .background: #expect(outcome == .killedInBackground)
            }
            #expect(outcome.showsBanner == (evidence != .background))
        }
    }

    @Test func ringKeepsTheLastCapacityInOrder() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("breadcrumbs.bin")
            try Breadcrumbs.open(at: url)
            let total = Breadcrumbs.capacity + 10
            for index in 0..<total { Breadcrumbs.append(.runtimeError(code: Int64(index))) }
            Breadcrumbs.close()

            let read = Breadcrumbs.read(from: url)
            #expect(read.map(\.a) == Array((total - Breadcrumbs.capacity)..<total).map(Int64.init))
        }
    }

    @Test func tornSlotIsSkipped() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("breadcrumbs.bin")
            try Breadcrumbs.open(at: url)
            for index in 0..<4 { Breadcrumbs.append(.runtimeError(code: Int64(index))) }
            Breadcrumbs.close()
            let slotSize = Int(EIKON_BREADCRUMB_SLOT_SIZE)

            // Overwrite the first half of slot 2 with the start of slot 3: a torn write.
            var data = try Data(contentsOf: url)
            data.replaceSubrange((2 * slotSize)..<(2 * slotSize + slotSize / 2),
                                 with: data.subdata(in: (3 * slotSize)..<(3 * slotSize + slotSize / 2)))
            try data.write(to: url)

            let read = Breadcrumbs.read(from: url)
            #expect(read.count == 3)
            #expect(!read.map(\.a).contains(1)) // seq 2 held code 1
        }
    }

    @Test func truncatedFileYieldsTheWholeSlots() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("breadcrumbs.bin")
            try Breadcrumbs.open(at: url)
            for index in 0..<3 { Breadcrumbs.append(.runtimeError(code: Int64(index))) }
            Breadcrumbs.close()
            let slotSize = Int(EIKON_BREADCRUMB_SLOT_SIZE)
            let data = try Data(contentsOf: url)
            try data.prefix(3 * slotSize + slotSize / 2).write(to: url) // ends mid-slot 3

            #expect(Breadcrumbs.read(from: url).map(\.a) == [0, 1])
        }
    }

    @Test func faultWrittenThroughTheHookReadsBack() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("fault.bin"), session = UUID()
            try FaultRecord.open(at: url, sessionID: session)
            eikon_session_fault_record(10, 0xDEAD_BEEF, 0x20)
            eikon_session_fault_record(11, 0x1234, 0x30)
            FaultRecord.close()

            let fault = try #require(FaultRecord.read(from: url, sessionID: session))
            #expect(fault.signal == 10)
            #expect(fault.pc == 0xDEAD_BEEF)
            #expect(FaultRecord.read(from: url, sessionID: UUID()) == nil)
        }
    }
}

// MARK: Outcome

@Test func oldMemoryWarningIsNotAMemoryKill() {
    let start = Date()
    let late = start + SessionOutcome.memoryWarningWindow + 1
    let consumed = ConsumedSession(record: record(startedAt: start),
                                   breadcrumbs: [crumb(1, .memoryWarning, at: start), crumb(2, .sessionStart, at: late)],
                                   fault: nil)
    #expect(SessionOutcome.classify(consumed) == .endedUnexpectedly)
}

// MARK: History

@Test func historyKeepsTheNewestEntriesPerGame() throws {
    try withTempDir { dir in
        let history = CrashHistory(directory: dir)
        let game = GameID(uuid: UUID()), other = GameID(uuid: UUID())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let crumbs = [crumb(1, .sessionStart, at: start)]
        history.add(ConsumedSession(record: record(game: other, startedAt: start), breadcrumbs: crumbs, fault: nil),
                    now: start)
        var added: [SessionRecord] = []
        for index in 0..<(CrashHistory.limitPerGame + 2) {
            let rec = record(game: game, startedAt: start + Double(index))
            added.append(rec)
            history.add(ConsumedSession(record: rec, breadcrumbs: crumbs, fault: nil), now: start + Double(index))
        }

        let reopened = CrashHistory(directory: dir)
        let kept = reopened.entries(for: game)
        #expect(kept.map(\.record) == Array(added.suffix(CrashHistory.limitPerGame).reversed()))
        #expect(kept.allSatisfy { $0.breadcrumbs == crumbs })
        #expect(reopened.entries(for: other).count == 1)
    }
}

// MARK: Issue URL

@Test func issueQueryParsesBackToTheFields() {
    let crash = entry()
    let built = CrashIssue.url(repository: repository, entry: crash, device: device,
                               reportID: CrashIssue.reportID(for: crash.record.gameID))
    let fields = query(built.url)
    #expect(Set(fields.keys) == ["template", "labels", "title", "outcome", "engine", "arch", "route", "game", "app",
                                 "device", "install", "jit", "fault", "breadcrumbs"])
    #expect(fields["outcome"] == crash.outcome.code)
    #expect(fields["engine"] == crash.record.engine.rawValue)
    #expect(fields["arch"] == crash.record.architecture?.rawValue)
    #expect(fields["route"] == crash.record.route)
    #expect(fields["game"] == CrashIssue.reportID(for: crash.record.gameID))
    #expect(fields["install"] == device.installMethod)
    for part in [device.appVersion, device.appBuild, device.appCommit] { #expect(fields["app"]?.contains(part) == true) }
    for part in [device.modelIdentifier, device.osVersion, device.osBuild] {
        #expect(fields["device"]?.contains(part) == true)
    }
    #expect(fields["jit"]?.contains(device.jitSource!) == true)
    #expect(fields["fault"]?.contains(String(crash.fault!.pc, radix: 16)) == true)
    #expect(fields["breadcrumbs"]?.split(separator: "\n").count == crash.breadcrumbs.count)
    #expect(built.droppedBreadcrumbs == 0)
}

@Test func reservedCharactersRoundTrip() {
    var crash = entry()
    crash.record.route = "a+b & c=d"
    let built = CrashIssue.url(repository: repository, entry: crash, device: device, reportID: "r+e&p=o t")
    let fields = query(built.url)
    #expect(fields["route"] == "a+b & c=d")
    #expect(fields["game"] == "r+e&p=o t")
}

@Test func longReportsDropTheOldestBreadcrumbsToFit() {
    let crash = entry(crumbs: CrashIssue.maxBreadcrumbs)
    let full = CrashIssue.url(repository: repository, entry: crash, device: device, reportID: "abcd1234")
    var padded = device
    // Pad a bounded field so the full report overflows by a little: only some crumbs fit.
    padded.appCommit += String(repeating: "c", count: CrashIssue.maxURLLength - full.url.absoluteString.count + 100)
    let built = CrashIssue.url(repository: repository, entry: crash, device: padded, reportID: "abcd1234")

    #expect(built.url.absoluteString.count <= CrashIssue.maxURLLength)
    #expect(built.droppedBreadcrumbs > 0)
    let firstSeqs = (query(built.url)["breadcrumbs"] ?? "").split(separator: "\n").compactMap { $0.split(separator: " ").first }
    let sorted = crash.breadcrumbs.sorted { $0.seq < $1.seq }
    #expect(firstSeqs.last.map(String.init) == String(sorted.last!.seq))
    #expect(!firstSeqs.contains { String($0) == String(sorted.first!.seq) })
}

@Test func issueCarriesTheReportIDAndNoFingerprintOrFullID() {
    let game = GameID(uuid: UUID())
    let crash = entry(game: game)
    let fingerprintLike = String(repeating: "9f3c", count: 16)
    let url = CrashIssue.url(repository: repository, entry: crash, device: device,
                             reportID: CrashIssue.reportID(for: game)).url.absoluteString.lowercased()
    #expect(url.contains(CrashIssue.reportID(for: game)))
    #expect(!url.contains(fingerprintLike))
    #expect(!url.contains(game.uuid.uuidString.lowercased()))
}
