import Foundation

enum ShellError: Error {
    case launchFailed(String)
}

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, arguments: [String] = [], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return output
    }
}

final class FileLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ollama.guardian.file-logger")
    let path: String

    init(path: String) {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let path = self.path
        queue.async {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

extension DateFormatter {
    static let guardianShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class SharedStateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var config: GuardianConfig
    private var snapshot: GuardianSnapshot
    private var mutatingActionInFlight: Bool

    init(config: GuardianConfig, snapshot: GuardianSnapshot, mutatingActionInFlight: Bool = false) {
        self.config = config
        self.snapshot = snapshot
        self.mutatingActionInFlight = mutatingActionInFlight
    }

    func update(config: GuardianConfig? = nil, snapshot: GuardianSnapshot? = nil, mutatingActionInFlight: Bool? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let config { self.config = config }
        if let snapshot { self.snapshot = snapshot }
        if let mutatingActionInFlight { self.mutatingActionInFlight = mutatingActionInFlight }
    }

    func read() -> (config: GuardianConfig, snapshot: GuardianSnapshot, mutatingActionInFlight: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (config, snapshot, mutatingActionInFlight)
    }
}
