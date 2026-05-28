import AppKit
import SwiftUI

enum ChatRole: String, Sendable {
    case user
    case assistant

    var promptName: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Jarvis"
        }
    }
}

struct ChatMessage: Identifiable, Sendable {
    let id = UUID()
    let role: ChatRole
    let text: String
}

final class OpenClawClient {
    private struct AgentRunResponse: Decodable {
        struct Payload: Decodable {
            let text: String?
        }

        struct Meta: Decodable {
            let finalAssistantVisibleText: String?
            let finalAssistantRawText: String?
        }

        let payloads: [Payload]?
        let meta: Meta?
    }

    private let queue = DispatchQueue(label: "Jarvis.OpenClaw", qos: .userInitiated)

    func send(history: [ChatMessage], completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = Self.makePrompt(from: history)

        queue.async {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-lc",
                Self.openClawShellCommand,
                "jarvis-openclaw",
                prompt
            ]
            process.standardOutput = stdout
            process.standardError = stderr

            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment

            do {
                try process.run()
            } catch {
                completion(.failure(error))
                return
            }

            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: outputData, encoding: .utf8) ?? ""
            let errorText = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let details = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = details.isEmpty ? fallback : details
                completion(.failure(OpenClawError.commandFailed(message.isEmpty ? "OpenClaw exited with status \(process.terminationStatus)." : message)))
                return
            }

            do {
                let response = try JSONDecoder().decode(AgentRunResponse.self, from: outputData)
                if let text = response.payloads?.compactMap(\.text).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if let text = response.meta?.finalAssistantVisibleText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    completion(.success(text))
                } else if let text = response.meta?.finalAssistantRawText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(OpenClawError.commandFailed("OpenClaw returned no text.")))
                }
            } catch {
                let cleanOutput = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanOutput.isEmpty {
                    completion(.failure(error))
                } else {
                    completion(.success(cleanOutput))
                }
            }
        }
    }

    private static let openClawShellCommand = """
    if command -v openclaw >/dev/null 2>&1; then
      exec openclaw agent --local --agent dev --session-id jarvis-desktop --json --timeout 600 --thinking off --message "$1"
    fi

    for candidate in "$HOME"/.local/state/fnm_multishells/*/bin/openclaw "$HOME"/.local/bin/openclaw /opt/homebrew/bin/openclaw /usr/local/bin/openclaw; do
      if [ -x "$candidate" ]; then
        candidate_dir="${candidate%/*}"
        export PATH="$candidate_dir:$PATH"
        exec "$candidate" agent --local --agent dev --session-id jarvis-desktop --json --timeout 600 --thinking off --message "$1"
      fi
    done

    echo "Jarvis could not find the openclaw command. Open Terminal and confirm 'openclaw agent --local --agent dev --message hi' works." >&2
    exit 127
    """

    private static func makePrompt(from history: [ChatMessage]) -> String {
        let latest = history.last(where: { $0.role == .user })?.text ?? ""
        let recent = history.suffix(18).map { message in
            "\(message.role.promptName): \(message.text)"
        }.joined(separator: "\n\n")

        return """
        You are Jarvis, a cute desktop robot assistant living in the bottom-right corner of Rex's Mac. You are connected directly through OpenClaw agent mode.

        Rex wants Jarvis to use OpenClaw's tools to operate this Mac when he asks. For local actions like opening apps, opening websites, searching the web, managing files, or running commands, actually use the available tools instead of only explaining how. After completing an action, reply briefly as Jarvis with what happened.

        For website-opening requests, always resolve named websites to explicit URLs before using tools. Examples:
        - "open YouTube" means open https://www.youtube.com
        - "open Google" means open https://www.google.com
        - "open GitHub" means open https://github.com

        Do not claim that a website or app was opened unless the tool call completed. Prefer direct commands such as opening the full URL over vague requests like "open YouTube".

        Be concise, warm, and practical. Keep short questions short. Use the conversation history below for context.

        Latest user request:
        \(latest)

        Conversation:
        \(recent)

        Jarvis:
        """
    }
}

enum OpenClawError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

struct LocalDesktopAction {
    let successReply: String
    let openArgumentCandidates: [[String]]

    func perform(completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lastError: Error?

            for arguments in openArgumentCandidates {
                switch Self.runOpen(arguments: arguments) {
                case .success:
                    completion(.success(successReply))
                    return
                case .failure(let error):
                    lastError = error
                }
            }

            completion(.failure(lastError ?? OpenClawError.commandFailed("The local open command did not complete.")))
        }
    }

    static func match(_ rawText: String) -> LocalDesktopAction? {
        let text = normalize(rawText)
        guard hasOpenIntent(text) else { return nil }

        if text.contains("roblox") {
            return LocalDesktopAction(
                successReply: "Opened Roblox.",
                openArgumentCandidates: [
                    ["-a", "Roblox"],
                    ["-a", "RobloxPlayer"]
                ]
            )
        }

        if let website = matchedWebsite(in: text) {
            if text.contains("chrome") {
                return LocalDesktopAction(
                    successReply: "Opened \(website.name) in Chrome.",
                    openArgumentCandidates: [
                        ["-a", "Google Chrome", website.url],
                        [website.url]
                    ]
                )
            }

            return LocalDesktopAction(
                successReply: "Opened \(website.name).",
                openArgumentCandidates: [
                    [website.url]
                ]
            )
        }

        if text.contains("chrome"), text.contains("tab") {
            return LocalDesktopAction(
                successReply: "Opened a new Chrome tab.",
                openArgumentCandidates: [
                    ["-a", "Google Chrome", "about:blank"],
                    ["-a", "Google Chrome"]
                ]
            )
        }

        if text.contains("chrome") {
            return LocalDesktopAction(
                successReply: "Opened Chrome.",
                openArgumentCandidates: [
                    ["-a", "Google Chrome"]
                ]
            )
        }

        return nil
    }

    private static let knownWebsites: [(name: String, aliases: [String], url: String)] = [
        ("YouTube", ["youtube", "you tube", "youtube com"], "https://www.youtube.com"),
        ("Google", ["google", "google com"], "https://www.google.com"),
        ("Gmail", ["gmail", "mail google"], "https://mail.google.com"),
        ("GitHub", ["github", "git hub", "github com"], "https://github.com"),
        ("ChatGPT", ["chatgpt", "chat gpt"], "https://chatgpt.com")
    ]

    private static func matchedWebsite(in text: String) -> (name: String, aliases: [String], url: String)? {
        knownWebsites.first { website in
            if website.name == "Google", text.contains("google chrome") {
                return false
            }

            return website.aliases.contains(where: { text.contains($0) })
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9:/\.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasOpenIntent(_ text: String) -> Bool {
        let phrases = [
            "open",
            "launch",
            "start",
            "visit",
            "go to",
            "show",
            "bring up",
            "pull up",
            "new tab",
            "play roblox"
        ]

        return phrases.contains(where: { text.contains($0) })
    }

    private static func runOpen(arguments: [String]) -> Result<Void, Error> {
        let process = Process()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let details = errorText.isEmpty ? "open exited with status \(process.terminationStatus)." : errorText
            return .failure(OpenClawError.commandFailed(details))
        }

        return .success(())
    }
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: "Hi, I'm Jarvis. I'm connected to OpenClaw agent mode now, so I can chat and use OpenClaw tools when you ask me to do things on this Mac.")
    ]
    @Published var draft = ""
    @Published var isLoading = false
    @Published var status = "OpenClaw agent"

    private let client: OpenClawClient

    init(client: OpenClawClient) {
        self.client = client
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        draft = ""
        status = "Thinking"
        isLoading = true
        messages.append(ChatMessage(role: .user, text: text))

        let history = messages
        if let localAction = LocalDesktopAction.match(text) {
            status = "Opening locally"
            localAction.perform { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }

                    switch result {
                    case .success(let reply):
                        self.isLoading = false
                        self.status = "OpenClaw agent"
                        self.messages.append(ChatMessage(role: .assistant, text: reply))
                    case .failure:
                        self.status = "Trying OpenClaw"
                        self.sendToOpenClaw(history: history)
                    }
                }
            }
            return
        }

        sendToOpenClaw(history: history)
    }

    private func sendToOpenClaw(history: [ChatMessage]) {
        client.send(history: history) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false

                switch result {
                case .success(let reply):
                    self.status = "OpenClaw agent"
                    self.messages.append(ChatMessage(role: .assistant, text: reply))
                case .failure(let error):
                    self.status = "Needs attention"
                    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.messages.append(ChatMessage(role: .assistant, text: "I couldn't reach OpenClaw cleanly: \(message)"))
                }
            }
        }
    }

    func clear() {
        guard !isLoading else { return }
        messages = [
            ChatMessage(role: .assistant, text: "Fresh chat ready.")
        ]
        status = "OpenClaw agent"
    }
}

struct JarvisChatView: View {
    @ObservedObject var model: ChatModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if model.isLoading {
                            TypingBubble()
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .background(Color(nsColor: .clear))
                .onChange(of: model.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: model.isLoading) {
                    scrollToBottom(proxy)
                }
            }

            Divider()
                .opacity(0.35)

            inputBar
        }
        .frame(width: 390, height: 520)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RobotBadge()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Jarvis")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isLoading ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(model.status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                model.clear()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Clear chat")
            .foregroundStyle(.secondary)
            .disabled(model.isLoading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Hide Jarvis")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask Jarvis...", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
                .disabled(model.isLoading)
                .onSubmit {
                    model.send()
                }

            Button {
                model.send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(red: 0.10, green: 0.58, blue: 0.72)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send")
        }
        .padding(14)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if model.isLoading {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("typing", anchor: .bottom)
                }
            } else if let last = model.messages.last {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user {
                Spacer(minLength: 42)
            }

            Text(message.text)
                .font(.system(size: 14.5, weight: .regular, design: .rounded))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(message.role == .user ? Color(red: 0.12, green: 0.55, blue: 0.72) : Color.primary.opacity(0.08))
                )
                .frame(maxWidth: 285, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer(minLength: 42)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.75))
                        .frame(width: 6, height: 6)
                        .opacity(index == 1 ? 0.55 : 0.9)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )

            Spacer(minLength: 42)
        }
    }
}

struct RobotButtonView: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.18)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let bob = sin(time * 2.4) * 2.0
            let blinking = time.truncatingRemainder(dividingBy: 4.2) > 4.02

            Button(action: onTap) {
                VStack(spacing: 3) {
                    RobotAvatar(blinking: blinking, isHovering: isHovering)
                        .frame(width: 92, height: 96)
                        .offset(y: bob)

                    Text("Jarvis")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.08, green: 0.36, blue: 0.46).opacity(0.88))
                        )
                        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Jarvis chat")
            .frame(width: 112, height: 124)
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .contextMenu {
                Button("Quit Jarvis") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

struct RobotBadge: View {
    var body: some View {
        RobotAvatar(blinking: false, isHovering: false)
            .padding(2)
            .background(Circle().fill(Color(red: 0.09, green: 0.35, blue: 0.45).opacity(0.12)))
    }
}

struct RobotAvatar: View {
    let blinking: Bool
    let isHovering: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = min(width, height) / 100

            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 58 * scale, height: 12 * scale)
                    .offset(y: 43 * scale)
                    .blur(radius: 1.5 * scale)

                VStack(spacing: 0) {
                    antenna(scale: scale)

                    ZStack {
                        RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.74, green: 0.96, blue: 1.0),
                                        Color(red: 0.16, green: 0.66, blue: 0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                                    .stroke(Color.white.opacity(0.65), lineWidth: 2 * scale)
                            )
                            .frame(width: 76 * scale, height: 58 * scale)

                        RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                            .fill(Color(red: 0.93, green: 0.99, blue: 1.0))
                            .frame(width: 58 * scale, height: 34 * scale)
                            .overlay(face(scale: scale))
                            .shadow(color: .black.opacity(0.08), radius: 2 * scale, x: 0, y: 1 * scale)
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                            .fill(Color(red: 0.10, green: 0.45, blue: 0.58))
                            .frame(width: 60 * scale, height: 34 * scale)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
                                    .stroke(Color.white.opacity(0.28), lineWidth: 1.5 * scale)
                            )

                        Capsule()
                            .fill(Color.white.opacity(0.86))
                            .frame(width: 26 * scale, height: 8 * scale)
                    }
                    .offset(y: -3 * scale)
                }
                .shadow(color: Color(red: 0.04, green: 0.18, blue: 0.25).opacity(isHovering ? 0.35 : 0.25), radius: isHovering ? 13 * scale : 9 * scale, x: 0, y: 7 * scale)
            }
            .frame(width: width, height: height)
        }
    }

    private func antenna(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color(red: 1.0, green: 0.73, blue: 0.42))
                .frame(width: 11 * scale, height: 11 * scale)
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1 * scale))

            RoundedRectangle(cornerRadius: 2 * scale)
                .fill(Color(red: 0.12, green: 0.50, blue: 0.62))
                .frame(width: 4 * scale, height: 12 * scale)
        }
        .offset(y: 3 * scale)
    }

    private func face(scale: CGFloat) -> some View {
        HStack(spacing: 11 * scale) {
            eye(scale: scale)
            eye(scale: scale)
        }
        .overlay(
            HStack(spacing: 34 * scale) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.53, blue: 0.56).opacity(0.7))
                    .frame(width: 7 * scale, height: 7 * scale)
                Circle()
                    .fill(Color(red: 1.0, green: 0.53, blue: 0.56).opacity(0.7))
                    .frame(width: 7 * scale, height: 7 * scale)
            }
            .offset(y: 9 * scale)
        )
    }

    private func eye(scale: CGFloat) -> some View {
        Group {
            if blinking {
                Capsule()
                    .fill(Color(red: 0.05, green: 0.22, blue: 0.28))
                    .frame(width: 12 * scale, height: 3 * scale)
            } else {
                Circle()
                    .fill(Color(red: 0.04, green: 0.22, blue: 0.28))
                    .frame(width: 11 * scale, height: 11 * scale)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 3.5 * scale, height: 3.5 * scale)
                            .offset(x: -2 * scale, y: -2 * scale)
                    )
            }
        }
    }
}

final class JarvisPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class JarvisWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = OpenClawClient()
    private lazy var chatModel = ChatModel(client: client)
    private var robotWindow: JarvisWindow?
    private var chatWindow: JarvisPanel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Jarvis is waiting on the desktop.")
        buildMenu()
        buildStatusItem()
        buildRobotWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showJarvis()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showJarvis()
        return true
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Show Jarvis", action: #selector(showJarvis), keyEquivalent: "j"))
        appMenu.addItem(menuItem("Reposition Jarvis", action: #selector(repositionJarvis), keyEquivalent: "r"))
        appMenu.addItem(menuItem("Hide Jarvis Chat", action: #selector(hideChat), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Jarvis")
        item.button?.title = " Jarvis"

        let menu = NSMenu()
        menu.addItem(menuItem("Show Jarvis", action: #selector(showJarvis)))
        menu.addItem(menuItem("Reposition to Bottom Right", action: #selector(repositionJarvis)))
        menu.addItem(menuItem("Open Chat", action: #selector(openChat)))
        menu.addItem(menuItem("Hide Chat", action: #selector(hideChat)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func buildRobotWindow() {
        let size = NSSize(width: 112, height: 124)
        let window = JarvisWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.canHide = false
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        let hostingView = NSHostingView(rootView: RobotButtonView { [weak self] in
            self?.toggleChat()
        })
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        robotWindow = window
        positionRobot()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func buildChatWindowIfNeeded() {
        guard chatWindow == nil else { return }

        let size = NSSize(width: 390, height: 520)
        let window = JarvisPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: JarvisChatView(model: chatModel) { [weak self] in
            self?.hideChat()
        })

        chatWindow = window
    }

    private func positionRobot() {
        guard let window = robotWindow else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let margin: CGFloat = 16
        let origin = NSPoint(x: visibleFrame.maxX - window.frame.width - margin, y: visibleFrame.minY + margin)
        window.setFrameOrigin(origin)
    }

    private func positionChat() {
        guard let chatWindow, let robotWindow else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(robotWindow.frame) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let margin: CGFloat = 12
        var x = robotWindow.frame.maxX - chatWindow.frame.width
        var y = robotWindow.frame.maxY + margin

        if y + chatWindow.frame.height > visibleFrame.maxY {
            y = max(visibleFrame.minY + margin, robotWindow.frame.minY - chatWindow.frame.height - margin)
        }
        if x < visibleFrame.minX + margin {
            x = visibleFrame.minX + margin
        }
        if x + chatWindow.frame.width > visibleFrame.maxX - margin {
            x = visibleFrame.maxX - chatWindow.frame.width - margin
        }

        chatWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func toggleChat() {
        buildChatWindowIfNeeded()
        guard let chatWindow else { return }

        if chatWindow.isVisible {
            hideChat()
        } else {
            openChat()
        }
    }

    @objc private func showJarvis() {
        positionRobot()
        robotWindow?.makeKeyAndOrderFront(nil)
        robotWindow?.orderFrontRegardless()
    }

    @objc private func repositionJarvis() {
        showJarvis()
        if chatWindow?.isVisible == true {
            positionChat()
            chatWindow?.orderFrontRegardless()
        }
    }

    @objc private func openChat() {
        buildChatWindowIfNeeded()
        positionRobot()
        positionChat()
        robotWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        chatWindow?.makeKeyAndOrderFront(nil)
        chatWindow?.orderFrontRegardless()
    }

    @objc private func hideChat() {
        chatWindow?.orderOut(nil)
    }

    @objc private func screenParametersChanged() {
        positionRobot()
        positionChat()
    }
}

@main
enum JarvisMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.finishLaunching()
        app.run()
        _ = delegate
    }
}
