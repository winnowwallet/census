import CryptoKit
import Foundation
import WalletCore

typealias PeerList = PublicationCatalog
let peerListOverlayCap = PublicationCatalog.overlayCap

func atTip(_ record: Record, tip: Int32) -> Bool {
    guard let height = record.startHeight else { return false }
    return PublicationCatalog.nearTip(height, tip: tip)
}

/// Where a candidate stands in the day's selection order. Clearnet keeps the
/// fastest duplicate and the netblock rule limits any one operator. Onion
/// and I2P addresses have no netblock, so they are ordered by a per-day hash
/// of the address instead of by latency: the overlay cap then takes a sample
/// of the day's reachable hidden services rather than the 2,000 fastest
/// responders, which one operator running many services on good hardware
/// could otherwise fill (IR-004). The date keys the hash, so the same day
/// replays to the same list and a different day samples differently.
func selectionRank(_ entry: PublicationCatalog.Entry, latencyMs: Int, overlay: OverlayNetwork,
                   date: String) -> String {
    if overlay == .clearnet { return String(format: "%012d", latencyMs) }
    return SHA256.hash(data: Data("\(date)\u{0}\(entry.host)".utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Canonicalize before deduplication. Order by `selectionRank`, then enforce
/// address diversity and overlay caps. Source dates are never rebuilt.
func makePeerList(_ records: [Record], tip: Int32, date: String) throws -> PeerList {
    var networks: [String: [PublicationCatalog.Entry]] = ["clearnet": [], "tor": [], "i2p": []]
    var candidates: [(PublicationCatalog.Entry, Int, OverlayNetwork)] = []
    for record in records where record.outcome == "ok" && atTip(record, tip: tip) {
        let overlay = OverlayNetwork(host: record.host)
        guard let host = PublicationCatalog.canonicalHost(record.host, overlay: overlay),
              let ua = record.userAgent, ua.utf8.count <= 256,
              !ua.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let height = record.startHeight, record.port > 0, record.latencyMs >= 0,
              let services = record.services, services & 64 != 0 else { continue }
        if overlay == .clearnet && record.port != 8333 { continue }
        candidates.append((.init(host: host, port: record.port, userAgent: ua, startHeight: height), record.latencyMs, overlay))
    }
    var seen = Set<PeerEndpoint>(), blocks = Set<String>()
    let ranked = candidates.map { (entry: $0.0, overlay: $0.2, rank: selectionRank($0.0, latencyMs: $0.1, overlay: $0.2, date: date)) }
    for (entry, overlay, _) in ranked.sorted(by: {
        ($0.rank, $0.entry.host, $0.entry.port, $0.entry.userAgent, $0.entry.startHeight) <
        ($1.rank, $1.entry.host, $1.entry.port, $1.entry.userAgent, $1.entry.startHeight)
    }) {
        guard networks[overlay.rawValue]!.count < peerListOverlayCap, seen.insert(entry.endpoint).inserted else { continue }
        if overlay == .clearnet {
            guard let block = entry.endpoint.netblock, blocks.insert(block).inserted else { continue }
        }
        networks[overlay.rawValue]!.append(entry)
    }
    return try PublicationCatalog(date: date, tip: tip, networks: networks).validated(requireFresh: false)
}

func writePeerList(_ records: [Record], tip: Int32, observedAt: String, to url: URL) throws -> PeerList {
    let list = try makePeerList(records, tip: tip, date: String(observedAt.prefix(10)))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(list).write(to: url, options: .atomic)
    return list
}
