import Foundation

enum MaintainerItemKind: String, Codable, CaseIterable {
    case issue
    case pullRequest

    var displayName: String {
        switch self {
        case .issue: return "Issue"
        case .pullRequest: return "PR"
        }
    }
}
enum MaintainerTaskStatus: String, Codable, CaseIterable {
    case discovered
    case reviewing
    case awaitingApproval
    case publishing
    case published
    case failed
    case ignored

    var isBusy: Bool { self == .reviewing || self == .publishing }
    var canReview: Bool { self == .discovered || self == .failed || self == .awaitingApproval }
    var canPublish: Bool { self == .awaitingApproval }
}

struct MaintainerReview: Codable, Equatable {
    let verdict: String
    let summary: String
    let markdown: String
    let completedAt: Date
}

struct MaintainerTask: Identifiable, Codable, Equatable {
    let id: String
    let repository: String
    let number: Int
    let kind: MaintainerItemKind
    var title: String
    let url: URL
    var author: String
    var sourceUpdatedAt: Date
    var revision: String
    var status: MaintainerTaskStatus
    var discoveredAt: Date
    var updatedAt: Date
    var codexThreadID: String?
    var review: MaintainerReview?
    var errorMessage: String?
    var publishedCommentURL: URL?

    static func stableID(repository: String, kind: MaintainerItemKind, number: Int) -> String {
        "\(repository.lowercased()):\(kind.rawValue):\(number)"
    }

    var reviewFingerprint: String {
        "\(sourceUpdatedAt.timeIntervalSince1970):\(revision)"
    }

    mutating func beginReview(at now: Date = Date()) throws {
        guard status.canReview else { throw MaintainerError.invalidTransition(status, .reviewing) }
        status = .reviewing
        errorMessage = nil
        updatedAt = now
    }

    mutating func completeReview(_ review: MaintainerReview, threadID: String, at now: Date = Date()) throws {
        guard status == .reviewing else { throw MaintainerError.invalidTransition(status, .awaitingApproval) }
        self.review = review
        codexThreadID = threadID
        status = .awaitingApproval
        errorMessage = nil
        updatedAt = now
    }

    mutating func beginPublishing(at now: Date = Date()) throws {
        guard status.canPublish, review != nil else { throw MaintainerError.invalidTransition(status, .publishing) }
        status = .publishing
        errorMessage = nil
        updatedAt = now
    }

    mutating func completePublishing(commentURL: URL?, at now: Date = Date()) throws {
        guard status == .publishing else { throw MaintainerError.invalidTransition(status, .published) }
        publishedCommentURL = commentURL
        status = .published
        errorMessage = nil
        updatedAt = now
    }

    mutating func fail(_ message: String, at now: Date = Date()) {
        status = .failed
        errorMessage = message
        updatedAt = now
    }
}

struct MaintainerConfiguration: Codable, Equatable {
    var enabled: Bool
    var repository: String
    var localRepositoryPath: String
    var triggerLabel: String
    var pollIntervalSeconds: TimeInterval

    static let `default` = MaintainerConfiguration(
        enabled: false,
        repository: "shanggqm/codexU",
        localRepositoryPath: "",
        triggerLabel: "codex:review",
        pollIntervalSeconds: 60
    )

    var normalizedRepository: String {
        repository.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedPath: String {
        NSString(string: localRepositoryPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    }

    var isValid: Bool {
        let components = normalizedRepository.split(separator: "/")
        return components.count == 2 && !normalizedPath.isEmpty
    }
}

enum MaintainerError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case commandFailed(String)
    case invalidResponse(String)
    case appServerUnavailable(String)
    case reviewFailed(String)
    case invalidTransition(MaintainerTaskStatus, MaintainerTaskStatus)
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value): return value
        case .commandFailed(let value): return value
        case .invalidResponse(let value): return value
        case .appServerUnavailable(let value): return value
        case .reviewFailed(let value): return value
        case .invalidTransition(let from, let to): return "不允许从 \(from.rawValue) 进入 \(to.rawValue)"
        case .taskNotFound: return "维护任务不存在"
        }
    }
}

enum MaintainerConfigurationStore {
    private static let key = "maintainer.configuration.v1"

    static func load(defaults: UserDefaults = .standard) -> MaintainerConfiguration {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(MaintainerConfiguration.self, from: data) else {
            return .default
        }
        return value
    }

    static func save(_ configuration: MaintainerConfiguration, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
