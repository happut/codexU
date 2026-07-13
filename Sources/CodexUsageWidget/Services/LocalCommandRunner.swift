import Foundation

struct LocalCommandResult {
    let standardOutput: Data
    let standardError: String
    let exitCode: Int32
}

private final class CommandOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

protocol LocalCommandRunning {
    func run(executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws -> LocalCommandResult
}

struct LocalCommandRunner: LocalCommandRunning {
    func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 60) throws -> LocalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = output
        process.standardError = error
        if input != nil { process.standardInput = inputPipe }

        do {
            try process.run()
        } catch {
            throw MaintainerError.commandFailed("无法启动 \(executable)：\(error.localizedDescription)")
        }

        if let input {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }

        let readGroup = DispatchGroup()
        let outputBox = CommandOutputBox()
        let errorBox = CommandOutputBox()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.set(output.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.set(error.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            readGroup.wait()
            throw MaintainerError.commandFailed("命令执行超时：\(arguments.first ?? executable)")
        }

        readGroup.wait()
        let stdout = outputBox.get()
        let stderrData = errorBox.get()
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LocalCommandResult(standardOutput: stdout, standardError: stderr, exitCode: process.terminationStatus)
    }
}

enum MaintainerExecutableResolver {
    static func resolve(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/Applications/ChatGPT.app/Contents/Resources/\(name)",
            "/Applications/Codex.app/Contents/Resources/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
