import WalletCore
import Foundation

/// Untrusted discovery input, never a replacement for peer/header/filter checks.
/// Census publication preserves all overlays; WalletCore validates the clearnet
/// subset consumed by the GUI wallet. Overlay validation belongs to this tool.
struct PublicationCatalog: Codable, Equatable, Sendable {
    typealias Entry = WalletCore.CensusCatalog.Entry
    var schemaVersion: Int
    var date: String
    var tip: Int32
    var networks: [String: [Entry]]
    init(schemaVersion: Int = 1, date: String, tip: Int32, networks: [String: [Entry]]) {
        self.schemaVersion = schemaVersion; self.date = date; self.tip = tip; self.networks = networks
    }
    static let maximumBytes = 4 * 1_024 * 1_024
    static let overlayCap = 2_000

    enum Invalid: String, Error, LocalizedError {
        case schema, date, expired, future, size, endpoint, height, duplicate, diversity
        var errorDescription: String? { "Invalid census peer list: \(rawValue)." }
    }

    static func day(_ text: String) -> Int? { WalletCore.CensusCatalog.day(text) }

    static func decode(_ data: Data, now: Date = Date(), requireFresh: Bool = true) throws -> Self {
        guard data.count <= maximumBytes else { throw Invalid.size }
        return try JSONDecoder().decode(Self.self, from: data).validated(now: now, requireFresh: requireFresh)
    }

    func validated(now: Date = Date(), requireFresh: Bool = true) throws -> Self {
        guard schemaVersion == 1, Set(networks.keys) == Set(["clearnet", "tor", "i2p"]) else { throw Invalid.schema }
        // Keep the consumer's current clearnet validation authoritative.
        let clearnet = try WalletCore.CensusCatalog(schemaVersion: schemaVersion, date: date,
            tip: tip, networks: networks).validated(now: now, requireFresh: requireFresh)
        var result = self
        result.networks["clearnet"] = clearnet.networks["clearnet"]
        for overlay in [OverlayNetwork.tor, .i2p] {
            result.networks[overlay.rawValue] = try validatedEntries(overlay)
        }
        return result
    }

    private func validatedEntries(_ overlay: OverlayNetwork) throws -> [Entry] {
        let entries = networks[overlay.rawValue] ?? []
        guard entries.count <= Self.overlayCap else { throw Invalid.size }
        var seen = Set<PeerEndpoint>()
        let canonical = try entries.map { input in
            let entry = try validatedEntry(input, overlay: overlay)
            guard seen.insert(entry.endpoint).inserted else { throw Invalid.duplicate }
            return entry
        }
        return canonical.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    private func validatedEntry(_ input: Entry, overlay: OverlayNetwork) throws -> Entry {
        var entry = input
        guard entry.port > 0, entry.userAgent.utf8.count <= 256,
              !entry.userAgent.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let host = Self.canonicalHost(entry.host, overlay: overlay) else { throw Invalid.endpoint }
        guard Self.nearTip(entry.startHeight, tip: tip) else { throw Invalid.height }
        entry.host = host
        return entry
    }

    static func nearTip(_ height: Int32, tip: Int32) -> Bool {
        WalletCore.CensusCatalog.nearTip(height, tip: tip)
    }

    /// Numeric clearnet only. Collapse mapped IPv4 and IPv6 text aliases
    /// before deduplication and diversity; never invoke DNS here.
    static func canonicalHost(_ text: String, overlay: OverlayNetwork) -> String? {
        guard text.utf8.count <= 255, text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let host = text.lowercased()
        if overlay != .clearnet { return canonicalOverlay(host, overlay: overlay) }
        return WalletCore.CensusCatalog.canonicalHost(host)
    }

    private static func canonicalOverlay(_ host: String, overlay: OverlayNetwork) -> String? {
            let suffix = overlay == .tor ? ".onion" : ".b32.i2p"
            guard host.hasSuffix(suffix) else { return nil }
            let label = String(host.dropLast(suffix.count))
            guard let bytes = decodeBase32(label) else { return nil }
            if overlay == .tor {
                guard label.count == 56, bytes.count == 35, bytes[34] == 3 else { return nil }
                let checksum = OnionChecksum.hash(Array(".onion checksum".utf8) + Array(bytes.prefix(32)) + [3])
                guard bytes[32] == checksum[0], bytes[33] == checksum[1] else { return nil }
            } else {
                guard label.count == 52, bytes.count == 32 else { return nil }
            }
            return host
    }

    private static func decodeBase32(_ text: String) -> [UInt8]? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var buffer: UInt32 = 0, bits = 0
        var result: [UInt8] = []
        for ch in text.utf8 {
            guard let value = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; result.append(UInt8((buffer >> bits) & 255)) }
        }
        guard buffer & ((1 << bits) - 1) == 0 else { return nil }
        return result
    }
}
