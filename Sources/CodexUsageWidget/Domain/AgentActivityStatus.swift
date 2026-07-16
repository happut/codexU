import Combine
import Foundation

enum AgentActivityPhase: String, Codable, CaseIterable, Equatable {
    case idle
    case running
    case requiresInput = "requires_input"
    case completed
    case failed

    var priority: Int {
        switch self {
        case .requiresInput: return 5
        case .failed: return 4
        case .running: return 3
        case .completed: return 2
        case .idle: return 1
        }
    }

    func localized(_ language: WidgetLanguage) -> String {
        switch self {
        case .idle: return language.text("空闲", "Idle")
        case .running: return language.text("即将调用工具", "Starting tool call")
        case .requiresInput: return language.text("等待确认", "Awaiting confirmation")
        case .completed: return language.text("任务结束", "Task ended")
        case .failed: return language.text("执行失败", "Failed")
        }
    }

    static func codexHookEvent(_ name: String) -> AgentActivityPhase? {
        switch name {
        case "PreToolUse": return .running
        case "PermissionRequest": return .requiresInput
        case "TaskCompleted", "Stop": return .completed
        default: return nil
        }
    }
}

struct AgentActivitySnapshot: Codable, Equatable {
    let version: Int
    let runtime: RuntimeScope
    let sessionID: String
    let phase: AgentActivityPhase
    let updatedAt: Date
}

enum AgentActivityPaths {
    static func root(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEXU_AGENT_STATUS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.temporaryDirectory.appendingPathComponent(
            "codexU-agent-status",
            isDirectory: true
        )
    }
}

enum AgentActivityHookCommand {
    static func run(arguments: [String] = CommandLine.arguments) -> Int32? {
        if arguments.contains("--install-codex-status-hook") {
            do {
                try CodexHookConfiguration().install()
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        if arguments.contains("--uninstall-codex-status-hook") {
            do {
                try CodexHookConfiguration().uninstall()
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        guard let index = arguments.firstIndex(of: "--agent-status-hook") else { return nil }
        guard arguments.indices.contains(index + 1),
              let runtime = RuntimeScope.storedIdentifier(arguments[index + 1]) else { return 2 }
        guard let input = try? FileHandle.standardInput.readToEnd(),
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let eventName = object["hook_event_name"] as? String,
              let phase = AgentActivityPhase.codexHookEvent(eventName) else { return 0 }

        let sessionID = (object["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else { return 0 }
        let snapshot = AgentActivitySnapshot(
            version: 1,
            runtime: runtime,
            sessionID: sessionID,
            phase: phase,
            updatedAt: Date()
        )

        do {
            let directory = AgentActivityPaths.root().appendingPathComponent(runtime.runtimeId, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeID = sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            let destination = directory.appendingPathComponent(String(safeID)).appendingPathExtension("json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: destination, options: .atomic)
            return 0
        } catch {
            return 1
        }
    }
}

final class AgentActivityStore: ObservableObject {
    @Published private(set) var phase: AgentActivityPhase = .idle
    @Published private(set) var codexHookInstalled = false
    @Published private(set) var configurationError: String?

    private var timer: Timer?
    private let configuration = CodexHookConfiguration()

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setCodexHookInstalled(_ installed: Bool) {
        do {
            if installed {
                try configuration.install()
            } else {
                try configuration.uninstall()
            }
            configurationError = nil
            refresh()
        } catch {
            configurationError = error.localizedDescription
            refresh()
        }
    }

    func refresh(now: Date = Date()) {
        codexHookInstalled = configuration.isInstalled()
        phase = Self.loadPhase(now: now)
    }

    static func loadPhase(now: Date, fileManager: FileManager = .default) -> AgentActivityPhase {
        let root = AgentActivityPaths.root(fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return .idle }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var candidates: [AgentActivitySnapshot] = []
        for case let file as URL in enumerator where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(AgentActivitySnapshot.self, from: data) else { continue }
            let age = now.timeIntervalSince(snapshot.updatedAt)
            let lifetime: TimeInterval = snapshot.phase == .completed ? 30 * 60 : 12 * 60 * 60
            if age >= 0, age <= lifetime {
                candidates.append(snapshot)
            } else if age > lifetime {
                try? fileManager.removeItem(at: file)
            }
        }
        return candidates.max {
            if $0.phase.priority == $1.phase.priority { return $0.updatedAt < $1.updatedAt }
            return $0.phase.priority < $1.phase.priority
        }?.phase ?? .idle
    }
}

struct CodexHookConfiguration {
    private static let marker = "--agent-status-hook codex"
    private static let events = ["PreToolUse", "PermissionRequest", "Stop"]
    private static let managedEvents = [
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "TaskCompleted",
        "Stop"
    ]

    private var hooksURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("hooks.json")
    }

    private var helperURL: URL {
        if let override = ProcessInfo.processInfo.environment["CODEXU_HOOK_HELPER_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(
            "codexU/hooks/codexu-hook",
            isDirectory: false
        )
    }

    func isInstalled() -> Bool {
        guard let root = try? loadRoot(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { event in
            containsManagedHook(
                hooks[event] as? [[String: Any]] ?? [],
                expectedCommand: currentCommand()
            )
        }
    }

    func install() throws {
        try installHelper()
        var root = try loadRoot()
        var hooks = try hooksDictionary(from: root)
        let command = currentCommand()

        for event in Self.managedEvents {
            let groups = try hookGroups(for: event, in: hooks).compactMap(removingManagedHooks)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }

        for event in Self.events {
            var groups = try hookGroups(for: event, in: hooks)
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 5,
                    "statusMessage": "Updating codexU agent status"
                ]]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root)
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return }
        var root = try loadRoot()
        var hooks = try hooksDictionary(from: root)
        for event in Self.managedEvents {
            let groups = try hookGroups(for: event, in: hooks)
            let filtered = groups.compactMap(removingManagedHooks)
            if filtered.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = filtered }
        }
        root["hooks"] = hooks
        try save(root)
    }

    private func loadRoot() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        let data = try Data(contentsOf: hooksURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private func save(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    private func hooksDictionary(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return hooks
    }

    private func hookGroups(for event: String, in hooks: [String: Any]) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        return groups
    }

    private func containsManagedHook(
        _ groups: [[String: Any]],
        expectedCommand: String? = nil
    ) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                guard let command = $0["command"] as? String else { return false }
                if let expectedCommand { return command == expectedCommand }
                return command.contains(Self.marker)
            } == true
        }
    }

    private func removingManagedHooks(_ group: [String: Any]) -> [String: Any]? {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let remaining = handlers.filter {
            ($0["command"] as? String)?.contains(Self.marker) != true
        }
        guard !remaining.isEmpty else { return nil }
        var result = group
        result["hooks"] = remaining
        return result
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func currentCommand() -> String {
        "\(shellQuote(helperURL.path)) \(Self.marker)"
    }

    private func installHelper() throws {
        let source = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = helperURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".codexu-hook-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: temporary.path
            )
            if FileManager.default.fileExists(atPath: helperURL.path) {
                _ = try FileManager.default.replaceItemAt(helperURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: helperURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
