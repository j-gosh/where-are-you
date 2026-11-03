//
//  FirebasePushBackend.swift
//  WAYFirebase
//
//  Firebase Cloud Messaging, with method swizzling off (FirebaseAppDelegateProxyEnabled = NO in
//  Config/App-Info.plist): the app hands over its APNs token itself.
//

import FirebaseFirestore
import FirebaseMessaging
import Foundation

public struct FirebasePushBackend: Sendable {
    public init() {}

    @MainActor
    public func setAPNSToken(_ token: Data) {
        Messaging.messaging().apnsToken = token
    }

    /// The device's FCM registration token. Needs the APNs token first.
    public func registrationToken() async throws -> String {
        try await Messaging.messaging().token()
    }

    /// Fires whenever FCM rotates the token, so it can be saved again.
    public func tokenRefreshes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(forName: .MessagingRegistrationTokenRefreshed, object: nil, queue: nil) { _ in
                continuation.yield()
            }
            let handle = ObserverHandle(observer: observer)
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(handle.observer)
            }
        }
    }

    /// `users/{uid}/devices/{deviceId}`: where the notification function sends this user's pushes.
    public func saveDeviceToken(_ token: String, deviceId: String, for uid: String) async throws {
        try await device(deviceId, of: uid).setData([
            "fcmToken": token,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    public func deleteDeviceToken(deviceId: String, for uid: String) async throws {
        try await device(deviceId, of: uid).delete()
        try await Messaging.messaging().deleteToken()
    }

    private func device(_ deviceId: String, of uid: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid).collection("devices").document(deviceId)
    }
}

/// NotificationCenter observer tokens are only handed back to NotificationCenter.
private struct ObserverHandle: @unchecked Sendable {
    let observer: NSObjectProtocol
}
