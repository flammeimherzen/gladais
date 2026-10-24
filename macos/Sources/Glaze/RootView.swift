import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 268)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
            Stage()
        }
        .background(GlazeBackground())
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onAppear { model.startIfNeeded() }
        .onKeyPress(.space) {
            model.toggle()
            return .handled
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gladais")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text("chats on this Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button(action: model.newConversation) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New chat")
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.dialogues) { dialogue in
                        DialogueRow(dialogue: dialogue, active: dialogue.id == model.selectedID)
                            .onTapGesture { model.select(dialogue.id) }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    model.delete(dialogue.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .background(.black.opacity(0.18))
    }
}

struct DialogueRow: View {
    var dialogue: Dialogue
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dialogue.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Text(dialogue.updatedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? Color.white.opacity(0.1) : Color.clear)
        )
        .foregroundStyle(.white.opacity(active ? 0.95 : 0.72))
    }
}

struct Stage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let chatting = !(model.selected?.messages.isEmpty ?? true)
                let full = min(460, proxy.size.width * 0.62)
                let compact = min(132, proxy.size.width * 0.18)
                VStack(spacing: chatting ? 8 : 18) {
                    Button(action: model.toggle) {
                        GlazeOrb(level: model.level, phase: model.phase)
                            .frame(width: chatting ? compact : full)
                    }
                    .buttonStyle(OrbButtonStyle())
                    .disabled(model.phase == .booting || model.phase == .transcribing || model.phase == .thinking)
                    .padding(.top, chatting ? 0 : 8)

                    if chatting {
                        Text(model.phase.title)
                            .font(.system(size: 12, weight: .medium))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        VStack(spacing: 6) {
                            Text(model.phase.title)
                                .font(.system(size: 13, weight: .medium))
                                .tracking(1.4)
                                .textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.45))
                            Text(model.caption.isEmpty ? model.note : model.caption)
                                .textSelection(.enabled)
                                .font(.system(size: 28, weight: .regular, design: .serif))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(3)
                                .frame(maxWidth: 640)
                        }
                    }

                    if let error = model.errorText {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.55))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }

                    TranscriptList()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(.spring(duration: 0.55, bounce: 0.12), value: chatting)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CapsuleMenu(title: voiceTitle, symbol: "waveform") {
                ForEach(model.voices) { voice in
                    Button {
                        model.chooseVoice(voice.id)
                    } label: {
                        if voice.id == model.voiceID {
                            Label("\(voice.name) · \(voice.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(voice.name) · \(voice.detail)")
                        }
                    }
                }
            }
            CapsuleMenu(title: model.modelID, symbol: "cpu") {
                ForEach(model.models, id: \.self) { name in
                    Button {
                        model.chooseModel(name)
                    } label: {
                        if name == model.modelID {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
            Spacer()
            Text(model.phase == .listening ? "a pause ends the phrase" : "space to talk")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .onKeyPress(.space) {
            model.toggle()
            return .handled
        }
    }

    private var voiceTitle: String {
        model.voices.first { $0.id == model.voiceID }?.name ?? "Voice"
    }
}

struct CapsuleMenu<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct TranscriptList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.selected?.messages ?? []) { turn in
                        MessageBubble(turn: turn)
                            .id(turn.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 10)),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selected?.messages.count ?? 0) { _, _ in
                if let last = model.selected?.messages.last?.id {
                    withAnimation(.spring(duration: 0.45)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MessageBubble: View {
    var turn: ChatTurn

    var body: some View {
        HStack {
            if turn.role == "user" { Spacer(minLength: 80) }
            Text(turn.text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(turn.text, forType: .string)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(turn.role == "user"
                              ? Color(red: 0.86, green: 0.64, blue: 0.32).opacity(0.22)
                              : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
            if turn.role != "user" { Spacer(minLength: 80) }
        }
    }
}

struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.28), value: configuration.isPressed)
    }
}
