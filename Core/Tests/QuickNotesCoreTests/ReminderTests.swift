import Foundation
import Testing
@testable import NoteLumeCore

actor MockScheduler: NotificationScheduling {
    var perm: NotificationPermission = .authorized
    var pending: [String: ReminderNotification] = [:]
    var delivered: [ReminderNotification] = []
    var scheduleCalls = 0

    func setPermission(_ p: NotificationPermission) { perm = p }
    func permission() async -> NotificationPermission { perm }
    func pendingIdentifiers() async -> Set<String> { Set(pending.keys) }
    func deliveredIdentifiers() async -> Set<String> { Set(delivered.map(\.identifier)) }
    func schedule(_ n: ReminderNotification) async throws { scheduleCalls += 1; pending[n.identifier] = n }
    func deliverNow(_ n: ReminderNotification) async throws { delivered.append(n) }
    func cancelPending(identifiers: [String]) async { for i in identifiers { pending[i] = nil } }
    func pendingCount() -> Int { pending.count }
    func deliveredCount() -> Int { delivered.count }
    func calls() -> Int { scheduleCalls }
    func pendingFor(_ id: UUID) -> [ReminderNotification] { pending.values.filter { $0.noteID == id } }
}

@Suite struct ReminderTests {
    func setup() async throws -> (Sandbox, NoteStore, MockScheduler, ReminderCoordinator) {
        let sb = try Sandbox(); let store = try makeStore(sb)
        let sched = MockScheduler()
        return (sb, store, sched, ReminderCoordinator(index: store.index, scheduler: sched))
    }

    func note(_ store: NoteStore, in sb: Sandbox, reminder: Date, body: String = "# Task") async throws -> UUID {
        let n = try await store.create(body: body)
        try await store.mutateMetadata(n.document.metadata.id) { $0.metadata.reminder = reminder }
        return n.document.metadata.id
    }

    @Test func schedulesFutureRemindersExactlyOnce() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(3600))
        var status = await rc.reconcile(now: now)
        #expect(status.scheduled == 1)
        #expect(status.upcoming == [id])
        _ = await rc.reconcile(now: now)
        _ = await rc.reconcile(now: now.addingTimeInterval(60))
        #expect(await sched.calls() == 1)           // no duplicate scheduling for the same revision
        status = await rc.reconcile(now: now)
        #expect(await sched.pendingCount() == 1)
    }

    @Test func changedReminderReplacesOldNotification() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(3600))
        _ = await rc.reconcile(now: now)
        let newDate = now.addingTimeInterval(7200)
        try await store.mutateMetadata(id) { $0.metadata.reminder = newDate }
        _ = await rc.reconcile(now: now)
        let p = await sched.pendingFor(id)
        #expect(p.count == 1)
        #expect(Int(p[0].fireDate.timeIntervalSince1970) == Int(newDate.timeIntervalSince1970))
    }

    @Test func removedReminderIsCancelled() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(3600))
        _ = await rc.reconcile(now: now)
        try await store.mutateMetadata(id) { $0.metadata.reminder = nil }
        _ = await rc.reconcile(now: now)
        #expect(await sched.pendingCount() == 0)
    }

    @Test func externalEditToReminderIsReconciled() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(3600))
        _ = await rc.reconcile(now: now)
        // Another Mac / editor changes the reminder inside the file.
        var raw = try sb.readRaw(id)
        let iso = ISO8601.format(now.addingTimeInterval(3600))
        let moved = ISO8601.format(now.addingTimeInterval(9000))
        raw = raw.replacingOccurrences(of: iso, with: moved)
        try sb.writeRaw(raw, id: id)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: sb.url(id).path)
        await store.reconcile()
        _ = await rc.reconcile(now: now)
        let p = await sched.pendingFor(id)
        #expect(p.count == 1)
        #expect(ISO8601.format(p[0].fireDate) == moved)
    }

    @Test func missedReminderAnnouncedOnceThenOnlyListedOverdue() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(-3600))
        var status = await rc.reconcile(now: now)
        #expect(status.overdue == [id])
        #expect(await sched.deliveredCount() == 1)
        status = await rc.reconcile(now: now.addingTimeInterval(10))
        #expect(await sched.deliveredCount() == 1)   // not repeated at every launch
        #expect(status.overdue == [id])
    }

    @Test func veryOldReminderIsListedButNotAnnounced() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(-5 * 24 * 3600))
        let status = await rc.reconcile(now: now)
        #expect(status.overdue == [id])
        #expect(await sched.deliveredCount() == 0)
    }

    @Test func dismissedOverdueDisappears() async throws {
        let (sb, store, _, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        let fire = now.addingTimeInterval(-60)
        let id = try await note(store, in: sb, reminder: fire)
        _ = await rc.reconcile(now: now)
        let stored = try #require(try store.index.summary(id: id)?.reminder)
        await rc.dismiss(noteID: id, fireDate: stored)
        let status = await rc.reconcile(now: now)
        #expect(status.overdue.isEmpty)
    }

    @Test func permissionDeniedStillTracksButNeverSchedules() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        await sched.setPermission(.denied)
        let now = Date()
        let id = try await note(store, in: sb, reminder: now.addingTimeInterval(100))
        let status = await rc.reconcile(now: now)
        #expect(status.permission == .denied)
        #expect(status.upcoming == [id])
        #expect(await sched.calls() == 0)
    }

    @Test func perDeviceDisableCancelsEverything() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        _ = try await note(store, in: sb, reminder: now.addingTimeInterval(100))
        _ = await rc.reconcile(now: now)
        #expect(await sched.pendingCount() == 1)
        await rc.setEnabled(false)
        #expect(await sched.pendingCount() == 0)
        #expect(await rc.isEnabled() == false)
        await rc.setEnabled(true)
        #expect(await sched.pendingCount() == 1)
    }

    @Test func neverExceedsOSPendingLimit() async throws {
        let (sb, store, sched, rc) = try await setup()
        defer { withExtendedLifetime(sb) {} }
        let now = Date()
        for i in 0..<70 { _ = try await note(store, in: sb, reminder: now.addingTimeInterval(Double(100 + i))) }
        let status = await rc.reconcile(now: now)
        #expect(status.scheduled == 60)
        #expect(await sched.pendingCount() == 60)
    }

    @Test func identifierRoundTrip() {
        let id = UUID()
        let ident = ReminderNotification.identifier(noteID: id, fireDate: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ReminderNotification.noteID(fromIdentifier: ident) == id)
    }
}
