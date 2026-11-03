//
//  Base64URL.swift
//  WAYCore
//

import Foundation

extension Data {
    /// Base64url (RFC 4648 §5) without padding. Safe in URLs and Firestore document IDs.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url. Returns `nil` for any character outside the base64url alphabet.
    public init?(base64URLEncoded string: String) {
        let isBase64URL = string.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_": true
            default: false
            }
        }
        guard isBase64URL, string.count % 4 != 1 else { return nil }

        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
