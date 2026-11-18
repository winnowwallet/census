import CryptoKit
import Foundation
import WalletCore

/// The publisher's signature over `census/peers.json`, written next to it as
/// `peers.json.sig` and served from the same place.
///
///     {"algorithm":"ed25519","publicKey":"<32 bytes hex>","signature":"<64 bytes hex>"}
///
/// Ed25519 over the domain tag and the file's exact bytes. The wallet's build
/// is what verifies it (winnowwallet/winnow-lean, `scripts/import-census` with
/// `scripts/ed25519_verify.py`), before the list is bundled into the app; the
/// app itself checks no signature. That import trusts only the public keys in
/// its `scripts/census-public-key.txt`. A known-answer vector holds this tool
/// to the same bytes (`tests/test_contract.py`, and `CensusTest.lean` for the
/// Lean Ed25519).
///
///   WinnowCensus keygen                            a fresh secret and its public key
///   WinnowCensus sign [--key-env NAME] FILE        writes FILE.sig with the secret in $NAME
///   WinnowCensus verify [--public-key HEX] FILE    checks FILE.sig, against HEX when given
enum Signing {
    static let algorithm = "ed25519"
    static let domain = Data("winnow-census-peers-v1\u{0}".utf8)
    static let defaultKeyVariable = "CENSUS_SIGNING_KEY"

    struct Signature: Codable {
        var algorithm: String
        var publicKey: String
        var signature: String
    }

    enum Failure: Error, CustomStringConvertible {
        case usage(String)
        case secret(String)
        case malformed
        case wrongKey(expected: String, found: String)
        case invalid

        var description: String {
            switch self {
            case let .usage(text): text
            case let .secret(text): text
            case .malformed: "the signature file is malformed"
            case let .wrongKey(expected, found): "signed with \(found), not the expected key \(expected)"
            case .invalid: "the signature does not match the file"
            }
        }
    }

    /// Runs one of the signing commands; the exit code is the result.
    static func run(_ command: String, arguments: ArraySlice<String>) -> Int32 {
        do {
            switch command {
            case "keygen": try keygen()
            case "sign": try sign(Array(arguments))
            case "verify": try verify(Array(arguments))
            default: throw Failure.usage("unknown command \(command)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("WinnowCensus \(command): \(error)\n".utf8))
            return 1
        }
    }

    /// Prints a fresh secret, once, in the form the Actions secret takes, and
    /// the public key the wallet's build pins.
    static func keygen() throws {
        let key = Curve25519.Signing.PrivateKey()
        print("\(defaultKeyVariable)=\(key.rawRepresentation.base64EncodedString())")
        print("public key: \(key.publicKey.rawRepresentation.hex)")
        print("Store the first line as the census repository's \(defaultKeyVariable) Actions secret; "
              + "add the public key to scripts/census-public-key.txt in winnowwallet/winnow-lean.")
    }

    static func sign(_ arguments: [String]) throws {
        let variable = option("--key-env", in: arguments) ?? defaultKeyVariable
        guard let file = arguments.last, !file.hasPrefix("--"), arguments.count == (arguments.contains("--key-env") ? 3 : 1)
        else { throw Failure.usage("usage: sign [--key-env NAME] FILE") }
        guard let encoded = ProcessInfo.processInfo.environment[variable], !encoded.isEmpty else {
            throw Failure.secret("no secret in $\(variable)")
        }
        guard let raw = Data(base64Encoded: encoded), raw.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { throw Failure.secret("$\(variable) is not a base64 32-byte Ed25519 secret") }
        let url = URL(fileURLWithPath: file)
        let payload = try Data(contentsOf: url)
        let signature = Signature(algorithm: algorithm, publicKey: key.publicKey.rawRepresentation.hex,
                                  signature: try key.signature(for: domain + payload).hex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try (try encoder.encode(signature) + Data("\n".utf8)).write(to: signatureURL(for: url), options: .atomic)
        print("signed \(file) under \(signature.publicKey)")
    }

    static func verify(_ arguments: [String]) throws {
        let expected = option("--public-key", in: arguments)
        guard let file = arguments.last, !file.hasPrefix("--"),
              arguments.count == (expected == nil ? 1 : 3)
        else { throw Failure.usage("usage: verify [--public-key HEX] FILE") }
        let url = URL(fileURLWithPath: file)
        let payload = try Data(contentsOf: url)
        let data = try Data(contentsOf: signatureURL(for: url))
        guard data.count <= 1_024, let signature = try? JSONDecoder().decode(Signature.self, from: data),
              signature.algorithm == algorithm,
              let keyBytes = Data(hex: signature.publicKey), keyBytes.count == 32,
              let signatureBytes = Data(hex: signature.signature), signatureBytes.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { throw Failure.malformed }
        if let expected, expected.lowercased() != signature.publicKey {
            throw Failure.wrongKey(expected: expected.lowercased(), found: signature.publicKey)
        }
        guard key.isValidSignature(signatureBytes, for: domain + payload) else { throw Failure.invalid }
        print("\(file): signature valid under \(signature.publicKey)")
    }

    static func signatureURL(for file: URL) -> URL {
        file.appendingPathExtension("sig")
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
