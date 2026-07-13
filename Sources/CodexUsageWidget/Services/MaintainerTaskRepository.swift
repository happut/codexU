import Foundation

final class MaintainerTaskRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("codexU", isDirectory: true)
                .appendingPathComponent("maintainer-tasks.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [MaintainerTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([MaintainerTask].self, from: data)) ?? []
    }

    func save(_ tasks: [MaintainerTask]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(tasks)
        try data.write(to: fileURL, options: .atomic)
    }
}
