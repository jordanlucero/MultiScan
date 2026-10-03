//
//  ShareViewController.swift
//  MultiScanShare
//
//  Principal class of the share extension. The share extension point still requires a platform view controller, so this hosts the shared SwiftUI `ShareView` and knows how to bring the app forward.
//

import SwiftUI

#if os(macOS)
import AppKit

final class ShareViewController: NSViewController {
    override func loadView() {
        let model = ShareModel(extensionContext: extensionContext) { url in
            // Open the app this extension is embedded in (MultiScan.app/Contents/PlugIns/MultiScanShare.appex) rather than going through the URL scheme first: with several copies installed (App Store + dev builds), LaunchServices may hand the URL to a different one, or to none.
            let appURL = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())) != nil {
                return true
            }
            return NSWorkspace.shared.open(url)
        }
        view = NSHostingView(rootView: ShareView(model: model))
    }
}
#else
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let model = ShareModel(extensionContext: extensionContext) { [weak self] url in
            await self?.openContainingApp(url) ?? false
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// ⚠️ iOS gives share extensions no supported way to open their app: `NSExtensionContext.open` is refused at this extension point and `UIApplication.shared` is unavailable. But the extension process still has an application object at the end of the responder chain, and its public `open(_:options:completionHandler:)` works. When blocked, falls back to "Open MultiScan to start scanning."
    private func openContainingApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url)
            }
            responder = current.next
        }
        return false
    }
}
#endif
