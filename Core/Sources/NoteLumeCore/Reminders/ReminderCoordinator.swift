import Foundation

public enum NotificationPermission: Sendable, Equatable {
    case notDetermined, authorized, denied
}

public struct ReminderNotification: Sendable, Equatable {
    /// `<note-uuid>|<unix-seconds>`: encodes the reminder revision, so a changed
    /// date is a different notification and the same revision is never scheduled twice.
    public var identifier: String
    public var noteID: UUID
    public var title: String
    public var body: String
    public var fireDate: Date
    public var isMissed: Bool

    static func identifier(noteID: UUID, fireDate: Date) -> String {
        "\(noteID.uuidString.lowercased())|\(Int(fireDate.timeIntervalSince1970))"
    }

    public static func noteID(fromIdentifier id: String) -> UUID? {
        id.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
    }
}

/// Abstraction over `UNUserNotificationCenter` so scheduling logic is testable.
public protocol NotificationScheduling: Sendable {
    func permission() async -> NotificationPermission
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> Set<String>
    func schedule(_ notification: ReminderNotification) async throws
    func deliverNow(_ notification: ReminderNotification) async throws
    func cancelPending(identifiers: [String]) async
}

public struct ReminderStatus: Sendable, Equatable {
    public var permission: NotificationPermission
    public var enabledOnThisDevice: Bool
    public var scheduled = 0
    public var overdue: [UUID] = []
    public var upcoming: [UUID] = []
}

/// Keeps OS notifications in step with the reminders found in note files
/// (requirements §8). Safe to run any number of times: at launch, after wake,
/// after external edits. Bookkeeping lives in the local SQLite database only.
public actor ReminderCoordinator {
    public static let enabledSettingKey = "reminders.enabled"

    /// macOS keeps at most 64 pending local notifications per app.
    static let pendingLimit = 60
    /// Reminders that came due while the app/Mac was off are announced once
    /// if they are not older than this.
    public var missedLookback: TimeInterval = 24 * 3600

    private let index: NoteIndex
    private let scheduler: NotificationScheduling

    public init(index: NoteIndex, scheduler: NotificationScheduling) {
        self.index = index
        self.scheduler = scheduler
    }

    public func isEnabled() -> Bool {
        ((try? index.setting(Self.enabledSettingKey)) ?? nil) != "false"
    }

    /// Per-device switch: synchronized reminders would otherwise notify on every Mac.
    public func setEnabled(_ enabled: Bool) async {
        try? index.setSetting(Self.enabledSettingKey, enabled ? "true" : "false")
        _ = await reconcile()
    }

    public func dismiss(noteID: UUID, fireDate: Date) {
        try? index.setReminderState(noteID: noteID, fireDate: fireDate, state: .dismissed)
    }

    @discardableResult
    public func reconcile(now: Date = Date()) async -> ReminderStatus {
        let permission = await scheduler.permission()
        let enabled = isEnabled()
        var status = ReminderStatus(permission: permission, enabledOnThisDevice: enabled)

        let notes = (try? index.reminderNotes()) ?? []
        let records = Dictionary(
            ((try? index.reminderRecords()) ?? []).map { (key(noteID: $0.noteID, fireDate: $0.fireDate), $0.state) },
            uniquingKeysWith: { _, new in new })

        var desired: [String: ReminderNotification] = [:]   // future reminders to be pending
        var current: [UUID: Date] = [:]

        for note in notes {
            guard let fire = note.reminder else { continue }
            current[note.id] = fire
            let k = key(noteID: note.id, fireDate: fire)
            if fire > now {
                status.upcoming.append(note.id)
                desired[ReminderNotification.identifier(noteID: note.id, fireDate: fire)] = makeNotification(note, fire: fire, missed: false)
            } else if records[k] != .dismissed {
                status.overdue.append(note.id)
            }
        }

        // Without permission or with reminders off on this Mac we only track state for the menubar.
        guard enabled, permission == .authorized else {
            if !enabled { await scheduler.cancelPending(identifiers: Array(await scheduler.pendingIdentifiers())) }
            try? index.pruneReminderRecords(keeping: current)
            return status
        }

        // Cancel notifications whose revision no longer matches any note (edited, removed, completed).
        let pending = await scheduler.pendingIdentifiers()
        let stale = pending.filter { desired[$0] == nil }
        if !stale.isEmpty { await scheduler.cancelPending(identifiers: Array(stale)) }

        // Schedule soonest first, never exceeding the OS limit; skip revisions already pending.
        let toSchedule = desired.values.sorted { $0.fireDate < $1.fireDate }.prefix(Self.pendingLimit)
        for n in toSchedule where !pending.contains(n.identifier) {
            do {
                try await scheduler.schedule(n)
                try? index.setReminderState(noteID: n.noteID, fireDate: n.fireDate, state: .scheduled)
            } catch { /* retried on the next reconcile */ }
        }
        status.scheduled = min(toSchedule.count, Self.pendingLimit)

        // Missed reminders: announce once per revision, if recent and not already delivered.
        let delivered = await scheduler.deliveredIdentifiers()
        for id in status.overdue {
            guard let fire = current[id], let note = notes.first(where: { $0.id == id }) else { continue }
            let k = key(noteID: id, fireDate: fire)
            let identifier = ReminderNotification.identifier(noteID: id, fireDate: fire)
            if delivered.contains(identifier) || records[k] == .delivered {
                try? index.setReminderState(noteID: id, fireDate: fire, state: .delivered)
                continue
            }
            if now.timeIntervalSince(fire) <= missedLookback {
                do {
                    try await scheduler.deliverNow(makeNotification(note, fire: fire, missed: true))
                    try? index.setReminderState(noteID: id, fireDate: fire, state: .delivered)
                } catch { /* try again next time */ }
            } else {
                try? index.setReminderState(noteID: id, fireDate: fire, state: .delivered)   // too old to announce; stays listed as overdue
            }
        }

        try? index.pruneReminderRecords(keeping: current)
        return status
    }

    private func key(noteID: UUID, fireDate: Date) -> String { ReminderNotification.identifier(noteID: noteID, fireDate: fireDate) }

    private func makeNotification(_ note: NoteSummary, fire: Date, missed: Bool) -> ReminderNotification {
        ReminderNotification(
            identifier: ReminderNotification.identifier(noteID: note.id, fireDate: fire),
            noteID: note.id, title: note.title,
            body: note.preview.isEmpty ? (missed ? "Reminder" : "Reminder for this note") : note.preview,
            fireDate: fire, isMissed: missed)
    }
}
