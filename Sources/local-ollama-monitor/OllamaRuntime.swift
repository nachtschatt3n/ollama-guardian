import Foundation

struct OllamaPSResponse: Decodable {
    struct Model: Decodable {
        var name: String
    }

    var models: [Model]
}

struct OllamaVersionResponse: Decodable {
    var version: String
}

struct WarmGenerateRequest: Encodable {
    var model: String
    var prompt: String
    var stream: Bool
    var keep_alive: Int
}

struct WarmEmbedRequest: Encodable {
    var model: String
    var input: String
    var keep_alive: Int
}

struct SampleResult {
    var system: SystemMetrics
    var process: ProcessMetrics
    var version: String?
    var loadedModels: [String]?
    var inference: InferenceObservation
}

final class OllamaAPIClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func version(baseURL: URL) async -> String? {
        do {
            let (data, response) = try await session.data(from: baseURL.appending(path: "/api/version"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(OllamaVersionResponse.self, from: data).version
        } catch {
            return nil
        }
    }

    func loadedModels(baseURL: URL) async -> [String]? {
        do {
            let (data, response) = try await session.data(from: baseURL.appending(path: "/api/ps"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(OllamaPSResponse.self, from: data).models.map(\.name)
        } catch {
            return nil
        }
    }

    func warm(model: WarmModelConfig, config: GuardianConfig) async throws {
        let url: URL
        let body: Data

        switch model.endpointType {
        case .generate:
            url = config.resolvedOllamaBaseURL.appending(path: "/api/generate")
            body = try JSONEncoder().encode(
                WarmGenerateRequest(model: model.name, prompt: "ping", stream: false, keep_alive: config.keepAlive)
            )
        case .embed:
            url = config.resolvedOllamaBaseURL.appending(path: "/api/embed")
            body = try JSONEncoder().encode(
                WarmEmbedRequest(model: model.name, input: "ping", keep_alive: config.keepAlive)
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        _ = try await session.data(for: request)
    }
}

final class ManagedProcess: @unchecked Sendable {
    private(set) var process: Process?
    var logger: FileLogger

    init(logger: FileLogger) {
        self.logger = logger
    }

    var pid: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning == true }

    func start(config: GuardianConfig) throws {
        try stop(force: true)
        try ensureNoConflictingListener(on: config.ollamaPort)

        guard let ollamaPath = ExecutableLocator.findExecutable(
            named: "ollama",
            fallbackDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        ) else {
            throw GuardianRuntimeError.missingOllamaExecutable
        }

        let logDirectory = (config.managedLogPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        } catch {
            throw GuardianRuntimeError.failedToPrepareLogDirectory(path: logDirectory)
        }
        if !FileManager.default.fileExists(atPath: config.managedLogPath) {
            FileManager.default.createFile(atPath: config.managedLogPath, contents: nil)
        }

        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: config.managedLogPath))
        } catch {
            throw GuardianRuntimeError.failedToOpenLogFile(path: config.managedLogPath)
        }
        try outputHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_DEBUG"] = config.debugEnabled ? "1" : "0"
        environment["OLLAMA_HOST"] = "\(config.ollamaHost):\(config.ollamaPort)"
        environment["OLLAMA_CONTEXT_LENGTH"] = "\(config.contextLength)"
        environment["OLLAMA_NUM_PARALLEL"] = "\(config.numParallel)"
        environment["OLLAMA_MAX_QUEUE"] = "\(config.maxQueue)"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "\(config.maxLoadedModels)"
        environment["OLLAMA_KEEP_ALIVE"] = "\(config.keepAlive)"
        environment["OLLAMA_MODELS"] = config.modelsDirectory
        environment["OLLAMA_ORIGINS"] = config.allowedOrigins
        environment["OLLAMA_NO_CLOUD"] = config.noCloudEnabled ? "1" : "0"
        environment["OLLAMA_NOPRUNE"] = config.noPruneEnabled ? "1" : "0"
        environment["OLLAMA_SCHED_SPREAD"] = config.schedSpreadEnabled ? "1" : "0"
        environment["OLLAMA_FLASH_ATTENTION"] = config.flashAttentionEnabled ? "1" : "0"
        environment["OLLAMA_KV_CACHE_TYPE"] = config.kvCacheType
        environment["OLLAMA_LLM_LIBRARY"] = config.llmLibrary
        environment["OLLAMA_GPU_OVERHEAD"] = config.gpuOverheadBytes
        environment["OLLAMA_LOAD_TIMEOUT"] = config.loadTimeout
        environment["OLLAMA_MULTIUSER_CACHE"] = config.multiUserCacheEnabled ? "1" : "0"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let logger = self.logger
        process.terminationHandler = { proc in
            logger.write("ollama process exited with status \(proc.terminationStatus)")
        }

        try process.run()
        self.process = process
        logger.write("started managed ollama pid=\(process.processIdentifier)")

        Thread.sleep(forTimeInterval: 0.25)
        if !process.isRunning {
            self.process = nil
            throw GuardianRuntimeError.managedProcessExitedEarly(details: recentLogTail(from: config.managedLogPath))
        }
    }

    func stop(force: Bool = false) throws {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(force ? 3 : 8)
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
            logger.write("lsof not found; skipping conflict preflight for port \(port)")
            return
        }

        let output = try Shell.run(lsofPath, arguments: ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        for pid in pids where pid != self.pid {
            logger.write("terminating conflicting process pid=\(pid) on port \(port)")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.4)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func recentLogTail(from path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let tail = contents
            .split(whereSeparator: \.isNewline)
            .suffix(8)
            .joined(separator: " | ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}

struct SampleCollector {
    static func collectSystemMetrics() -> SystemMetrics {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let cpu = (try? Shell.run("/usr/bin/top", arguments: ["-l", "1", "-n", "0", "-stats", "cpu"])) ?? ""
        let gpu = (try? Shell.run("/usr/sbin/ioreg", arguments: ["-r", "-d", "1", "-c", "AGXAccelerator"])) ?? ""
        let memory = (try? Shell.run("/usr/bin/vm_stat")) ?? ""
        let loadAverage = loadAverage1m()
        return SystemMetrics(
            cpuPercent: parseCPUPercent(from: cpu),
            gpuPercent: parseGPUPercent(from: gpu),
            loadAverage1m: loadAverage,
            memoryUsedBytes: parseUsedMemory(from: memory, totalMemory: totalMemory),
            totalMemoryBytes: totalMemory
        )
    }

    static func collectProcessMetrics() -> ProcessMetrics {
        let output = (try? Shell.run("/bin/ps", arguments: ["-axo", "pid=,%cpu=,rss=,thcount=,comm="])) ?? ""
        let rows = output.split(whereSeparator: \.isNewline)
        for row in rows {
            let parts = row.split(maxSplits: 4, whereSeparator: \.isWhitespace).filter { !$0.isEmpty }
            guard parts.count >= 5 else { continue }
            let command = String(parts[4])
            guard command.contains("ollama") else { continue }
            return ProcessMetrics(
                pid: Int32(parts[0]),
                cpuPercent: Double(parts[1]) ?? 0,
                residentMemoryBytes: (UInt64(parts[2]) ?? 0) * 1024,
                threadCount: Int(parts[3]) ?? 0,
                running: true
            )
        }
        return .empty
    }

    private static func parseCPUPercent(from topOutput: String) -> Double {
        guard let line = topOutput.split(whereSeparator: \.isNewline).first(where: { $0.contains("CPU usage:") }) else { return 0 }
        let pattern = /CPU usage:\s+([0-9.]+)% user,\s+([0-9.]+)% sys,\s+([0-9.]+)% idle/

        guard let match = line.firstMatch(of: pattern) else {
            return 0
        }

        let user = Double(match.output.1) ?? 0
        let system = Double(match.output.2) ?? 0
        let idle = Double(match.output.3) ?? 0
        return max(0, min(100, user + system + max(0, 100 - (user + system + idle))))
    }

    private static func parseGPUPercent(from ioregOutput: String) -> Double {
        let pattern = /"Device Utilization %"\s*=\s*([0-9.]+)/
        guard let match = ioregOutput.firstMatch(of: pattern) else { return 0 }
        return max(0, min(100, Double(match.output.1) ?? 0))
    }

    private static func parseUsedMemory(from vmStatOutput: String, totalMemory: UInt64) -> UInt64 {
        let pageSizeLine = (try? Shell.run("/usr/sbin/sysctl", arguments: ["-n", "hw.pagesize"])) ?? "16384"
        let pageSize = UInt64(pageSizeLine.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16384
        var freePages: UInt64 = 0
        for line in vmStatOutput.split(whereSeparator: \.isNewline) {
            if line.contains("Pages free") {
                freePages = UInt64(line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            }
        }
        let freeBytes = freePages * pageSize
        return totalMemory > freeBytes ? totalMemory - freeBytes : 0
    }

    private static func loadAverage1m() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}

final class LogMonitor {
    private(set) var offset: UInt64 = 0
    private let interestingEndpoints = [
        "/api/chat",
        "/api/generate",
        "/api/embed",
        "/v1/chat/completions",
        "/v1/embeddings",
        "/v1/models",
    ]

    func scan(path: String) -> InferenceObservation {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: true)
        }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
                return InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: false)
            }

            var lastEndpoint: String?
            for line in chunk.split(whereSeparator: \.isNewline) {
                if let endpoint = Self.extractEndpoint(from: String(line), matches: interestingEndpoints) {
                    lastEndpoint = endpoint
                }
            }

            if let lastEndpoint {
                return InferenceObservation(lastInferenceTimestamp: Date(), lastInferenceEndpoint: lastEndpoint, degraded: false)
            }
            return InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: false)
        } catch {
            return InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: true)
        }
    }

    static func extractEndpoint(from line: String, matches endpoints: [String]) -> String? {
        endpoints.first(where: { line.contains($0) })
    }
}

actor GuardianBackend {
    private var logger: FileLogger
    private let processManager: ManagedProcess
    private let apiClient: OllamaAPIClient
    private let logMonitor: LogMonitor

    init(logger: FileLogger) {
        self.logger = logger
        self.processManager = ManagedProcess(logger: logger)
        self.apiClient = OllamaAPIClient()
        self.logMonitor = LogMonitor()
    }

    func setLogger(_ logger: FileLogger) {
        self.logger = logger
        processManager.logger = logger
    }

    func startManagedProcess(config: GuardianConfig) throws {
        try processManager.start(config: config)
    }

    func stopManagedProcess(force: Bool) throws {
        try processManager.stop(force: force)
    }

    func waitForHealthyAPI(baseURL: URL) async throws -> String {
        for _ in 0..<80 {
            if let version = await apiClient.version(baseURL: baseURL), !version.isEmpty {
                return version
            }
            if !processManager.isRunning {
                throw GuardianRuntimeError.managedProcessExitedEarly(details: nil)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GuardianRuntimeError.apiStartupTimeout(baseURL: baseURL.absoluteString)
    }

    func warmConfiguredModels(config: GuardianConfig) async throws {
        for model in config.warmModels {
            logger.write("warming model \(model.name) via \(model.endpointType.rawValue)")
            try await apiClient.warm(model: model, config: config)
        }
    }

    func collectSample(config: GuardianConfig) async -> SampleResult {
        async let version = apiClient.version(baseURL: config.resolvedOllamaBaseURL)
        async let loadedModels = apiClient.loadedModels(baseURL: config.resolvedOllamaBaseURL)
        let system = SampleCollector.collectSystemMetrics()
        let process = SampleCollector.collectProcessMetrics()
        let inference = logMonitor.scan(path: config.managedLogPath)

        return SampleResult(
            system: system,
            process: process,
            version: await version,
            loadedModels: await loadedModels,
            inference: inference
        )
    }
}

enum DetectionEngine {
    static func evaluate(_ input: DetectionInput) -> DetectionOutcome {
        let snapshot = input.snapshot

        if snapshot.reloadInProgress || snapshot.cooldownActive {
            return DetectionOutcome(stuck: false, reason: nil)
        }

        if snapshot.api.healthFailureStreak >= 3 {
            return DetectionOutcome(stuck: true, reason: "Repeated health-check failures")
        }

        if snapshot.process.residentMemoryBytes > UInt64(input.config.memoryThresholdMB * 1024 * 1024),
           snapshot.process.running {
            return DetectionOutcome(stuck: true, reason: "Resident memory above threshold")
        }

        guard snapshot.loadedModelsCount > 0 else {
            return DetectionOutcome(stuck: false, reason: nil)
        }

        guard !snapshot.inference.degraded else {
            return DetectionOutcome(stuck: false, reason: nil)
        }

        let lastInference = snapshot.inference.lastInferenceTimestamp ?? .distantPast
        let idleDuration = input.now.timeIntervalSince(lastInference)
        if idleDuration >= input.config.unhealthySeconds,
           snapshot.process.cpuPercent >= input.config.cpuThresholdPercent,
           input.consecutiveHighCPUCount >= 2 {
            return DetectionOutcome(stuck: true, reason: "High CPU with loaded models and no recent inference")
        }

        return DetectionOutcome(stuck: false, reason: nil)
    }
}
