//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SafariServices

/// Receives {url} from the toolbar button and opens the app via its `macolama://ask` URL scheme.
/// The app fetches the page itself, so the sandboxed extension never passes page content across processes.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        if let raw = message?["url"] as? String, var components = URLComponents(string: "macolama://ask") {
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let deepLink = components.url {
                // NSWorkspace is main-actor; fire and forget. VERIFY(safari): the appex lives long enough for the hop.
                Task { @MainActor in NSWorkspace.shared.open(deepLink) }
            }
        }
        context.completeRequest(returningItems: nil)
    }
}
