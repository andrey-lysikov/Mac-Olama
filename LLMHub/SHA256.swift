//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Streaming SHA-256 over CryptoKit, fed chunk by chunk while a file downloads.
struct SHA256Hasher {
    private var inner = CryptoKit.SHA256()
    mutating func update(_ data: Data) { inner.update(data: data) }
    mutating func finalizeHex() -> String { inner.finalize().map { String(format: "%02x", $0) }.joined() }

    static func hex(of data: Data) -> String {
        var h = SHA256Hasher()
        h.update(data)
        return h.finalizeHex()
    }
}
