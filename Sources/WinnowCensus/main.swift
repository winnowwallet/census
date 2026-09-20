import Darwin
import Foundation
import CryptoKit
import WalletCore

/// Peer census: dial a list of nodes with the same `PeerConnection` the app
/// uses and record what each one reports in its handshake — user agent,
/// starting height, service bits, and the BIP133 fee filter it pushes right
/// after `verack`. One JSON object per node, then a breakdown.
///
/// Read-only and polite: version/verack, a short wait for `feefilter`, then
/// disconnect. Nothing is requested. The user agent names the tool so an
/// operator reading their logs knows what dialled them.
///
/// The point of using Winnow's own connection rather than a generic crawler:
/// a peer that fails *this* handshake is one the wallet could never use, so
/// the numbers describe Winnow's world, not the abstract network.
///
/// Input: a Bitnodes/btcnodes snapshot (`{"nodes": {"host:port": [...]}}`)
/// or a plain list, one `host:port` per line. Onion and I2P addresses are
/// dialled through the SOCKS5 proxies given, or skipped without one.
struct Options: Sendable {
    var validatePeerList: URL?
    var input: URL?
    var observedAt: String?
    var expectedRecords: Int?
    var inputSHA256: String?
    var runStartedAt = ISO8601DateFormatter().string(from: Date())
    var out: URL?
    /// Machine-readable summary for the scheduled census (docs/census/).
    var summary: URL?
    var sample = 0 // 0 = all
    /// Concurrent dials, per overlay. Each overlay has its own queue and its
    /// own ceiling: a Tor client keeps only a few dozen circuits pending at
    /// once (MaxClientCircuitsPending, default 32), and onion dials beyond
    /// that do not queue politely, they saturate it until every rendezvous
    /// times out. Clearnet has no such limit.
    var parallel = 64
    var torParallel = 32
    var i2pParallel = 64
    var timeout: Duration = .seconds(8)
    var feeFilterWait: Duration = .milliseconds(1_500)
    var network: NetworkParams = .mainnet
    var seed: UInt64 = 42
    /// SOCKS5 proxies for the hidden networks. Without one, that network's
    /// addresses are skipped rather than dialled and counted unreachable.
    var torSocks: PeerEndpoint?
    var i2pSocks: PeerEndpoint?
    /// Hidden services answer slowly; a separate budget keeps the clearnet
    /// timeout honest.
    var hiddenTimeout: Duration = .seconds(25)
    /// The chain tip to judge heights against. Default: the median of what
    /// usable peers report, which one liar in either direction cannot move.
    /// The snapshot's own latest_height is a good value to pass.
    var tip: Int32?
    /// Summarise an earlier run's JSON lines instead of dialling: re-files a
    /// day under a changed rule without touching the network.
    var replay: URL?
    /// Build the wallet's verified peer list (census/peers.json) from an
    /// earlier run's JSON lines instead of dialling. Requires --out.
    var peerList: URL?
}

struct Record: Codable, Sendable {
    var host: String
    var port: UInt16
    /// ok | noCompactFilters | unreachable | handshakeFailed | protocolViolation | timeout
    var outcome: String
    var userAgent: String?
    var startHeight: Int32?
    var services: UInt64?
    var feeFilterSatPerKvB: Int64?
    var latencyMs: Int
    var error: String?
    /// clearnet | tor | i2p
    var network: String
    var runStartedAt: String?
    var runSample: Int?
    var expectedRecords: Int?
    var observedAt: String?
    var inputSHA256: String?
}

private func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--observed-at": options.observedAt = args.next()
        case "--validate-peer-list": options.validatePeerList = args.next().map { URL(fileURLWithPath: $0) }
        case "--input": options.input = args.next().map { URL(fileURLWithPath: $0) }
        case "--out": options.out = args.next().map { URL(fileURLWithPath: $0) }
        case "--summary-json": options.summary = args.next().map { URL(fileURLWithPath: $0) }
        case "--sample": options.sample = Int(args.next() ?? "") ?? 0
        case "--parallel": options.parallel = Int(args.next() ?? "") ?? 64
        case "--tor-parallel": options.torParallel = Int(args.next() ?? "") ?? 32
        case "--i2p-parallel": options.i2pParallel = Int(args.next() ?? "") ?? 64
        case "--timeout": options.timeout = .seconds(Double(args.next() ?? "") ?? 8)
        case "--feefilter-wait-ms": options.feeFilterWait = .milliseconds(Int(args.next() ?? "") ?? 1_500)
        case "--seed": options.seed = UInt64(args.next() ?? "") ?? 42
        case "--tor-socks": options.torSocks = args.next().flatMap(parseHostPort)
        case "--i2p-socks": options.i2pSocks = args.next().flatMap(parseHostPort)
        case "--hidden-timeout": options.hiddenTimeout = .seconds(Double(args.next() ?? "") ?? 25)
        case "--tip": options.tip = Int32(args.next() ?? "")
        case "--replay": options.replay = args.next().map { URL(fileURLWithPath: $0) }
        case "--peer-list": options.peerList = args.next().map { URL(fileURLWithPath: $0) }
        case "--network":
            switch args.next() {
            case "mainnet": options.network = .mainnet
            case "signet": options.network = .signet
            default: fatalError("--network mainnet|signet")
            }
        case "--help", "-h":
            print("""
            usage: WinnowCensus --input nodes.json|nodes.txt [--out results.jsonl] [--summary-json summary.json]
                   WinnowCensus --replay results.jsonl [--summary-json summary.json] [--tip HEIGHT]
                   WinnowCensus --peer-list results.jsonl --out peers.json [--tip HEIGHT]
                   WinnowCensus --validate-peer-list peers.json
                   WinnowCensus keygen | sign [--key-env CENSUS_SIGNING_KEY] peers.json | verify [--public-key HEX] peers.json
                                [--sample N] [--parallel 64] [--tor-parallel 32] [--i2p-parallel 64]
                                [--timeout 8] [--feefilter-wait-ms 1500]
                                [--tor-socks 127.0.0.1:9050] [--i2p-socks 127.0.0.1:4447] [--hidden-timeout 25]
                                [--tip HEIGHT]
            """)
            exit(0)
        default:
            fatalError("unknown argument \(arg)")
        }
    }
    if options.input == nil && options.replay == nil && options.peerList == nil && options.validatePeerList == nil {
        fatalError("--input, --replay or --peer-list is required")
    }
    if options.peerList != nil && options.out == nil { fatalError("--peer-list requires --out") }
    return options
}

func parseHostPort(_ text: String) -> PeerEndpoint? {
    guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]), port > 0 else { return nil }
    var host = String(text[..<colon]).lowercased()
    if host.hasPrefix("[") {
        guard host.hasSuffix("]") else { return nil }
        host = String(host.dropFirst().dropLast())
    }
    guard !host.isEmpty, !host.contains("["), !host.contains("]") else { return nil }
    return PeerEndpoint(host: host, port: port)
}

enum OverlayNetwork: String, CaseIterable {
    case clearnet, tor, i2p

    init(host: String) {
        if host.lowercased().hasSuffix(".onion") { self = .tor }
        else if host.lowercased().hasSuffix(".i2p") { self = .i2p }
        else { self = .clearnet }
    }
}

/// Accepts a snapshot dictionary or a plain host:port list. Hidden-network
/// addresses are kept only when a proxy for that network is configured.
private func loadEndpoints(from url: URL, options: Options) throws -> [PeerEndpoint] {
    let data = try Data(contentsOf: url)
    var keys: [String] = []
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let nodes = object["nodes"] as? [String: Any] {
        keys = Array(nodes.keys)
    } else {
        keys = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
    }
    var endpoints: [PeerEndpoint] = []
    var seen = Set<PeerEndpoint>()
    for key in keys {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard let parsed = parseHostPort(trimmed) else { continue }
        let overlay = OverlayNetwork(host: parsed.host)
        if overlay == .tor, options.torSocks == nil { continue }
        if overlay == .i2p, options.i2pSocks == nil { continue }
        guard let host = PublicationCatalog.canonicalHost(parsed.host, overlay: overlay) else { continue }
        let endpoint = PeerEndpoint(host: host, port: parsed.port)
        if seen.insert(endpoint).inserted { endpoints.append(endpoint) }
    }
    return endpoints
}

private func probe(_ endpoint: PeerEndpoint, options: Options) async -> Record {
    let started = ContinuousClock.now
    let overlay = OverlayNetwork(host: endpoint.host)
    let proxy: PeerEndpoint? = switch overlay {
    case .clearnet: nil
    case .tor: options.torSocks
    case .i2p: options.i2pSocks
    }
    let timeout = overlay == .clearnet ? options.timeout : options.hiddenTimeout
    let peer = PeerConnection(endpoint: endpoint, params: options.network,
                              localServices: 0, localStartHeight: 0, relayPreference: false,
                              socksProxy: proxy)
    func elapsed() -> Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
    func record(_ outcome: String, userAgent: String? = nil, startHeight: Int32? = nil,
                services: UInt64? = nil, feeFilter: Int64? = nil, error: String? = nil) -> Record {
        Record(host: endpoint.host, port: endpoint.port, outcome: outcome, userAgent: userAgent,
               startHeight: startHeight, services: services, feeFilterSatPerKvB: feeFilter,
               latencyMs: elapsed(), error: error, network: overlay.rawValue,
               runStartedAt: options.runStartedAt, runSample: options.sample, expectedRecords: options.expectedRecords,
               observedAt: ISO8601DateFormatter().string(from: Date()), inputSHA256: options.inputSHA256)
    }
    do {
        try await peer.connect(timeout: timeout)
        // Core pushes feefilter right after verack; give it a moment.
        let deadline = ContinuousClock.now + options.feeFilterWait
        while await peer.feeFilter == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let result = record("ok", userAgent: await peer.peerUserAgent,
                            startHeight: await peer.peerStartHeight,
                            services: await peer.peerServices,
                            feeFilter: await peer.feeFilter)
        await peer.disconnect()
        return result
    } catch let error as PeerError {
        switch error {
        case let .missingCompactFilters(services):
            return record("noCompactFilters", userAgent: await peer.peerUserAgent,
                          startHeight: await peer.peerStartHeight, services: services)
        case .timeout:
            return record("timeout")
        case .protocolViolation:
            return record("protocolViolation", error: error.localizedDescription)
        default:
            return record("unreachable", error: error.localizedDescription)
        }
    } catch {
        return record("handshakeFailed", error: error.localizedDescription)
    }
}

/// Deterministic shuffle so a sample is reproducible from its seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The daily data point the site renders. Aggregates only: the per-node
/// detail is in the JSONL, and btcnodes already publishes the per-IP view.
struct Summary: Codable {
    struct Family: Codable {
        var usable: Int
        var atTip: Int
        var stuckAtSplit: Int
        var behind: Int
        var medianFeeFilterSatPerKvB: Int64?
    }
    var generatedAt: String
    var processedAt: String?
    var observationEndedAt: String?
    var inputSHA256: String?
    var completeRun: Bool?
    var sample: Int?
    var expectedRecords: Int?
    var recordsSHA256: String?
    var peerListSHA256: String?
    var processingRevision: String?
    var wholeNetworkFamilies: [String: Int]?
    var dialled: Int
    var outcomes: [String: Int]
    var usable: Int
    var observedTip: Int32
    var splitHeight: Int32
    var stuckAtSplit: Int
    var behind: Int
    /// Reporting more than 100 blocks above the reference snapshot height.
    /// This observation alone cannot identify the cause or the peer's chain.
    var aheadOfTip: Int
    var medianFeeFilterSatPerKvB: Int64?
    var handshakeLatencyMsMedian: Int?
    var families: [String: Family]
    /// The same breakdown per overlay network: clearnet, tor, i2p. Absent
    /// networks were not dialled (no proxy configured).
    var networks: [String: Network]

    struct Network: Codable {
        var dialled: Int
        var usable: Int
        var noCompactFilters: Int
        var atTip: Int
        var stuckAtSplit: Int
        var behind: Int
    }
}

func family(of userAgent: String) -> String {
    if userAgent.contains("Knots") { return "Knots" }
    if userAgent.hasPrefix("/Satoshi:") { return "Core" }
    if userAgent.contains("btcd") { return "btcd" }
    if userAgent.contains("bcoin") { return "bcoin" }
    return "other"
}

/// The tip to judge heights against: the caller's, or the median of what
/// usable peers report. A percentile near the top let one node claiming a
/// taller chain drag the estimate up and mark every honest peer "behind".
func observedTip(_ records: [Record], override: Int32?) -> Int32 {
    if let override { return override }
    let heights = records.filter { $0.outcome == "ok" }.compactMap(\.startHeight).sorted()
    return heights.isEmpty ? 0 : heights[heights.count / 2]
}

func makeSummary(_ records: [Record], tip: Int32, splitHeight: Int32 = 961_632) -> Summary {
    let ok = records.filter { $0.outcome == "ok" }
    func median(_ values: [Int64]) -> Int64? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }
    let isStuck: (Record) -> Bool = { ($0.startHeight ?? 0) >= splitHeight && Int64($0.startHeight ?? 0) <= Int64(splitHeight) + 20 }
    let isBehind: (Record) -> Bool = { Int64(tip) - Int64($0.startHeight ?? 0) > 100 }
    let isAhead: (Record) -> Bool = { Int64($0.startHeight ?? 0) - Int64(tip) > 100 }
    var families: [String: Summary.Family] = [:]
    for (name, members) in Dictionary(grouping: ok, by: { family(of: $0.userAgent ?? "") }) {
        families[name] = Summary.Family(
            usable: members.count,
            atTip: members.filter { atTip($0, tip: tip) }.count,
            stuckAtSplit: members.filter(isStuck).count,
            behind: members.filter(isBehind).count,
            medianFeeFilterSatPerKvB: median(members.compactMap(\.feeFilterSatPerKvB)))
    }
    var networks: [String: Summary.Network] = [:]
    for (name, members) in Dictionary(grouping: records, by: \.network) {
        let usable = members.filter { $0.outcome == "ok" }
        networks[name] = Summary.Network(
            dialled: members.count, usable: usable.count,
            noCompactFilters: members.filter { $0.outcome == "noCompactFilters" }.count,
            atTip: usable.filter { atTip($0, tip: tip) }.count,
            stuckAtSplit: usable.filter(isStuck).count,
            behind: usable.filter(isBehind).count)
    }
    let latencies = ok.map(\.latencyMs).sorted()
    return Summary(
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        dialled: records.count,
        outcomes: Dictionary(grouping: records, by: \.outcome).mapValues(\.count),
        usable: ok.count,
        observedTip: tip,
        splitHeight: splitHeight,
        stuckAtSplit: ok.filter(isStuck).count,
        behind: ok.filter(isBehind).count,
        aheadOfTip: ok.filter(isAhead).count,
        medianFeeFilterSatPerKvB: median(ok.compactMap(\.feeFilterSatPerKvB)),
        handshakeLatencyMsMedian: latencies.isEmpty ? nil : latencies[latencies.count / 2],
        families: families, networks: networks)
}

private func summarize(_ records: [Record], tip: Int32, splitHeight: Int32 = 961_632) {
    let ok = records.filter { $0.outcome == "ok" }
    func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.1f%%", 100 * Double(n) / Double(d)) }
    print("")
    print("dialled \(records.count)")
    for outcome in ["ok", "noCompactFilters", "unreachable", "timeout", "handshakeFailed", "protocolViolation"] {
        let n = records.filter { $0.outcome == outcome }.count
        if n > 0 { print("  \(outcome.padding(toLength: 18, withPad: " ", startingAt: 0)) \(n)  \(pct(n, records.count))") }
    }
    print("")
    print("of the \(ok.count) Winnow-usable peers (handshake ok, compact filters advertised):")
    print("  tip used to judge heights: \(tip)")
    let stuck = ok.filter { ($0.startHeight ?? 0) >= splitHeight && Int64($0.startHeight ?? 0) <= Int64(splitHeight) + 20 }
    let behind = ok.filter { Int64(tip) - Int64($0.startHeight ?? 0) > 100 }
    let ahead = ok.filter { Int64($0.startHeight ?? 0) - Int64(tip) > 100 }
    print("  at the BIP-110 split height (\(splitHeight)…\(splitHeight + 20)): \(stuck.count)  \(pct(stuck.count, ok.count))")
    print("  more than 100 blocks behind the tip:                \(behind.count)  \(pct(behind.count, ok.count))")
    print("  more than 100 blocks above the reference tip:        \(ahead.count)  \(pct(ahead.count, ok.count))")
    let filters = ok.compactMap(\.feeFilterSatPerKvB).sorted()
    if !filters.isEmpty {
        print("  fee filter median \(filters[filters.count / 2]) sat/kvB, "
              + "over 100 sat/vB: \(filters.filter { $0 > 100_000 }.count)")
    }
    print("")
    print("by overlay network:")
    print("  network   dialled  usable   no filters  stuck@split (of usable)")
    for (name, members) in Dictionary(grouping: records, by: \.network).sorted(by: { $0.key < $1.key }) {
        let usable = members.filter { $0.outcome == "ok" }
        let noFilters = members.filter { $0.outcome == "noCompactFilters" }.count
        let stuckHere = usable.filter { ($0.startHeight ?? 0) >= splitHeight && Int64($0.startHeight ?? 0) <= Int64(splitHeight) + 20 }.count
        print("  \(name.padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(members.count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(pct(usable.count, members.count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(pct(noFilters, members.count).padding(toLength: 11, withPad: " ", startingAt: 0)) \(pct(stuckHere, usable.count))")
    }
    print("")
    print("by software family (usable peers):")
    func family(_ ua: String) -> String {
        if ua.contains("Knots") { return "Knots" }
        if ua.hasPrefix("/Satoshi:") { return "Core" }
        if ua.contains("btcd") { return "btcd" }
        if ua.contains("bcoin") { return "bcoin" }
        return "other"
    }
    let groups = Dictionary(grouping: ok) { family($0.userAgent ?? "") }
    print("  family   count  at tip   stuck@split  >100 behind")
    for (name, members) in groups.sorted(by: { $0.value.count > $1.value.count }) {
        let nearTipCount = members.filter { atTip($0, tip: tip) }.count
        let s = members.filter { ($0.startHeight ?? 0) >= splitHeight && Int64($0.startHeight ?? 0) <= Int64(splitHeight) + 20 }.count
        let b = members.filter { Int64(tip) - Int64($0.startHeight ?? 0) > 100 }.count
        print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(members.count).padding(toLength: 6, withPad: " ", startingAt: 0)) \(pct(nearTipCount, members.count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(pct(s, members.count).padding(toLength: 12, withPad: " ", startingAt: 0)) \(pct(b, members.count))")
    }
    print("")
    print("top user agents among stuck peers:")
    let uaCounts = Dictionary(grouping: stuck) { $0.userAgent ?? "?" }.mapValues(\.count)
    for (ua, n) in uaCounts.sorted(by: { $0.value > $1.value }).prefix(8) { print("  \(n)  \(ua)") }
}

/// Serialises the streamed output: the overlays are crawled concurrently.
actor RecordSink {
    private let handle: FileHandle?
    private let encoder: JSONEncoder
    init(handle: FileHandle?) {
        self.handle = handle
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }
    func write(_ record: Record) {
        guard let handle, let data = try? encoder.encode(record) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

/// Dials `endpoints` with at most `parallel` in flight, streaming records to `sink`.
func crawl(_ endpoints: [PeerEndpoint], label: String, parallel: Int, options: Options,
           sink: RecordSink) async -> [Record] {
    var records: [Record] = []
    var done = 0
    await withTaskGroup(of: Record.self) { group in
        var next = 0
        func enqueue() {
            guard next < endpoints.count else { return }
            let endpoint = endpoints[next]
            next += 1
            group.addTask { await probe(endpoint, options: options) }
        }
        for _ in 0 ..< min(parallel, endpoints.count) { enqueue() }
        for await record in group {
            records.append(record)
            done += 1
            await sink.write(record)
            if done % 200 == 0 || done == endpoints.count {
                FileHandle.standardError.write(Data("\(label) \(done)/\(endpoints.count)\n".utf8))
            }
            enqueue()
        }
    }
    return records
}

/// One queue per overlay, run side by side, each with its own ceiling (see
/// `Options.parallel`). Records come back in completion order across all
/// three.
func crawlAll(_ endpoints: [PeerEndpoint], options: Options, output: FileHandle?) async -> [Record] {
    let sink = RecordSink(handle: output)
    let byOverlay = Dictionary(grouping: endpoints) { OverlayNetwork(host: $0.host) }
    return await withTaskGroup(of: [Record].self) { group in
        for (overlay, members) in byOverlay.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let parallel = switch overlay {
            case .clearnet: options.parallel
            case .tor: options.torParallel
            case .i2p: options.i2pParallel
            }
            FileHandle.standardError.write(Data("\(overlay.rawValue): \(members.count) endpoints, \(parallel) at a time\n".utf8))
            group.addTask {
                await crawl(members, label: overlay.rawValue, parallel: parallel, options: options, sink: sink)
            }
        }
        var all: [Record] = []
        for await part in group { all += part }
        return all
    }
}

/// Reads back the JSON lines an earlier run streamed out.
func replayRecords(from url: URL) throws -> [Record] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .filter { !$0.isEmpty }
        .map { try decoder.decode(Record.self, from: Data($0.utf8)) }
}

/// Either dials the input list or replays an earlier run's records.
func collectRecords(options: Options) async throws -> [Record] {
    var options = options
    if let replay = options.replay {
        let records = try replayRecords(from: replay)
        FileHandle.standardError.write(Data("replaying \(records.count) records from \(replay.lastPathComponent)\n".utf8))
        return records
    }
    guard let input = options.input else { fatalError("--input or --replay is required") }
    options.inputSHA256 = try sha256(input)
    var endpoints = try loadEndpoints(from: input, options: options)
    var generator = SeededGenerator(state: options.seed)
    endpoints.sort { ($0.host, $0.port) < ($1.host, $1.port) }
    endpoints.shuffle(using: &generator)
    options.expectedRecords = endpoints.count
    if options.sample > 0 { endpoints = Array(endpoints.prefix(options.sample)) }
    FileHandle.standardError.write(Data("dialling \(endpoints.count) endpoints\n".utf8))
    var output: FileHandle?
    if let out = options.out {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        output = try FileHandle(forWritingTo: out)
    }
    let records = await crawlAll(endpoints, options: options, output: output)
    try? output?.close()
    return records
}

func observationDate(_ records: [Record], options: Options) throws -> String {
    let dates = Set(records.compactMap(\.runStartedAt))
    let value = options.observedAt ?? (dates.count == 1 ? dates.first : nil)
        ?? (options.replay == nil && options.peerList == nil ? options.runStartedAt : "")
    guard let parsed = ISO8601DateFormatter().date(from: value),
          ISO8601DateFormatter().string(from: parsed) == value, parsed <= Date(),
          PublicationCatalog.day(String(value.prefix(10))) != nil else {
        throw NSError(domain: "Census", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Replay needs its original --observed-at YYYY-MM-DDTHH:MM:SSZ or records with a run timestamp"])
    }
    if let supplied = options.observedAt, !dates.isEmpty, dates != Set([supplied]) {
        throw PublicationCatalog.Invalid.date
    }
    for record in records {
        if let ended = record.observedAt {
            guard let end = ISO8601DateFormatter().date(from: ended),
                  ISO8601DateFormatter().string(from: end) == ended,
                  end >= parsed, end <= Date() else { throw PublicationCatalog.Invalid.date }
        }
    }
    return value
}

func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

if let command = CommandLine.arguments.dropFirst().first, ["keygen", "sign", "verify"].contains(command) {
    exit(Signing.run(command, arguments: CommandLine.arguments.dropFirst(2)))
}
let options = parseOptions()
if let catalog = options.validatePeerList {
    _ = try PublicationCatalog.decode(Data(contentsOf: catalog), requireFresh: false)
    exit(0)
}
let records: [Record]
if let input = options.peerList { records = try replayRecords(from: input) }
else { records = try await collectRecords(options: options) }
let tip = observedTip(records, override: options.tip)
let observedAt = try observationDate(records, options: options)
if options.peerList != nil {
    _ = try writePeerList(records, tip: tip, observedAt: observedAt, to: options.out!)
} else {
    if let summaryURL = options.summary {
        var summary = makeSummary(records, tip: tip)
        summary.generatedAt = observedAt
        summary.observationEndedAt = records.compactMap(\.observedAt).max()
        summary.inputSHA256 = records.first?.inputSHA256
        summary.processedAt = ISO8601DateFormatter().string(from: Date())
        summary.sample = records.first?.runSample ?? options.sample
        summary.expectedRecords = records.first?.expectedRecords
        summary.completeRun = !records.isEmpty && records.allSatisfy {
            $0.runStartedAt == observedAt && $0.runSample == 0 && $0.expectedRecords == records.count
            && $0.observedAt != nil && $0.inputSHA256 == summary.inputSHA256
        } && summary.inputSHA256?.count == 64 && Set(records.map(\.network)) == Set(["clearnet", "tor", "i2p"])
        summary.processingRevision = ProcessInfo.processInfo.environment["GITHUB_SHA"]
        summary.wholeNetworkFamilies = Dictionary(grouping: records.filter { $0.userAgent != nil },
            by: { family(of: $0.userAgent!) }).mapValues(\.count)
        if let raw = options.replay ?? options.out { summary.recordsSHA256 = try sha256(raw) }
        let peersURL = summaryURL.deletingLastPathComponent().appendingPathComponent("peers.json")
        _ = try writePeerList(records, tip: tip, observedAt: observedAt, to: peersURL)
        summary.peerListSHA256 = try sha256(peersURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: summaryURL, options: .atomic)
    }
    summarize(records, tip: tip)
}
