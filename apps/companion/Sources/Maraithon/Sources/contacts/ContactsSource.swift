import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for macOS Contacts.app, backed by
/// Contacts.framework. Contacts change infrequently, so the source polls on a
/// quiet cadence and uses a payload hash cursor instead of re-uploading every
/// row on each cycle.
@MainActor
final class ContactsSource: SourceProtocol {
    let id: String = "contacts"
    let displayName: String = "Contacts"
    let symbol: String = "person.crop.circle.badge.checkmark"
    let statusPublisher: SourceStatusPublisher

    typealias Outbox = @Sendable (UUID, [ContactPayload]) async throws -> SyncOutcome

    private let reader: ContactsReader
    private let cursor: ContactsCursor
    private let eventLog: EventLog
    private let outbox: Outbox
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?
    private var didRequestAccess: Bool = false

    init(
        reader: ContactsReader = ContactsReader(),
        cursor: ContactsCursor = ContactsCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 600,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 50,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        outbox: @escaping Outbox
    ) {
        self.reader = reader
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 3_600)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.statusPublisher = SourceStatusPublisher(sourceID: "contacts", state: .disconnected)
    }

    convenience init(
        reader: ContactsReader = ContactsReader(),
        cursor: ContactsCursor = ContactsCursor(),
        eventLog: EventLog,
        ingest: ContactsIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 600,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 50,
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
            lowPowerProbe: lowPowerProbe,
            outbox: { deviceId, contacts in
                try await ingest.push(deviceId: deviceId, contacts: contacts)
            }
        )
    }

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("contacts.start", source: .contacts)
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
        eventLog.info("contacts.pause", source: .contacts)
    }

    func syncNow() async throws {
        eventLog.info("contacts.sync_now", source: .contacts)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("contacts.clear_local_state", source: .contacts)
    }

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
                "contacts.cadence_changed",
                source: .contacts,
                payload: [
                    "low_power": String(lowPower),
                    "interval_seconds": String(Int(lowPower ? lowPowerPollInterval : pollInterval))
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
            statusPublisher.update(state: .error(reason: String(describing: error)))
            eventLog.error(
                "contacts.cycle_failed",
                source: .contacts,
                payload: ["error": String(describing: error)]
            )
        }
    }

    func runCycle() async throws {
        statusPublisher.update(state: .syncing)

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
                        "contacts.access_request",
                        source: .contacts,
                        payload: ["granted": String(granted)]
                    )
                } catch {
                    eventLog.error(
                        "contacts.access_request_failed",
                        source: .contacts,
                        payload: ["error": String(describing: error)]
                    )
                }
            }
            if reader.authorizationState() != .authorized {
                statusPublisher.update(state: .needsAttention(reason: "contacts_not_authorized"))
                return
            }
        default:
            statusPublisher.update(state: .needsAttention(reason: "contacts_not_authorized"))
            eventLog.warning(
                "contacts.not_authorized",
                source: .contacts,
                payload: ["state": String(describing: auth)]
            )
            return
        }

        let snapshots = try await Task.detached(priority: .utility) { [reader] in
            try await reader.fetchAllContacts()
        }.value

        let priorSnapshot = cursor.snapshot
        let candidates = snapshots.filter {
            cursor.shouldPush(guid: $0.guid, payloadHash: $0.payloadHash, since: priorSnapshot)
        }
        let sortedCandidates = candidates.sorted {
            let left = $0.displayName ?? $0.organizationName ?? $0.guid
            let right = $1.displayName ?? $1.organizationName ?? $1.guid
            if left == right { return $0.guid < $1.guid }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        if sortedCandidates.isEmpty {
            eventLog.debug(
                "contacts.cycle_empty",
                source: .contacts,
                payload: [
                    "scanned": String(snapshots.count),
                    "tracked": String(cursor.trackedCount)
                ]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        let deviceId = deviceIdProvider()
        let limit = max(batchLimit, 1)
        var accepted = 0
        var duplicate = 0
        var invalid = 0
        var pushed = 0
        var batchIndex = 0
        var batchStart = sortedCandidates.startIndex

        while batchStart < sortedCandidates.endIndex {
            try Task.checkCancellation()

            let batchEnd =
                sortedCandidates.index(
                    batchStart,
                    offsetBy: limit,
                    limitedBy: sortedCandidates.endIndex
                ) ?? sortedCandidates.endIndex
            let batch = Array(sortedCandidates[batchStart..<batchEnd])
            let outcome = try await outbox(deviceId, batch.map(Self.payload(from:)))

            cursor.advance(
                batch.map { snapshot in
                    (guid: snapshot.guid, payloadHash: snapshot.payloadHash)
                }
            )

            accepted += outcome.accepted
            duplicate += outcome.duplicate
            invalid += outcome.invalid
            pushed += batch.count
            batchIndex += 1

            eventLog.info(
                "contacts.batch_pushed",
                source: .contacts,
                payload: [
                    "batch": String(batchIndex),
                    "batch_size": String(batch.count),
                    "accepted": String(outcome.accepted),
                    "duplicate": String(outcome.duplicate),
                    "invalid": String(outcome.invalid),
                    "tracked": String(cursor.trackedCount)
                ]
            )

            batchStart = batchEnd
        }

        statusPublisher.recordSync(
            at: Date(),
            accepted: accepted,
            duplicate: duplicate,
            failed: invalid,
            issueSummary: invalid > 0 ? "contacts_invalid" : nil
        )
        statusPublisher.update(state: .connected)

        eventLog.info(
            "contacts.cycle_pushed",
            source: .contacts,
            payload: [
                "scanned": String(snapshots.count),
                "pushed": String(pushed),
                "accepted": String(accepted),
                "duplicate": String(duplicate),
                "invalid": String(invalid),
                "batches": String(batchIndex),
                "tracked": String(cursor.trackedCount)
            ]
        )
    }

    nonisolated static func payload(from snapshot: ContactsReader.Snapshot) -> ContactPayload {
        ContactPayload(
            guid: snapshot.guid,
            localId: "contact:\(snapshot.guid)",
            displayName: snapshot.displayName,
            firstName: snapshot.firstName,
            middleName: snapshot.middleName,
            lastName: snapshot.lastName,
            nickname: snapshot.nickname,
            organizationName: snapshot.organizationName,
            departmentName: snapshot.departmentName,
            jobTitle: snapshot.jobTitle,
            emails: snapshot.emails,
            phones: snapshot.phones,
            urls: snapshot.urls,
            postalAddresses: snapshot.postalAddresses.map {
                ContactPostalAddressPayload(
                    label: $0.label,
                    street: $0.street,
                    city: $0.city,
                    state: $0.state,
                    postalCode: $0.postalCode,
                    country: $0.country
                )
            },
            payloadHash: snapshot.payloadHash
        )
    }
}
