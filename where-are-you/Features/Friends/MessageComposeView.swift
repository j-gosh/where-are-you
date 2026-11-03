//
//  MessageComposeView.swift
//  where-are-you
//

import MessageUI
import Messages
import SwiftUI

/// The system Messages composer with an interactive message (the invite bubble) ready to send.
struct MessageComposeView: UIViewControllerRepresentable {
    let message: MSMessage
    let onFinish: (MessageComposeResult) -> Void

    /// False in the simulator and on devices without Messages set up.
    static var canSend: Bool {
        MFMessageComposeViewController.canSendText()
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.message = message
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }
}
