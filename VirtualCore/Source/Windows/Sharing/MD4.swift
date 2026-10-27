import Foundation

/// The MD4 message digest from RFC 1320, which is what the NT hash of a password for SMB is made with.
///
/// It's long been broken as a cryptographic hash. It's only used because Samba stores passwords as NT hashes,
/// and CommonCrypto's implementation is deprecated for that reason.
enum MD4 {
    static func hash(_ message: Data) -> Data {
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        withUnsafeBytes(of: (UInt64(message.count) &* 8).littleEndian) { padded.append(contentsOf: $0) }

        var state: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)

        padded.withUnsafeBytes { bytes in
            for blockStart in stride(from: 0, to: bytes.count, by: 64) {
                var words = [UInt32](repeating: 0, count: 16)
                for index in 0..<16 {
                    let offset = blockStart + index * 4
                    words[index] = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                }
                state = process(words, state: state)
            }
        }

        var digest = Data(capacity: 16)
        for word in [state.0, state.1, state.2, state.3] {
            withUnsafeBytes(of: word.littleEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    private static let rounds: [(order: [Int], shifts: [UInt32], constant: UInt32, function: (UInt32, UInt32, UInt32) -> UInt32)] = [
        (Array(0..<16), [3, 7, 11, 19], 0, { x, y, z in (x & y) | (~x & z) }),
        ([0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15], [3, 5, 9, 13], 0x5A82_7999, { x, y, z in (x & y) | (x & z) | (y & z) }),
        ([0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15], [3, 9, 11, 15], 0x6ED9_EBA1, { x, y, z in x ^ y ^ z }),
    ]

    private static func process(_ words: [UInt32], state: (UInt32, UInt32, UInt32, UInt32)) -> (UInt32, UInt32, UInt32, UInt32) {
        /// Each step changes one of the four registers, in the order a, d, c, b.
        var registers = [state.0, state.1, state.2, state.3]

        for round in rounds {
            for (step, wordIndex) in round.order.enumerated() {
                let target = (4 - step % 4) % 4
                let x = registers[(target + 1) % 4], y = registers[(target + 2) % 4], z = registers[(target + 3) % 4]
                let sum = registers[target] &+ round.function(x, y, z) &+ words[wordIndex] &+ round.constant
                let shift = round.shifts[step % 4]
                registers[target] = sum << shift | sum >> (32 - shift)
            }
        }

        return (state.0 &+ registers[0], state.1 &+ registers[1], state.2 &+ registers[2], state.3 &+ registers[3])
    }
}
