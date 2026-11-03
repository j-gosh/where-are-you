//
//  MessagesViewController.swift
//  WhereAreYouMessages
//

import Messages
import SwiftUI
import UIKit

/// Entry point of the iMessage app (NSExtensionPrincipalClass in Config/Messages-Info.plist).
final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessagesModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.openURL = { [weak self] url in
            self?.extensionContext?.open(url)
        }
        model.insertMessage = { [weak self] message in
            guard let conversation = self?.activeConversation else {
                throw MessagesModel.Failure.noConversation
            }
            try await conversation.insert(message)
        }

        let host = UIHostingController(rootView: MessagesRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await model.load() }
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        model.show(selectedMessage: conversation.selectedMessage)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        model.show(selectedMessage: message)
    }
}
