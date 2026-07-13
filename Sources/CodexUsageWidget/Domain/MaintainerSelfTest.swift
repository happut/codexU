import Foundation

enum MaintainerSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let now = Date(timeIntervalSince1970: 1_720_000_000)
        var task = fixtureTask(now: now)
        expect(task.status == .discovered, "new task starts discovered")
        do {
            try task.beginReview(at: now)
            expect(task.status == .reviewing, "beginReview transition")
            let review = MaintainerReview(verdict: "comment", summary: "summary", markdown: "body", completedAt: now)
            try task.completeReview(review, threadID: "thread-test", at: now)
            expect(task.status == .awaitingApproval, "completeReview transition")
            expect(task.codexThreadID == "thread-test", "thread id persistence")
            try task.beginPublishing(at: now)
            try task.completePublishing(commentURL: URL(string: "https://github.com/o/r/issues/1#issuecomment-1"), at: now)
            expect(task.status == .published, "publishing transition")
        } catch {
            failures.append("valid transition threw: \(error)")
        }

        do {
            var invalid = fixtureTask(now: now)
            try invalid.beginPublishing(at: now)
            failures.append("invalid publishing transition was accepted")
        } catch {
            expect(true, "invalid transition rejected")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexu-maintainer-selftest-\(UUID().uuidString).json")
        let repository = MaintainerTaskRepository(fileURL: temporary)
        do {
            try repository.save([task])
            expect(repository.load() == [task], "task persistence round trip")
        } catch {
            failures.append("task persistence failed: \(error)")
        }
        try? FileManager.default.removeItem(at: temporary)

        let marker = GitHubMaintainerClient(ghPath: "/bin/false").commentMarker(for: fixtureTask(now: now))
        expect(marker.contains("codexu-maintainer:o/r:issue:1"), "comment marker contains stable task id")
        expect(MaintainerTask.stableID(repository: "O/R", kind: .issue, number: 1) == "o/r:issue:1", "stable id normalization")

        let validConfig = MaintainerConfiguration(
            enabled: true,
            repository: "o/r",
            localRepositoryPath: "/tmp/repo",
            triggerLabel: "codex:review",
            pollIntervalSeconds: 60
        )
        expect(validConfig.isValid, "valid configuration")
        var invalidConfig = validConfig
        invalidConfig.repository = "missing-slash"
        expect(!invalidConfig.isValid, "invalid repository rejected")

        do {
            let discoverRunner = FakeCommandRunner(results: [
                .success(""),
                .success("""
                [[{"number":16,"title":"E2E","body":"first body","html_url":"https://github.com/o/r/issues/16","updated_at":"2026-07-13T00:00:00Z","user":{"login":"author"}}]]
                """)
            ])
            let client = GitHubMaintainerClient(runner: discoverRunner, ghPath: "/usr/bin/gh")
            let discovered = try client.discover(repository: "o/r", label: "codex:review")
            expect(discovered.count == 1, "paginated issue discovery")
            expect(discovered.first?.kind == .issue, "issue kind decoding")
            expect(discovered.first?.revision.hasPrefix("issue-") == true, "issue body fingerprint revision")
        } catch {
            failures.append("GitHub discovery fixture failed: \(error)")
        }

        do {
            let publishTask = fixtureTask(now: now)
            let marker = GitHubMaintainerClient(ghPath: "/bin/false").commentMarker(for: publishTask)
            let existingURL = "https://github.com/o/r/issues/1#issuecomment-9"
            let publishRunner = FakeCommandRunner(results: [
                .success("[[]]"),
                .success("{\"html_url\":\"\(existingURL)\"}"),
                .success("[[{\"body\":\"\(marker)\",\"html_url\":\"\(existingURL)\"}]]")
            ])
            let client = GitHubMaintainerClient(runner: publishRunner, ghPath: "/usr/bin/gh")
            let review = MaintainerReview(verdict: "approve", summary: "ok", markdown: "review", completedAt: now)
            let firstURL = try client.publish(review: review, for: publishTask)
            let secondURL = try client.publish(review: review, for: publishTask)
            expect(firstURL?.absoluteString == existingURL, "first comment URL")
            expect(secondURL == firstURL, "idempotent existing marker lookup")
            expect(publishRunner.postCount == 1, "idempotent publish sends one POST")
        } catch {
            failures.append("GitHub publish fixture failed: \(error)")
        }

        if failures.isEmpty {
            print("maintainer self-test passed")
            return true
        }
        failures.forEach { fputs("maintainer self-test failed: \($0)\n", stderr) }
        return false
    }

    private static func fixtureTask(now: Date) -> MaintainerTask {
        MaintainerTask(
            id: MaintainerTask.stableID(repository: "o/r", kind: .issue, number: 1),
            repository: "o/r",
            number: 1,
            kind: .issue,
            title: "test",
            url: URL(string: "https://github.com/o/r/issues/1")!,
            author: "author",
            sourceUpdatedAt: now,
            revision: "rev-1",
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

private final class FakeCommandRunner: LocalCommandRunning {
    struct Fixture {
        let output: String
        let error: String
        let exitCode: Int32

        static func success(_ output: String) -> Fixture {
            Fixture(output: output, error: "", exitCode: 0)
        }
    }

    private var results: [Fixture]
    private(set) var postCount = 0

    init(results: [Fixture]) { self.results = results }

    func run(executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws -> LocalCommandResult {
        guard !results.isEmpty else { throw MaintainerError.commandFailed("missing fake command result") }
        if arguments.contains("POST") { postCount += 1 }
        let fixture = results.removeFirst()
        return LocalCommandResult(
            standardOutput: Data(fixture.output.utf8),
            standardError: fixture.error,
            exitCode: fixture.exitCode
        )
    }
}
