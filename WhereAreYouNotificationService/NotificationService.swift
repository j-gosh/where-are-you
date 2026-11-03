//
//  NotificationService.swift
//  WhereAreYouNotificationService
//

import UserNotifications
import WAYCore

/// Decrypts alert pushes on the device. The push itself only carries ciphertext and generic
/// text; if decryption fails for any reason, the generic text is shown.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let keychainGroup = (Bundle.main.object(forInfoDictionaryKey: "WAYKeychainAccessGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let text = PushContent.text(
            for: content.userInfo,
            keyStore: KeychainKeyStore(accessGroup: keychainGroup),
            directory: KeychainFriendDirectoryStore(accessGroup: keychainGroup)
        ) {
            content.title = text.title
            content.body = text.body
        }
        contentHandler(content)
    }
}
