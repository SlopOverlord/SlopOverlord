import Foundation

enum TaskSyncCrypto {
    static func verifyGitHubSignature(body: Data, secret: String, signatureHeader: String?) -> Bool {
        guard let signatureHeader,
              signatureHeader.hasPrefix("sha256=")
        else {
            return false
        }
        let expected = "sha256=" + hmacSHA256Hex(key: Data(secret.utf8), message: body)
        return constantTimeEquals(expected, signatureHeader)
    }

    static func hmacSHA256Hex(key: Data, message: Data) -> String {
        let blockSize = 64
        var keyBytes = [UInt8](key)
        if keyBytes.count > blockSize {
            keyBytes = sha256(keyBytes)
        }
        if keyBytes.count < blockSize {
            keyBytes += Array(repeating: 0, count: blockSize - keyBytes.count)
        }

        let outer = keyBytes.map { $0 ^ 0x5c }
        let inner = keyBytes.map { $0 ^ 0x36 }
        let digest = sha256(inner + [UInt8](message))
        return sha256(outer + digest).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = [UInt8](lhs.utf8)
        let b = [UInt8](rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private static func sha256(_ input: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        let bitLength = UInt64(input.count) * 8
        var message = input + [0x80]
        while (message.count % 64) != 56 {
            message.append(0)
        }
        message += stride(from: 56, through: 0, by: -8).map { UInt8((bitLength >> UInt64($0)) & 0xff) }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let chunk = Array(message[chunkStart..<chunkStart + 64])
            var w = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let j = i * 4
                w[i] = (UInt32(chunk[j]) << 24) | (UInt32(chunk[j + 1]) << 16) | (UInt32(chunk[j + 2]) << 8) | UInt32(chunk[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        return h.flatMap { value in
            [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ]
        }
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
