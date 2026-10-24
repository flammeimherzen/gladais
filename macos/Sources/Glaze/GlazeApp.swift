import AppKit
import SwiftUI

@main
struct GlazeApp: App {
    @NSApplicationDelegateAdaptor(GladaisDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New chat") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

final class GladaisDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdownEngines()
        return .terminateNow
    }
}

enum Phase: String {
    case booting
    case idle
    case listening
    case transcribing
    case thinking
    case speaking

    var title: String {
        switch self {
        case .booting: "Waking up"
        case .idle: "Tap the glass"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }
}

struct VoiceOption: Identifiable, Hashable {
    var id: String
    var name: String
    var detail: String
}

struct ChatTurn: Identifiable, Codable, Hashable {
    var id: UUID
    var role: String
    var text: String
    var date: Date
}

struct Dialogue: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var messages: [ChatTurn]
}
