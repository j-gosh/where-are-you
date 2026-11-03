//
//  SharingAndAlertTests.swift
//  WAYCoreTests
//

import Foundation
import Testing
@testable import WAYCore

private func account(_ uid: String, _ name: String) -> Account {
    Account(uid: uid, identity: .generate(), profile: Profile(displayName: name, avatar: Avatar(emoji: nil, color: .blue)))
}

private func location(latitude: Double = 48.8566, longitude: Double = 2.3522, secondsAfter base: TimeInterval = 0, approximate: Bool = false) -> SharedLocation {
    SharedLocation(latitude: latitude, longitude: longitude, horizontalAccuracy: 10, isApproximate: approximate, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + base))
}

struct SharingSettingsTests {
    @Test func uploadsOnlyFromActiveDeviceWhileSharingWithSomeone() {
        let settings = SharingSettings(isEnabled: true, friendUIDs: ["olivia"], activeDeviceId: "phone")

        #expect(settings.uploads(from: "phone"))
        #expect(!settings.uploads(from: "ipad"))
        #expect(!SharingSettings(isEnabled: false, friendUIDs: ["olivia"], activeDeviceId: "phone").uploads(from: "phone"))
        #expect(!SharingSettings(isEnabled: true, friendUIDs: [], activeDeviceId: "phone").uploads(from: "phone"))
    }

    @Test func masterSwitchOverridesPerFriendChoice() {
        #expect(SharingSettings(isEnabled: true, friendUIDs: ["olivia"], activeDeviceId: nil).isSharing(with: "olivia"))
        #expect(!SharingSettings(isEnabled: false, friendUIDs: ["olivia"], activeDeviceId: nil).isSharing(with: "olivia"))
        #expect(!SharingSettings(isEnabled: true, friendUIDs: ["olivia"], activeDeviceId: nil).isSharing(with: "ethan"))
    }
}

struct UploadPolicyTests {
    let policy = UploadPolicy()

    @Test func firstReadingAlwaysUploads() {
        #expect(policy.shouldUpload(location(), after: nil))
    }

    @Test func waitsForMovementAndMinimumInterval() {
        let last = location()
        // About 111 m north.
        let moved = location(latitude: 48.8576, secondsAfter: 60)

        #expect(policy.shouldUpload(moved, after: last))
        #expect(!policy.shouldUpload(location(latitude: 48.8576, secondsAfter: 10), after: last), "Too soon")
        #expect(!policy.shouldUpload(location(latitude: 48.85661, secondsAfter: 60), after: last), "Barely moved")
    }

    @Test func heartbeatUploadsWithoutMovement() {
        #expect(policy.shouldUpload(location(secondsAfter: 15 * 60), after: location()))
    }

    @Test func precisionChangeUploads() {
        #expect(policy.shouldUpload(location(secondsAfter: 60, approximate: true), after: location()))
    }

    @Test func distanceIsRoughlyRight() {
        let paris = location()
        let london = location(latitude: 51.5074, longitude: -0.1278)
        #expect(abs(UploadPolicy.distance(from: paris, to: london) - 343_500) < 2_000)
    }
}

struct LocationSharerTests {
    let me = account("me", "Me")
    let olivia = IdentityKey.generate()
    let ethan = IdentityKey.generate()

    @Test func sealsLocationAndProfileForEachRecipient() throws {
        let shares = try LocationSharer.shares(for: location(), account: me, recipients: ["olivia": olivia.publicIdentity, "ethan": ethan.publicIdentity])

        #expect(shares.map(\.recipientUid) == ["ethan", "olivia"])
        let oliviaShare = try #require(shares.last)
        #expect(oliviaShare.isSharingLocation)
        let opened = try Sealing.open(SharedLocation.self, from: try #require(oliviaShare.location), sender: me.identity.publicIdentity, senderUid: "me", recipient: olivia, recipientUid: "olivia")
        #expect(opened == location())
        let profile = try Sealing.open(Profile.self, from: oliviaShare.profile, sender: me.identity.publicIdentity, senderUid: "me", recipient: olivia, recipientUid: "olivia")
        #expect(profile == me.profile)
    }

    @Test func eachRecipientCanOnlyOpenTheirOwnCopy() throws {
        let shares = try LocationSharer.shares(for: location(), account: me, recipients: ["olivia": olivia.publicIdentity, "ethan": ethan.publicIdentity])
        let ethansCopy = try #require(shares.first { $0.recipientUid == "ethan" }?.location)

        #expect(throws: CryptoError.keyMismatch) {
            try Sealing.open(SharedLocation.self, from: ethansCopy, sender: me.identity.publicIdentity, senderUid: "me", recipient: olivia, recipientUid: "olivia")
        }
    }

    @Test func stoppedSharesKeepProfileButNoLocation() throws {
        let shares = try LocationSharer.stoppedShares(account: me, recipients: ["olivia": olivia.publicIdentity])

        #expect(shares.count == 1)
        #expect(shares[0].location == nil)
        #expect(!shares[0].isSharingLocation)
    }
}

struct AlertPlannerTests {
    let me = account("me", "Me")
    let olivia = account("olivia", "Olivia")
    let ethan = account("ethan", "Ethan")

    private func request(_ id: String, trigger: AlertTrigger = .arrive) -> AlertRequest {
        AlertRequest(id: id, placeName: "Home", latitude: 1, longitude: 2, radius: 200, trigger: trigger)
    }

    private func document(_ id: String, from requester: Account, createdAt: TimeInterval?) throws -> AlertRequestDocument {
        var document = try AlertPlanner.requestDocument(request(id), from: requester, to: "me", identity: me.identity.publicIdentity)
        document.createdAt = createdAt.map { Date(timeIntervalSince1970: $0) }
        return document
    }

    private var identities: [String: PublicIdentity] {
        ["olivia": olivia.identity.publicIdentity, "ethan": ethan.identity.publicIdentity]
    }

    @Test func decryptsAndOrdersOldestFirstWithinTheLimit() throws {
        let documents = [
            try document("c", from: olivia, createdAt: 300),
            try document("a", from: ethan, createdAt: 100),
            try document("b", from: olivia, createdAt: 200),
        ]

        let plan = AlertPlanner.plan(documents: documents, account: me, identities: identities, preferences: AlertPreferences(), limit: 2)

        #expect(plan.monitored.map(\.id) == ["a", "b"])
        #expect(plan.overLimit == 1)
        #expect(plan.monitored.first?.requesterUid == "ethan")
        #expect(plan.monitored.first?.requesterKey == ethan.identity.publicIdentity.rawRepresentation)
    }

    @Test func respectsAllowAndBlockPreferences() throws {
        let documents = [try document("a", from: olivia, createdAt: 1), try document("b", from: ethan, createdAt: 2)]

        let blocked = AlertPlanner.plan(documents: documents, account: me, identities: identities, preferences: AlertPreferences(blockedAlertRequesters: ["olivia"]))
        #expect(blocked.monitored.map(\.id) == ["b"])

        let none = AlertPlanner.plan(documents: documents, account: me, identities: identities, preferences: AlertPreferences(allowAlertsOnMe: false))
        #expect(none.monitored.isEmpty)
    }

    @Test func unknownRequesterKeyIsUnreadable() throws {
        let plan = AlertPlanner.plan(documents: [try document("a", from: olivia, createdAt: 1)], account: me, identities: [:], preferences: AlertPreferences())

        #expect(plan.monitored.isEmpty)
        #expect(plan.unreadable == 1)
    }

    @Test func documentIdMustMatchSealedId() throws {
        var swapped = try document("a", from: olivia, createdAt: 1)
        swapped.id = "not-a"

        #expect(AlertPlanner.plan(documents: [swapped], account: me, identities: identities, preferences: AlertPreferences()).unreadable == 1)
    }

    @Test(arguments: [
        (AlertTrigger.arrive, GeofenceState?.some(.outside), GeofenceState.inside, true),
        (.arrive, nil, .inside, false),
        (.arrive, .inside, .inside, false),
        (.arrive, .inside, .outside, false),
        (.leave, .inside, .outside, true),
        (.leave, nil, .outside, false),
        (.leave, .outside, .inside, false),
    ])
    func notifiesOnlyOnRealTransitions(trigger: AlertTrigger, previous: GeofenceState?, current: GeofenceState, expected: Bool) {
        #expect(AlertPlanner.shouldNotify(trigger: trigger, previous: previous, current: current) == expected)
    }

    @Test func requesterCanOpenTheEvent() throws {
        let alert = MonitoredAlert(request: request("a", trigger: .leave), requesterUid: "olivia", requesterKey: olivia.identity.publicIdentity.rawRepresentation)
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        let box = try AlertPlanner.sealedEvent(for: alert, account: me, at: when)

        let event = try Sealing.open(AlertEvent.self, from: box, sender: me.identity.publicIdentity, senderUid: "me", recipient: olivia.identity, recipientUid: "olivia")
        #expect(event == AlertEvent(alertId: "a", placeName: "Home", trigger: .leave, occurredAt: when))
    }

    @Test func requesterListsTheirOwnAlerts() throws {
        let mine = try AlertPlanner.requestDocument(request("a"), from: me, to: "olivia", identity: olivia.identity.publicIdentity)

        let alerts = AlertPlanner.setAlerts(documents: [mine], account: me)

        #expect(alerts == [SetAlert(request: request("a"), targetUid: "olivia")])
        #expect(AlertPlanner.setAlerts(documents: [mine], account: ethan).isEmpty, "Only the requester can read their copy")
    }
}

struct PushContentTests {
    let me = account("me", "Me")
    let olivia = account("olivia", "Olivia")
    let keyStore = InMemoryKeyStore()
    let directory = InMemoryFriendDirectoryStore()

    init() throws {
        try keyStore.save(me.identity, for: "me")
        try directory.save(FriendDirectory(entries: ["olivia": .init(displayName: "Olivia", publicKey: olivia.identity.publicIdentity.rawRepresentation)]), for: "me")
    }

    private func userInfo(kind: String, box: SealedBox) throws -> [AnyHashable: Any] {
        [
            PushContent.kindKey: kind,
            PushContent.fromKey: "olivia",
            PushContent.toKey: "me",
            PushContent.boxKey: String(decoding: try JSONEncoder().encode(box), as: UTF8.self),
        ]
    }

    @Test func decryptsArrivalEvent() throws {
        let event = AlertEvent(alertId: "a", placeName: "Home", trigger: .arrive, occurredAt: .now)
        let box = try Sealing.seal(event, from: olivia.identity, senderUid: "olivia", to: me.identity.publicIdentity, recipientUid: "me")

        let text = PushContent.text(for: try userInfo(kind: "alertEvent", box: box), keyStore: keyStore, directory: directory)

        #expect(text == PushContent.Text(title: "Olivia", body: "Arrived at Home"))
    }

    @Test func decryptsNoticeOfNewAlert() throws {
        let request = AlertRequest(id: "a", placeName: "Work", latitude: 1, longitude: 2, radius: 200, trigger: .leave)
        let box = try Sealing.seal(request, from: olivia.identity, senderUid: "olivia", to: me.identity.publicIdentity, recipientUid: "me")

        let text = try #require(PushContent.text(for: try userInfo(kind: "alertRequest", box: box), keyStore: keyStore, directory: directory))

        #expect(text.title == "New Location Alert")
        #expect(text.body.contains("Olivia"))
        #expect(text.body.contains("Work"))
    }

    @Test func unknownSenderOrForgedBoxFallsBackToGenericText() throws {
        let event = AlertEvent(alertId: "a", placeName: "Home", trigger: .arrive, occurredAt: .now)
        let forged = try Sealing.seal(event, from: IdentityKey.generate(), senderUid: "olivia", to: me.identity.publicIdentity, recipientUid: "me")

        #expect(PushContent.text(for: try userInfo(kind: "alertEvent", box: forged), keyStore: keyStore, directory: directory) == nil)
        #expect(PushContent.text(for: [PushContent.kindKey: "alertEvent"], keyStore: keyStore, directory: directory) == nil)
        #expect(PushContent.text(for: try userInfo(kind: "somethingNew", box: forged), keyStore: keyStore, directory: directory) == nil)
    }
}
