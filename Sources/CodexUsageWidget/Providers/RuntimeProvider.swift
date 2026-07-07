import Foundation

struct RuntimeLoadContext {
    let now: Date
    let homeDirectory: URL
    let cacheDirectory: URL

    static func live(now: Date = Date()) -> RuntimeLoadContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("codexU", isDirectory: true)
            ?? home.appendingPathComponent("Library/Caches/codexU", isDirectory: true)
        return RuntimeLoadContext(now: now, homeDirectory: home, cacheDirectory: cache)
    }
}

protocol RuntimeUsageProvider {
    var scope: RuntimeScope { get }
    func loadSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot
    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard?
}

struct RuntimeProviderRegistry {
    let providers: [any RuntimeUsageProvider]

    init(providers: [any RuntimeUsageProvider] = [
        CodexRuntimeProvider(),
        ClaudeCodeRuntimeProvider()
    ]) {
        self.providers = providers
    }

    func provider(for scope: RuntimeScope) -> (any RuntimeUsageProvider)? {
        providers.first { $0.scope == scope }
    }
}

struct CodexRuntimeProvider: RuntimeUsageProvider {
    let scope: RuntimeScope = .codex

    func loadSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        let snapshot = CodexUsageReader().load()
        let status: RuntimeMenuStatus
        if snapshot.primary != nil || snapshot.secondary != nil {
            status = .available
        } else if snapshot.local != nil {
            status = .localOnly
        } else {
            status = .unavailable
        }

        return RuntimeUsageSnapshot(
            scope: scope,
            snapshot: snapshot,
            status: status,
            quotaSourceLabel: "Codex app-server + local records",
            usageSourceLabel: "Codex local state"
        )
    }

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? {
        CodexUsageReader().loadTaskBoard()
    }
}
