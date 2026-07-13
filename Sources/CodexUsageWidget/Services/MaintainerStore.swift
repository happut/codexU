import Cocoa
import Combine
import Foundation
import UserNotifications

@MainActor
final class MaintainerStore: ObservableObject {
    @Published private(set) var tasks: [MaintainerTask]
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var statusMessage: String?
    @Published var configuration: MaintainerConfiguration

    private let repository: MaintainerTaskRepository
    private let github: GitHubMaintainerClient
    private let reviewer: CodexReviewRunner
    private let worker = DispatchQueue(label: "com.codexu.maintainer", qos: .utility)
    private var timer: Timer?
    private var processingTaskID: String?

    init(
        repository: MaintainerTaskRepository = MaintainerTaskRepository(),
        github: GitHubMaintainerClient = GitHubMaintainerClient(),
        reviewer: CodexReviewRunner = CodexReviewRunner(),
        configuration: MaintainerConfiguration? = nil
    ) {
        self.repository = repository
        self.github = github
        self.reviewer = reviewer
        self.configuration = configuration ?? MaintainerConfigurationStore.load()
        tasks = repository.load().sorted { $0.updatedAt > $1.updatedAt }
    }

    var awaitingApprovalCount: Int { tasks.filter { $0.status == .awaitingApproval }.count }
    var activeCount: Int { tasks.filter { $0.status.isBusy || $0.status == .discovered }.count }

    func start() {
        requestNotificationPermission()
        rescheduleTimer()
        if configuration.enabled { scanNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func saveConfiguration() {
        configuration.repository = configuration.normalizedRepository
        configuration.localRepositoryPath = configuration.normalizedPath
        configuration.pollIntervalSeconds = max(30, min(3600, configuration.pollIntervalSeconds))
        MaintainerConfigurationStore.save(configuration)
        rescheduleTimer()
        statusMessage = configuration.isValid ? "维护机器人配置已保存" : "请填写有效的 owner/repo 和本地仓库目录"
        if configuration.enabled, configuration.isValid { scanNow() }
    }

    func scanNow() {
        guard !isSyncing else { return }
        guard configuration.isValid else {
            statusMessage = "请先配置 GitHub 仓库和本地仓库目录"
            return
        }
        isSyncing = true
        statusMessage = "正在读取 GitHub…"
        let config = configuration
        let github = github
        worker.async { [weak self] in
            guard let self else { return }
            do {
                let discovered = try github.discover(repository: config.normalizedRepository, label: config.triggerLabel)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.merge(discovered)
                    self.isSyncing = false
                    self.lastSyncAt = Date()
                    self.statusMessage = discovered.isEmpty ? "没有匹配 \(config.triggerLabel) 的开放 Issue/PR" : "已同步 \(discovered.count) 个对象"
                    self.processNextDiscoveredTask()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isSyncing = false
                    self?.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func reviewAgain(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), !tasks[index].status.isBusy else { return }
        tasks[index].status = .discovered
        tasks[index].review = nil
        tasks[index].errorMessage = nil
        tasks[index].publishedCommentURL = nil
        tasks[index].updatedAt = Date()
        persist()
        processNextDiscoveredTask()
    }

    func approveAndPublish(taskID: String) {
        guard processingTaskID == nil, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        do { try tasks[index].beginPublishing() } catch {
            statusMessage = error.localizedDescription
            return
        }
        processingTaskID = taskID
        persist()
        let task = tasks[index]
        let github = github
        worker.async { [weak self] in
            guard let self, let review = task.review else { return }
            do {
                let commentURL = try github.publish(review: review, for: task)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let currentIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                        try? self.tasks[currentIndex].completePublishing(commentURL: commentURL)
                    }
                    self.processingTaskID = nil
                    self.statusMessage = "审查意见已发布到 GitHub"
                    self.persist()
                    self.notify(title: "GitHub 审查已发布", body: "\(task.kind.displayName) #\(task.number) · \(task.title)")
                    self.processNextDiscoveredTask()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let currentIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                        self.tasks[currentIndex].fail(error.localizedDescription)
                    }
                    self.processingTaskID = nil
                    self.statusMessage = error.localizedDescription
                    self.persist()
                }
            }
        }
    }

    func ignore(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), !tasks[index].status.isBusy else { return }
        tasks[index].status = .ignored
        tasks[index].updatedAt = Date()
        persist()
    }

    func openGitHub(_ task: MaintainerTask) { NSWorkspace.shared.open(task.url) }

    func openPublishedComment(_ task: MaintainerTask) {
        if let url = task.publishedCommentURL { NSWorkspace.shared.open(url) }
    }

    func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func merge(_ items: [GitHubMaintainerItem]) {
        for item in items {
            let id = MaintainerTask.stableID(repository: item.repository, kind: item.kind, number: item.number)
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].title = item.title
                tasks[index].author = item.author
                tasks[index].sourceUpdatedAt = item.updatedAt
                // Issue revisions fingerprint title/body; PR revisions use head SHA. Comments never retrigger a review.
                if tasks[index].revision != item.revision {
                    tasks[index].revision = item.revision
                    if !tasks[index].status.isBusy {
                        tasks[index].status = .discovered
                        tasks[index].review = nil
                        tasks[index].publishedCommentURL = nil
                        tasks[index].errorMessage = nil
                        tasks[index].updatedAt = Date()
                    }
                }
            } else {
                tasks.append(item.makeTask())
            }
        }
        tasks.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    private func processNextDiscoveredTask() {
        guard processingTaskID == nil,
              let index = tasks.firstIndex(where: { $0.status == .discovered }) else { return }
        let taskID = tasks[index].id
        do { try tasks[index].beginReview() } catch { return }
        processingTaskID = taskID
        persist()
        let task = tasks[index]
        let config = configuration
        let github = github
        let reviewer = reviewer
        statusMessage = "Codex 正在审查 \(task.kind.displayName) #\(task.number)…"

        worker.async { [weak self] in
            guard let self else { return }
            do {
                let context = try github.reviewContext(for: task)
                let result = try reviewer.review(
                    context: context,
                    localRepositoryPath: config.normalizedPath,
                    existingThreadID: task.codexThreadID
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let currentIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                        if self.tasks[currentIndex].revision == task.revision {
                            try? self.tasks[currentIndex].completeReview(result.review, threadID: result.threadID)
                        } else {
                            self.tasks[currentIndex].status = .discovered
                            self.tasks[currentIndex].review = nil
                            self.tasks[currentIndex].errorMessage = nil
                            self.tasks[currentIndex].updatedAt = Date()
                        }
                    }
                    self.processingTaskID = nil
                    self.statusMessage = "审查完成，等待你的批准"
                    self.persist()
                    self.notify(title: "Codex 审查完成", body: "\(task.kind.displayName) #\(task.number) 等待批准")
                    self.processNextDiscoveredTask()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let currentIndex = self.tasks.firstIndex(where: { $0.id == taskID }) {
                        self.tasks[currentIndex].fail(error.localizedDescription)
                    }
                    self.processingTaskID = nil
                    self.statusMessage = error.localizedDescription
                    self.persist()
                    self.processNextDiscoveredTask()
                }
            }
        }
    }

    private func persist() {
        do { try repository.save(tasks) } catch { statusMessage = "保存维护任务失败：\(error.localizedDescription)" }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard configuration.enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(30, configuration.pollIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanNow() }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
