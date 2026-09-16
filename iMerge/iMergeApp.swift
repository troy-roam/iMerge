import SwiftUI

@main
struct iMergeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
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
