/// SHA3-256 (FIPS 202) for the v3 onion address checksum. Not a wallet key hash.
/// Keccak-f[1600], rate 1088, SHA3 domain suffix 0x06.
enum OnionChecksum {
    static func hash(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var padded = input + [UInt8](repeating: 0, count: rate - input.count % rate)
        padded[input.count] = 0x06
        padded[padded.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for start in stride(from: 0, to: padded.count, by: rate) {
            for i in 0..<rate { state[i / 8] ^= UInt64(padded[start + i]) << (8 * (i % 8)) }
            permute(&state)
        }
        return (0..<32).map { UInt8(truncatingIfNeeded: state[$0 / 8] >> (8 * ($0 % 8))) }
    }

    private static func rotate(_ x: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? x : (x << n) | (x >> (64 - n))
    }

    private static func permute(_ a: inout [UInt64]) {
        let shifts = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
                      41, 45, 15, 21, 8, 18, 2, 61, 56, 14]
        let constants: [UInt64] = [
            0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
            0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
            0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
            0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
            0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
        ]
        for constant in constants {
            theta(&a)
            let b = rhoPi(a, shifts: shifts)
            chi(&a, b)
            a[0] ^= constant
        }
    }
    private static func theta(_ a: inout [UInt64]) {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                for y in 0..<5 { c[x] ^= a[x + 5 * y] }
            }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotate(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
    }
    private static func rhoPi(_ a: [UInt64], shifts: [Int]) -> [UInt64] {
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 { b[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(a[x + 5 * y], shifts[x + 5 * y]) }
            }
        return b
    }
    private static func chi(_ a: inout [UInt64], _ b: [UInt64]) {
            for x in 0..<5 {
                for y in 0..<5 { a[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]) }
            }
    }

}
