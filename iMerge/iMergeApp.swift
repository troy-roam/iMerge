import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.iMerge"
        let current = NSRunningApplication.current
        let earlierCopy = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && $0.processIdentifier < current.processIdentifier }
            .min { $0.processIdentifier < $1.processIdentifier }

        guard let earlierCopy else { return }
        earlierCopy.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag else { return true }
        sender.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        return false
    }
}

@main
struct iMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(replacing: .pasteboard) {
                Button("Paste Images") {
                    NotificationCenter.default.post(name: .pasteImages, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Copy Merged Image") {
                    NotificationCenter.default.post(name: .copyMerged, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Divider()

                Button("Select All") {
                    // With a sheet like Export up, hand ⌘A back to the focused text field.
                    if NSApp.modalWindow == nil {
                        NotificationCenter.default.post(name: .selectAllElements, object: nil)
                    } else {
                        NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Export Merged Image…") {
                    NotificationCenter.default.post(name: .exportMerged, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let pasteImages = Notification.Name("iMerge.pasteImages")
    static let copyMerged = Notification.Name("iMerge.copyMerged")
    static let exportMerged = Notification.Name("iMerge.exportMerged")
    static let selectAllElements = Notification.Name("iMerge.selectAllElements")
}
