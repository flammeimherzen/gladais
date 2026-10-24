import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var dialogues: [Dialogue] = []
    @Published var selectedID: UUID?
    @Published var phase: Phase = .booting
    @Published var level: CGFloat = 0
    @Published var caption = ""
    @Published var note = "Starting the local engine"
    @Published var voices: [VoiceOption] = [
        VoiceOption(id: "mine", name: "Your voice", detail: "reference")
    ]
    @Published var models: [String] = ["qwen2.5:14b"]
    @Published var voiceID = "xenia"
    @Published var modelID = "qwen2.5:14b"
    @Published var errorText: String?

    let ear = Ear()
    let mouth = Mouth()
    private var server: Process?
    private let storeURL: URL
    private var started = false
    private var didShutdown = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("dialogues.json")
        load()
        if dialogues.isEmpty {
            newConversation()
        } else {
            selectedID = dialogues[0].id
        }
        voiceID = "mine"
        modelID = UserDefaults.standard.string(forKey: "glaze.model") ?? "qwen2.5:14b"
        ear.onLevel = { [weak self] value in
            DispatchQueue.main.async {
                self?.level = CGFloat(value)
            }
        }
        ear.onUtterance = { [weak self] samples in
            Task { await self?.handleUtterance(samples) }
        }
        ear.onSilence = { [weak self] in
            Task { @MainActor in
                self?.phase = .idle
                self?.note = "Silence. Tap again"
                self?.level = 0
            }
        }
        mouth.onLevel = { [weak self] value in
            DispatchQueue.main.async {
                guard self?.phase == .speaking else { return }
                self?.level = CGFloat(value)
            }
        }
        mouth.onFinish = { [weak self] in
            Task { @MainActor in
                guard self?.phase == .speaking else { return }
                self?.phase = .idle
                self?.level = 0
                self?.note = "You can speak again"
            }
        }
    }

    var selected: Dialogue? {
        dialogues.first { $0.id == selectedID }
    }

    func shutdownEngines() {
        guard !didShutdown else { return }
        didShutdown = true
        ear.stop(send: false)
        mouth.stop()
        unloadOllama()
        server?.terminate()
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "\(projectRoot.path)/server.py"]
        try? kill.run()
        kill.waitUntilExit()
        server?.waitUntilExit()
    }

    private func unloadOllama() {
        let session = URLSession(configuration: .ephemeral)
        var names: [String] = []
        if let data = syncData(session, url: "http://127.0.0.1:11434/api/ps"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loaded = json["models"] as? [[String: Any]] {
            names = loaded.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        if names.isEmpty {
            names = [modelID]
        }
        for name in names {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "keep_alive": 0])
            _ = syncData(session, request: request)
        }
    }

    private func syncData(_ session: URLSession, url: String) -> Data? {
        guard let url = URL(string: url) else { return nil }
        return syncData(session, request: URLRequest(url: url))
    }

    private func syncData(_ session: URLSession, request: URLRequest) -> Data? {
        var result: Data?
        let wait = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, _ in
            result = data
            wait.signal()
        }.resume()
        _ = wait.wait(timeout: .now() + 8)
        return result
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await bootstrap() }
    }

    func newConversation() {
        let dialogue = Dialogue(id: UUID(), title: "New chat", updatedAt: Date(), messages: [])
        dialogues.insert(dialogue, at: 0)
        selectedID = dialogue.id
        caption = ""
        save()
    }

    func select(_ id: UUID) {
        selectedID = id
        caption = ""
    }

    func delete(_ id: UUID) {
        dialogues.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = dialogues.first?.id
        }
        if dialogues.isEmpty {
            newConversation()
        }
        save()
    }

    func toggle() {
        switch phase {
        case .listening:
            let sent = ear.stop(send: true)
            if !sent {
                phase = .idle
                level = 0
                note = "Too short. Try again"
            }
        case .speaking:
            mouth.stop()
            phase = .idle
            level = 0
            note = "Stopped"
        case .idle:
            Task { await beginListening() }
        case .booting, .transcribing, .thinking:
            break
        }
    }

    private func bootstrap() async {
        phase = .booting
        note = "Checking the engine"
        if await ping(ready: true) {
            await refreshOptions()
            phase = .idle
            note = "Tap the glass and speak"
            return
        }
        note = "Loading Whisper and F5-TTS"
        launchServer()
        for _ in 0..<240 {
            if await ping(ready: true) {
                await refreshOptions()
                phase = .idle
                note = "Tap the glass and speak"
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        errorText = "The engine did not answer. Check \(projectRoot.path)/server.py"
        note = "No connection to the engine"
    }

    private func beginListening() async {
        errorText = nil
        let allowed = await Ear.requestPermission()
        guard allowed else {
            errorText = "No microphone access. Allow it for Gladais in System Settings."
            return
        }
        do {
            try ear.start()
            phase = .listening
            caption = ""
            note = "Speak. A pause ends the phrase"
        } catch {
            errorText = "Could not open the microphone: \(error.localizedDescription)"
        }
    }

    private func handleUtterance(_ samples: [Float]) async {
        phase = .transcribing
        level = 0
        note = "Transcribing"
        do {
            let text = try await transcribe(samples)
            guard !text.isEmpty else {
                phase = .idle
                note = "Could not make out the speech"
                return
            }
            caption = text
            append(role: "user", text: text)
            phase = .thinking
            note = "Thinking"
            let reply = try await reply(to: currentMessages())
            append(role: "assistant", text: reply)
            caption = reply
            phase = .speaking
            note = "Speaking"
            let audio = try await speak(spoken(reply))
            try mouth.play(audio)
        } catch {
            phase = .idle
            level = 0
            errorText = error.localizedDescription
            note = "Something went wrong"
        }
    }

    private func currentMessages() -> [[String: String]] {
        (selected?.messages ?? []).map { ["role": $0.role, "content": $0.text] }
    }

    private func append(role: String, text: String) {
        guard let index = dialogues.firstIndex(where: { $0.id == selectedID }) else { return }
        dialogues[index].messages.append(ChatTurn(id: UUID(), role: role, text: text, date: Date()))
        dialogues[index].updatedAt = Date()
        if role == "user", dialogues[index].title == "New chat" {
            dialogues[index].title = String(text.prefix(42))
        }
        let moved = dialogues.remove(at: index)
        dialogues.insert(moved, at: 0)
        selectedID = moved.id
        save()
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        var request = URLRequest(url: endpoint("/v1/transcribe"))
        request.httpMethod = "POST"
        request.httpBody = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let body = try JSONDecoder().decode(TextBody.self, from: data)
        return body.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reply(to messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: endpoint("/v1/reply"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["model": modelID, "messages": messages]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(TextBody.self, from: data).text
    }

    private func spoken(_ text: String) -> String {
        var cleaned = text
        for token in ["**", "`", "#", "*", "_"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: " ")
        }
        return cleaned.replacingOccurrences(of: "\n", with: " ")
    }

    private func speak(_ text: String) async throws -> Data {
        var request = URLRequest(url: endpoint("/v1/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["text": text, "speaker": voiceID]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? "Voice error"
            throw EngineError.server(message)
        }
        return data
    }

    private func refreshOptions() async {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint("/v1/options")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let rawModels = json["models"] as? [String], !rawModels.isEmpty {
            models = rawModels
        }
        if !models.contains(modelID) {
            modelID = models[0]
        }
    }

    func chooseVoice(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "glaze.voice")
    }

    func chooseModel(_ id: String) {
        modelID = id
        UserDefaults.standard.set(id, forKey: "glaze.model")
    }

    private func ping(ready: Bool) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: endpoint("/health")),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return !ready || (json["ready"] as? Bool == true)
    }

    private func launchServer() {
        let root = projectRoot
        let python = root.appendingPathComponent(".venv/bin/python").path
        let script = root.appendingPathComponent("server.py").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            errorText = "Not found: \(python)"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script]
        process.currentDirectoryURL = root
        let log = root.appendingPathComponent("macos/server.log").path
        FileManager.default.createFile(atPath: log, contents: nil)
        if let handle = FileHandle(forWritingAtPath: log) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            server = process
        } catch {
            errorText = "Could not start the engine: \(error.localizedDescription)"
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:8765\(path)")!
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode >= 400 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let message = json["error"] {
                throw EngineError.server(message)
            }
            throw EngineError.server("Error \(http.statusCode)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Dialogue].self, from: data) else { return }
        dialogues = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(dialogues) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private var projectRoot: URL {
        if let override = ProcessInfo.processInfo.environment["GLADAIS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let bundle = Bundle.main.bundleURL
        let starts = [
            bundle.pathExtension == "app" ? bundle.deletingLastPathComponent() : bundle,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        ]
        for start in starts {
            var cursor = start
            for _ in 0..<8 {
                if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("server.py").path) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }
        if bundle.pathExtension == "app" {
            return bundle.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
}

private struct TextBody: Decodable {
    var text: String
}

private enum EngineError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server(let message): message
        }
    }
}
