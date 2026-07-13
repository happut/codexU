import Foundation

struct GitHubMaintainerItem: Equatable {
    let repository: String
    let number: Int
    let kind: MaintainerItemKind
    let title: String
    let url: URL
    let author: String
    let updatedAt: Date
    let revision: String

    func makeTask(now: Date = Date()) -> MaintainerTask {
        MaintainerTask(
            id: MaintainerTask.stableID(repository: repository, kind: kind, number: number),
            repository: repository,
            number: number,
            kind: kind,
            title: title,
            url: url,
            author: author,
            sourceUpdatedAt: updatedAt,
            revision: revision,
            status: .discovered,
            discoveredAt: now,
            updatedAt: now,
            codexThreadID: nil,
            review: nil,
            errorMessage: nil,
            publishedCommentURL: nil
        )
    }
}

struct GitHubReviewContext {
    let item: GitHubMaintainerItem
    let body: String
    let comments: String
    let diff: String?
}

final class GitHubMaintainerClient: @unchecked Sendable {
    private let runner: LocalCommandRunning
    private let ghPath: String?
    private let decoder = JSONDecoder()

    init(runner: LocalCommandRunning = LocalCommandRunner(), ghPath: String? = MaintainerExecutableResolver.resolve("gh")) {
        self.runner = runner
        self.ghPath = ghPath
        decoder.dateDecodingStrategy = .iso8601
    }

    func validateAuthentication() throws {
        let result = try run(["auth", "status"], timeout: 20)
        guard result.exitCode == 0 else {
            throw MaintainerError.commandFailed(result.standardError.isEmpty ? "GitHub CLI 尚未登录，请先运行 gh auth login" : result.standardError)
        }
    }

    func discover(repository: String, label: String) throws -> [GitHubMaintainerItem] {
        try validateAuthentication()
        let result = try run([
            "api", "-X", "GET", "repos/\(repository)/issues",
            "--paginate", "--slurp",
            "-f", "state=open", "-f", "labels=\(label)", "-f", "per_page=100"
        ])
        guard result.exitCode == 0 else { throw commandError(result) }

        let rawItems: [IssueListItem]
        do {
            rawItems = try decoder.decode([[IssueListItem]].self, from: result.standardOutput).flatMap { $0 }
        } catch {
            throw MaintainerError.invalidResponse("无法解析 GitHub Issue 列表：\(error.localizedDescription)")
        }

        return try rawItems.map { item in
            let kind: MaintainerItemKind = item.pullRequest == nil ? .issue : .pullRequest
            let revision: String
            if kind == .pullRequest {
                revision = try pullRequestRevision(repository: repository, number: item.number)
            } else {
                revision = "issue-\(stableFingerprint(item.title + "\u{0}" + (item.body ?? "")))"
            }
            guard let url = URL(string: item.htmlURL) else {
                throw MaintainerError.invalidResponse("GitHub 返回了无效 URL")
            }
            return GitHubMaintainerItem(
                repository: repository,
                number: item.number,
                kind: kind,
                title: item.title,
                url: url,
                author: item.user.login,
                updatedAt: item.updatedAt,
                revision: revision
            )
        }
    }

    func reviewContext(for task: MaintainerTask) throws -> GitHubReviewContext {
        let fields = task.kind == .pullRequest
            ? "title,body,author,updatedAt,url,comments,headRefOid"
            : "title,body,author,updatedAt,url,comments"
        let command = task.kind == .pullRequest ? "pr" : "issue"
        let result = try run([command, "view", String(task.number), "--repo", task.repository, "--json", fields])
        guard result.exitCode == 0 else { throw commandError(result) }

        let object: ViewObject
        do {
            object = try decoder.decode(ViewObject.self, from: result.standardOutput)
        } catch {
            throw MaintainerError.invalidResponse("无法解析 GitHub 上下文：\(error.localizedDescription)")
        }

        var diff: String?
        if task.kind == .pullRequest {
            let diffResult = try run(["pr", "diff", String(task.number), "--repo", task.repository], timeout: 90)
            guard diffResult.exitCode == 0 else { throw commandError(diffResult) }
            let fullDiff = String(data: diffResult.standardOutput, encoding: .utf8) ?? ""
            diff = String(fullDiff.prefix(180_000))
        }

        let item = GitHubMaintainerItem(
            repository: task.repository,
            number: task.number,
            kind: task.kind,
            title: object.title,
            url: URL(string: object.url) ?? task.url,
            author: object.author.login,
            updatedAt: object.updatedAt,
            revision: object.headRefOID ?? task.revision
        )
        let comments = object.comments.suffix(20).map { "@\($0.author.login): \($0.body)" }.joined(separator: "\n\n")
        return GitHubReviewContext(item: item, body: object.body ?? "", comments: comments, diff: diff)
    }

    func publish(review: MaintainerReview, for task: MaintainerTask) throws -> URL? {
        let marker = commentMarker(for: task)
        if let existing = try existingCommentURL(for: task, marker: marker) { return existing }

        let body = "\(review.markdown)\n\n---\n由 codexU Maintainer 审查；发布前已经维护者批准。\n\(marker)"
        let payload = try JSONSerialization.data(withJSONObject: ["body": body])
        let result = try run([
            "api", "-X", "POST", "repos/\(task.repository)/issues/\(task.number)/comments", "--input", "-"
        ], input: payload)
        guard result.exitCode == 0 else { throw commandError(result) }
        let response = try decoder.decode(CommentResponse.self, from: result.standardOutput)
        return URL(string: response.htmlURL)
    }

    func commentMarker(for task: MaintainerTask) -> String {
        "<!-- codexu-maintainer:\(task.id):\(task.revision) -->"
    }

    private func existingCommentURL(for task: MaintainerTask, marker: String) throws -> URL? {
        let result = try run([
            "api", "-X", "GET", "repos/\(task.repository)/issues/\(task.number)/comments",
            "--paginate", "--slurp", "-f", "per_page=100"
        ])
        guard result.exitCode == 0 else { throw commandError(result) }
        let comments = try decoder.decode([[ExistingComment]].self, from: result.standardOutput).flatMap { $0 }
        return comments.first(where: { $0.body.contains(marker) }).flatMap { URL(string: $0.htmlURL) }
    }

    private func pullRequestRevision(repository: String, number: Int) throws -> String {
        let result = try run(["pr", "view", String(number), "--repo", repository, "--json", "headRefOid", "--jq", ".headRefOid"])
        guard result.exitCode == 0 else { throw commandError(result) }
        return String(data: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 60) throws -> LocalCommandResult {
        guard let ghPath else { throw MaintainerError.commandFailed("未找到 GitHub CLI，请先安装 gh") }
        return try runner.run(executable: ghPath, arguments: arguments, input: input, timeout: timeout)
    }

    private func commandError(_ result: LocalCommandResult) -> MaintainerError {
        .commandFailed(result.standardError.isEmpty ? "GitHub CLI 执行失败（exit \(result.exitCode)）" : result.standardError)
    }

    private func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private struct IssueListItem: Decodable {
        let number: Int
        let title: String
        let body: String?
        let htmlURL: String
        let updatedAt: Date
        let user: User
        let pullRequest: PullRequestMarker?

        enum CodingKeys: String, CodingKey {
            case number, title, body, user
            case htmlURL = "html_url"
            case updatedAt = "updated_at"
            case pullRequest = "pull_request"
        }
    }

    private struct PullRequestMarker: Decodable {}
    private struct User: Decodable { let login: String }
    private struct Author: Decodable { let login: String }
    private struct ViewComment: Decodable { let author: Author; let body: String }
    private struct ViewObject: Decodable {
        let title: String
        let body: String?
        let author: Author
        let updatedAt: Date
        let url: String
        let comments: [ViewComment]
        let headRefOID: String?

        enum CodingKeys: String, CodingKey {
            case title, body, author, updatedAt, url, comments
            case headRefOID = "headRefOid"
        }
    }
    private struct CommentResponse: Decodable {
        let htmlURL: String
        enum CodingKeys: String, CodingKey { case htmlURL = "html_url" }
    }
    private struct ExistingComment: Decodable {
        let body: String
        let htmlURL: String
        enum CodingKeys: String, CodingKey { case body; case htmlURL = "html_url" }
    }
}
