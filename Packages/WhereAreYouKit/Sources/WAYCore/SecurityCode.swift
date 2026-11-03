//
//  SecurityCode.swift
//  WAYCore
//

import CryptoKit
import Foundation

/// A number two friends can compare in person to confirm nobody swapped their keys.
public enum SecurityCode {
    public static let groupCount = 12
    public static let digitsPerGroup = 5

    /// 60 digits in groups of 5. The same on both devices whichever order the keys are passed in.
    public static func digits(_ first: PublicIdentity, _ second: PublicIdentity) -> String {
        let (low, high) = first.rawRepresentation.lexicographicallyPrecedes(second.rawRepresentation)
            ? (first, second)
            : (second, first)
        var input = Data("WhereAreYou SecurityCode v1".utf8)
        input.append(low.rawRepresentation)
        input.append(high.rawRepresentation)

        // SHA-512 gives 64 bytes: five per group. Each 40-bit chunk mod 10^5 keeps the bias negligible.
        let hash = Array(SHA512.hash(data: input))
        return (0..<groupCount).map { group in
            let chunk = hash[(group * 5)..<(group * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let number = String(chunk % 100_000)
            return String(repeating: "0", count: digitsPerGroup - number.count) + number
        }
        .joined(separator: " ")
    }
}
