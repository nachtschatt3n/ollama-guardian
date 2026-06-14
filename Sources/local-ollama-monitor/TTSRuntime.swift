import Foundation

/// Supervises the local mlx-audio Qwen3-TTS fallback server (an OpenAI-compatible
/// `/v1/audio/speech` endpoint) as a Guardian-managed child process — mirroring how
/// `ManagedProcess` supervises `ollama serve`.
final class TTSManagedProcess: @unchecked Sendable {
    private(set) var process: Process?
    var logger: FileLogger

    init(logger: FileLogger) {
        self.logger = logger
    }

    var pid: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning == true }

    func start(config: TTSConfig) throws {
        try stop(force: true)
        try ensureNoConflictingListener(on: config.port)

        guard FileManager.default.isExecutableFile(atPath: config.pythonPath) else {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "TTS Python Not Found",
                summary: "The TTS server interpreter at \(config.pythonPath) is missing or not executable.",
                recovery: [
                    "Create the venv: python3 -m venv \(config.workingDirectory)/venv",
                    "Install mlx-audio into it, then verify the path in Settings.",
                ]
            )
        }

        let serverScript = "\(config.workingDirectory)/tts_server.py"
        guard FileManager.default.fileExists(atPath: serverScript) else {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "TTS Server Script Missing",
                summary: "tts_server.py was not found in \(config.workingDirectory).",
                recovery: ["Restore tts_server.py to the TTS working directory."]
            )
        }

        let logDirectory = (config.managedLogPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: config.managedLogPath) {
            FileManager.default.createFile(atPath: config.managedLogPath, contents: nil)
        }
        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: config.managedLogPath))
        try outputHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.pythonPath)
        process.arguments = ["-m", "uvicorn", "tts_server:app", "--host", config.bindHost, "--port", "\(config.port)"]
        process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["TTS_MODEL"] = config.model
        environment["TTS_SEED"] = "\(config.seed)"
        environment["TTS_LANG"] = config.language
        environment["TTS_INSTRUCT"] = config.instruct
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let logger = self.logger
        process.terminationHandler = { proc in
            logger.write("tts server exited with status \(proc.terminationStatus)")
        }

        try process.run()
        self.process = process
        logger.write("started managed tts server pid=\(process.processIdentifier) port=\(config.port)")

        Thread.sleep(forTimeInterval: 0.25)
        if !process.isRunning {
            self.process = nil
            throw GuardianRuntimeError.invalidConfiguration(
                title: "TTS Server Exited Immediately",
                summary: "The TTS server process stopped right after launch. Check the TTS log.",
                recovery: ["Open the TTS log at \(config.managedLogPath) to inspect the error."]
            )
        }
    }

    func stop(force: Bool = false) throws {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(force ? 3 : 6)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
    }

    private func ensureNoConflictingListener(on port: Int) throws {
        guard let lsofPath = ExecutableLocator.findExecutable(named: "lsof", fallbackDirectories: ["/usr/sbin", "/usr/bin"]) else {
            return
        }
        let output = (try? Shell.run(lsofPath, arguments: ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])) ?? ""
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for pid in pids where pid != self.pid {
            logger.write("terminating conflicting process pid=\(pid) on tts port \(port)")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.4)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}

struct TTSHealthResult {
    var healthy: Bool
    var detail: String?
}

final class TTSClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func health(config: TTSConfig) async -> TTSHealthResult {
        var request = URLRequest(url: config.healthURL)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return TTSHealthResult(healthy: false, detail: "no response")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 200, body.contains("\"ok\"") {
                return TTSHealthResult(healthy: true, detail: nil)
            }
            if body.contains("loading") {
                return TTSHealthResult(healthy: false, detail: "loading")
            }
            return TTSHealthResult(healthy: false, detail: "status \(http.statusCode)")
        } catch {
            return TTSHealthResult(healthy: false, detail: error.localizedDescription)
        }
    }
}
