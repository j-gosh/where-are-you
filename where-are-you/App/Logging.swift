//
//  Logging.swift
//  where-are-you
//

import OSLog

// Never log coordinates, names, or other personal data. Error descriptions are
// logged as public because they don't contain any.
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "where-are-you"

    static let location = Logger(subsystem: subsystem, category: "location")
    static let friends = Logger(subsystem: subsystem, category: "friends")
    static let maps = Logger(subsystem: subsystem, category: "maps")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
}
