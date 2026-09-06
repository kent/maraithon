import Foundation

/// Persists `(CNContact.identifier -> payload_hash)` so Contacts sync only
/// re-uploads rows whose reachable CRM details changed.
///
/// Contacts.framework does not expose a cheap last-modified timestamp for
/// every contact, so the source computes a stable hash from the fields it
/// sends to Maraithon. A contact with no changes stays out of subsequent
/// batches; the server still upserts by guid if a row is sent again.
struct ContactsCursor: @unchecked Sendable {
    static let defaultsKey = "com.maraithon.companion.contacts.cursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var snapshot: [String: String] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) else {
            return [:]
        }
        var out: [String: String] = [:]
        out.reserveCapacity(raw.count)
        for (guid, value) in raw {
            if let hash = value as? String, !hash.isEmpty {
                out[guid] = hash
            }
        }
        return out
    }

    /// A scan passes one prior snapshot to avoid deserializing it per contact.
    func shouldPush(
        guid: String,
        payloadHash: String,
        since priorSnapshot: [String: String]? = nil
    ) -> Bool {
        guard !guid.isEmpty, !payloadHash.isEmpty else { return true }
        return (priorSnapshot ?? snapshot)[guid] != payloadHash
    }

    func advance(_ entries: [(guid: String, payloadHash: String)]) {
        guard !entries.isEmpty else { return }
        var raw = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        for entry in entries where !entry.guid.isEmpty && !entry.payloadHash.isEmpty {
            raw[entry.guid] = entry.payloadHash
        }
        defaults.set(raw, forKey: Self.defaultsKey)
    }

    var trackedCount: Int {
        defaults.dictionary(forKey: Self.defaultsKey)?.count ?? 0
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
