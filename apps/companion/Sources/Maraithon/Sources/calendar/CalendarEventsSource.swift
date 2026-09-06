import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for macOS Calendar.app, backed by
/// EventKit. Polls every 5 minutes by default — calendars change less
/// frequently than reminders (mostly meeting invites and reschedules)
/// but more frequently than notes (recurring expansions, accepted
/// invites, time edits).
///
/// Window: `[now - 90 days, now + 180 days]`. Each cycle re-fetches the
/// whole window because EventKit doesn't expose a cheap "events
/// modified since" query. The cursor is a `(guid → modified_at)` map
/// so the source only re-pushes occurrences whose `lastModifiedDate`
/// has actually advanced; the rest are dropped before they hit the
/// wire.
///
/// `@MainActor` because of the `@Observable` status publisher; the
/// EventKit + HTTP work happens off-main and re-enters the main actor
/// only to update status.
@MainActor
final class CalendarEventsSource: SourceProtocol {
    let id: String = "calendar"
    let displayName: String = "Calendar"
    let symbol: String = "calendar"
    let statusPublisher: SourceStatusPublisher

    /// Outbox closure — same shape as the other sources, so tests can
    /// capture payloads without going through HTTP.
    typealias Outbox = @Sendable (UUID, [CalendarEventPayload]) async throws -> SyncOutcome

    /// Days of past events to mirror. A full year so "what did I do
    /// last quarter?" works and — since edits are only observed while
    /// an event is inside the fetch window — reschedules or renames of
    /// months-old events still propagate instead of leaving the server
    /// copy stale. A busy corporate calendar is still only a few
    /// thousand rows per year, and the cursor diff keeps re-pushes to
    /// actual changes.
    static let defaultLookbackDays: TimeInterval = 365

    /// Days of upcoming events to mirror. A full year covers annual
    /// recurrences (birthdays, renewals, yearly planning) that a
    /// six-month horizon silently dropped until they drifted close.
    static let defaultLookaheadDays: TimeInterval = 365

    private let cursor: CalendarCursor
    private let eventLog: EventLog
    private let outbox: Outbox
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let reader: CalendarEventReader
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool
    private let lookbackDays: TimeInterval
    private let lookaheadDays: TimeInterval
    private let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?
    private var didRequestAccess: Bool = false

    init(
        reader: CalendarEventReader = CalendarEventReader(),
        cursor: CalendarCursor = CalendarCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lookbackDays: TimeInterval = CalendarEventsSource.defaultLookbackDays,
        lookaheadDays: TimeInterval = CalendarEventsSource.defaultLookaheadDays,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        outbox: @escaping Outbox
    ) {
        self.reader = reader
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // 4× base cadence under Low Power Mode, capped at 30 minutes.
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 1800)
        self.batchLimit = batchLimit
        self.lookbackDays = lookbackDays
        self.lookaheadDays = lookaheadDays
        self.lowPowerProbe = lowPowerProbe
        self.clock = clock
        self.statusPublisher = SourceStatusPublisher(sourceID: "calendar", state: .disconnected)
    }

    /// Convenience init wiring the outbox to a `CalendarIngest`. The
    /// designated init stays available for tests that want to capture
    /// payloads directly.
    convenience init(
        reader: CalendarEventReader = CalendarEventReader(),
        cursor: CalendarCursor = CalendarCursor(),
        eventLog: EventLog,
        ingest: CalendarIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lookbackDays: TimeInterval = CalendarEventsSource.defaultLookbackDays,
        lookaheadDays: TimeInterval = CalendarEventsSource.defaultLookaheadDays,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.init(
            reader: reader,
            cursor: cursor,
            eventLog: eventLog,
            deviceIdProvider: deviceIdProvider,
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            batchLimit: batchLimit,
            lookbackDays: lookbackDays,
            lookaheadDays: lookaheadDays,
            lowPowerProbe: lowPowerProbe,
            outbox: { deviceId, events in
                try await ingest.push(deviceId: deviceId, events: events)
            }
        )
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("calendar.start", source: .calendar)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        statusPublisher.update(state: .paused)
        eventLog.info("calendar.pause", source: .calendar)
    }

    func syncNow() async throws {
        eventLog.info("calendar.sync_now", source: .calendar)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("calendar.clear_local_state", source: .calendar)
    }

    // MARK: - Polling

    private func pollLoop() async {
        let timer = AsyncTimerSequence(
            interval: .seconds(pollInterval),
            clock: .continuous
        )
        await tickIfNeeded(force: true)
        for await _ in timer {
            if Task.isCancelled || isPaused { break }
            await tickIfNeeded(force: false)
        }
    }

    private func tickIfNeeded(force: Bool) async {
        let lowPower = lowPowerProbe()
        if lowPower != lastLowPowerState {
            lastLowPowerState = lowPower
            eventLog.info(
                "calendar.cadence_changed",
                source: .calendar,
                payload: [
                    "low_power": String(lowPower),
                    "interval_seconds": String(
                        Int(lowPower ? lowPowerPollInterval : pollInterval)
                    )
                ]
            )
        }
        if !force, lowPower, let last = lastTickAt {
            let elapsed = ContinuousClock().now - last
            if elapsed < .seconds(lowPowerPollInterval) { return }
        }
        lastTickAt = ContinuousClock().now
        do {
            try await runCycle()
        } catch {
            statusPublisher.update(
                state: .error(reason: String(describing: error))
            )
            eventLog.error(
                "calendar.cycle_failed",
                source: .calendar,
                payload: ["error": String(describing: error)]
            )
        }
    }

    /// Single sync cycle: fetch the sliding window, diff against the
    /// cursor, batch-push, advance the cursor only on POST success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)

        // Authorization gate. EventKit's `.notDetermined` state is the
        // one we explicitly prompt for; everything else is a terminal
        // user choice we surface to the UI without retrying.
        let auth = reader.authorizationState()
        switch auth {
        case .authorized:
            break
        case .notDetermined:
            if !didRequestAccess {
                didRequestAccess = true
                do {
                    let granted = try await reader.requestAccess()
                    eventLog.info(
                        "calendar.access_request",
                        source: .calendar,
                        payload: ["granted": String(granted)]
                    )
                } catch {
                    eventLog.error(
                        "calendar.access_request_failed",
                        source: .calendar,
                        payload: ["error": String(describing: error)]
                    )
                }
            }
            if reader.authorizationState() != .authorized {
                statusPublisher.update(
                    state: .needsAttention(reason: "calendar_not_authorized")
                )
                return
            }
        default:
            statusPublisher.update(
                state: .needsAttention(reason: "calendar_not_authorized")
            )
            eventLog.warning(
                "calendar.not_authorized",
                source: .calendar,
                payload: ["state": String(describing: auth)]
            )
            return
        }

        let now = clock()
        let start = now.addingTimeInterval(-lookbackDays * 86_400)
        let end = now.addingTimeInterval(lookaheadDays * 86_400)

        let snapshots = try await reader.fetchEvents(start: start, end: end)

        // Diff against the cursor: only re-push rows whose
        // lastModifiedDate is strictly newer than the persisted one.
        // Events without a modifiedAt push only on their first sighting.
        let priorSnapshot = cursor.snapshot
        let candidates = snapshots.filter { snap in
            cursor.shouldPush(guid: snap.guid, modifiedAt: snap.modifiedAt, since: priorSnapshot)
        }
        // Newest-modified first so the most relevant events ship before
        // historical ones. Events without `modifiedAt` sort to the tail;
        // tie-break by guid for stable ordering.
        let sortedCandidates = candidates.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.guid < rhs.guid
            }
        }
        if sortedCandidates.isEmpty {
            eventLog.debug(
                "calendar.cycle_empty",
                source: .calendar,
                payload: [
                    "scanned": String(snapshots.count),
                    "tracked": String(cursor.trackedCount)
                ]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        // Ship every candidate, chunked at `batchLimit` per POST, so a
        // burst larger than one batch drains within the cycle instead
        // of starving the oldest-modified tail. Advancing per chunk —
        // including nil-modification sightings at the sentinel — means
        // a failure mid-drain keeps earlier progress and the remainder
        // retries next cycle.
        let deviceId = deviceIdProvider()
        var pushResult = PushResult.empty
        var chunkStart = 0
        while chunkStart < sortedCandidates.count {
            let chunkEnd = min(chunkStart + batchLimit, sortedCandidates.count)
            let chunk = Array(sortedCandidates[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
            let chunkResult = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: chunk
            )
            cursor.advance(chunkResult.processedSnapshots.map {
                (guid: $0.guid, modifiedAt: $0.modifiedAt)
            })
            pushResult.merge(chunkResult)
        }

        statusPublisher.recordSync(
            at: Date(),
            accepted: pushResult.outcome.accepted,
            duplicate: pushResult.outcome.duplicate
        )
        statusPublisher.update(state: .connected)

        let calendarCounts = sortedCandidates
            .compactMap(\.calendarName)
            .reduce(into: [String: Int]()) { acc, name in
                acc[name, default: 0] += 1
            }

        eventLog.info(
            "calendar.cycle_pushed",
            source: .calendar,
            payload: [
                "scanned": String(snapshots.count),
                "pushed": String(sortedCandidates.count),
                "accepted": String(pushResult.outcome.accepted),
                "duplicate": String(pushResult.outcome.duplicate),
                "invalid": String(pushResult.outcome.invalid),
                "tracked": String(cursor.trackedCount),
                "window_start": Self.isoString(from: start),
                "window_end": Self.isoString(from: end),
                "calendars": Self.calendarSummary(calendarCounts)
            ]
        )
    }

    private struct PushResult {
        var outcome: SyncOutcome
        var processedSnapshots: [CalendarEventReader.Snapshot]

        static var empty: PushResult {
            PushResult(
                outcome: SyncOutcome(accepted: 0, duplicate: 0),
                processedSnapshots: []
            )
        }

        mutating func merge(_ other: PushResult) {
            outcome = SyncOutcome(
                accepted: outcome.accepted + other.outcome.accepted,
                duplicate: outcome.duplicate + other.outcome.duplicate,
                invalid: outcome.invalid + other.outcome.invalid
            )
            processedSnapshots.append(contentsOf: other.processedSnapshots)
        }
    }

    private func pushWithInvalidBatchIsolation(
        deviceId: UUID,
        snapshots: [CalendarEventReader.Snapshot]
    ) async throws -> PushResult {
        guard !snapshots.isEmpty else { return .empty }

        do {
            let payloads = snapshots.map(Self.payload(from:))
            let outcome = try await outbox(deviceId, payloads)
            return PushResult(outcome: outcome, processedSnapshots: snapshots)
        } catch {
            guard Self.isInvalidBatchError(error) else { throw error }

            if snapshots.count == 1 {
                let snapshot = snapshots[0]
                eventLog.warning(
                    "calendar.event_skipped_invalid",
                    source: .calendar,
                    payload: [
                        "guid_prefix": Self.guidPrefix(snapshot.guid),
                        "modified_at": snapshot.modifiedAt.map(Self.isoString(from:)) ?? "<nil>",
                        "calendar": Self.redactedLogToken(snapshot.calendarName),
                        "reason": "invalid_batch"
                    ]
                )
                return PushResult(
                    outcome: SyncOutcome(accepted: 0, duplicate: 0, invalid: 1),
                    processedSnapshots: [snapshot]
                )
            }

            let midpoint = snapshots.count / 2
            var left = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: Array(snapshots[..<midpoint])
            )
            let right = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: Array(snapshots[midpoint...])
            )
            left.merge(right)
            return left
        }
    }

    private nonisolated static func isInvalidBatchError(_ error: Error) -> Bool {
        guard let clientError = error as? MaraithonClientError else {
            return false
        }
        switch clientError {
        case let .clientError(status, body):
            return status == 400 && (body?.contains("invalid_batch") ?? false)
        default:
            return false
        }
    }

    // MARK: - Mapping

    /// Static mapping from reader snapshot to wire payload. Kept
    /// `nonisolated` so tests can call it without a live `EKEventStore`.
    nonisolated static func payload(
        from snapshot: CalendarEventReader.Snapshot
    ) -> CalendarEventPayload {
        CalendarEventPayload(
            guid: snapshot.guid,
            // `local_id` mirrors the other sources' "<prefix>:<id>"
            // shape. Reminders use `r:`; we use `cal:` here so a log
            // reader can tell calendar local IDs apart at a glance.
            localId: "cal:\(snapshot.masterIdentifier)",
            calendarName: snapshot.calendarName,
            calendarColor: snapshot.calendarColor,
            title: snapshot.title,
            notes: snapshot.notes,
            location: snapshot.location,
            startAt: snapshot.startAt,
            endAt: snapshot.endAt,
            isAllDay: snapshot.isAllDay,
            isRecurring: snapshot.isRecurring,
            organizerEmail: snapshot.organizerEmail,
            attendeesCount: snapshot.attendeesCount,
            attendeeEmails: snapshot.attendeeEmails,
            createdAt: snapshot.createdAt,
            modifiedAt: snapshot.modifiedAt
        )
    }

    /// Compact "calendar_name: count" summary for log lines, sorted by
    /// count descending with redacted names so account emails don't leak
    /// into local diagnostics.
    private nonisolated static func calendarSummary(_ counts: [String: Int]) -> String {
        counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\(Self.redactedLogToken($0.key))=\($0.value)" }
            .joined(separator: ",")
    }

    private nonisolated static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private nonisolated static func guidPrefix(_ guid: String) -> String {
        String(guid.prefix(16))
    }

    private nonisolated static func redactedLogToken(_ text: String?) -> String {
        CalendarRedactor.redact(text).replacingOccurrences(of: " ", with: "_")
    }
}

/// Redaction helper for calendar title / notes / location content.
/// Calendar text is just as user-written as notes / reminders, so we
/// never log it verbatim — only a length-tagged short prefix.
///
/// Kept as a free enum (not a method on the source) so detached
/// `Task`s can call it without touching `@MainActor` state.
enum CalendarRedactor {
    static let prefixLength = 12

    static func redact(_ text: String?) -> String {
        guard let text else { return "<nil>" }
        if text.count <= prefixLength {
            return "[len=\(text.count)] \(text)"
        }
        let prefix = String(text.prefix(prefixLength))
        return "[len=\(text.count)] \(prefix)…"
    }
}
