import Foundation

struct OllamaPSResponse: Decodable {
    struct Model: Decodable {
        var name: String
    }

    var models: [Model]
}

struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        var name: String
        var digest: String?
    }

    var models: [Model]
}

struct OllamaVersionResponse: Decodable {
    var version: String
}

struct GitHubRelease: Decodable {
    var tag_name: String
    var published_at: Date
    var html_url: String
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
    var requestRate: RequestRateSnapshot
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

    func installedModelsWithDigests(baseURL: URL) async -> [(name: String, digest: String)]? {
        do {
            let (data, response) = try await session.data(from: baseURL.appending(path: "/api/tags"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return decoded.models.compactMap { model in
                guard let digest = model.digest, !digest.isEmpty else { return nil }
                return (name: model.name, digest: digest)
            }
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

actor OllamaReleaseChecker {
    private let session: URLSession
    private let userAgent: String

    init(session: URLSession = .shared, userAgent: String = "ollama-guardian") {
        self.session = session
        self.userAgent = userAgent
    }

    func latestRelease() async -> OllamaReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)
            guard let htmlURL = URL(string: release.html_url) else { return nil }
            return OllamaReleaseInfo(
                latestTag: release.tag_name,
                publishedAt: release.published_at,
                htmlURL: htmlURL,
                fetchedAt: Date()
            )
        } catch {
            return nil
        }
    }
}

actor OllamaRegistryClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func remoteManifestDigest(model: String) async -> String? {
        let (namespace, name, tag) = Self.parse(model: model)
        guard let url = URL(string: "https://registry.ollama.ai/v2/\(namespace)/\(name)/manifests/\(tag)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let preferredHeaders: Set<String> = ["docker-content-digest", "ollama-content-digest"]
            for (key, value) in http.allHeaderFields {
                guard let keyString = key as? String else { continue }
                if preferredHeaders.contains(keyString.lowercased()),
                   let digestString = value as? String,
                   !digestString.isEmpty {
                    return Self.normalizeDigest(digestString)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    static func parse(model: String) -> (namespace: String, name: String, tag: String) {
        let (path, tag): (String, String) = {
            if let colon = model.lastIndex(of: ":") {
                return (String(model[..<colon]), String(model[model.index(after: colon)...]))
            }
            return (model, "latest")
        }()

        if let slash = path.firstIndex(of: "/") {
            return (String(path[..<slash]), String(path[path.index(after: slash)...]), tag)
        }
        return ("library", path, tag)
    }

    static func normalizeDigest(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
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
        // macOS 26 dropped the `thcount` ps keyword; the old args returned exit 1 and 4-column
        // rows, which the parser rejected — silently zeroing cpu/rss and disabling stuck detection.
        let output = (try? Shell.run("/bin/ps", arguments: ["-axo", "pid=,%cpu=,rss=,comm="])) ?? ""
        let rows = output.split(whereSeparator: \.isNewline)
        for row in rows {
            let parts = row.split(maxSplits: 3, whereSeparator: \.isWhitespace).filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }
            let command = String(parts[3])
            guard command.contains("ollama") else { continue }
            return ProcessMetrics(
                pid: Int32(parts[0]),
                cpuPercent: Double(parts[1]) ?? 0,
                residentMemoryBytes: (UInt64(parts[2]) ?? 0) * 1024,
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

struct LogScanResult {
    var inference: InferenceObservation
    var requestRate: RequestRateSnapshot
}

struct CompletedRequest: Equatable {
    var endTime: Date
    var latency: TimeInterval
    var endpoint: String
    var startTime: Date { endTime.addingTimeInterval(-latency) }
}

final class LogMonitor {
    private(set) var offset: UInt64 = 0
    private var recentRequests: [CompletedRequest] = []
    private static let bufferLimit = 400
    private static let windowSeconds: TimeInterval = 60
    private let interestingEndpoints = [
        "/api/chat",
        "/api/generate",
        "/api/embed",
        "/v1/chat/completions",
        "/v1/embeddings",
        "/v1/models",
    ]

    func scan(path: String, parallelLimit: Int, now: Date = Date()) -> LogScanResult {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return LogScanResult(
                inference: InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: true),
                requestRate: summarize(parallelLimit: parallelLimit, now: now)
            )
        }

        var degraded = false
        var newEndpoint: String?

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                for line in chunk.split(whereSeparator: \.isNewline) {
                    let lineString = String(line)
                    if let completion = Self.parseGinCompletion(line: lineString, now: now) {
                        recentRequests.append(completion)
                        newEndpoint = completion.endpoint
                    } else if let endpoint = Self.extractEndpoint(from: lineString, matches: interestingEndpoints) {
                        newEndpoint = endpoint
                    }
                }
            }
        } catch {
            degraded = true
        }

        pruneOldRequests(now: now)

        let inference: InferenceObservation
        if let endpoint = newEndpoint {
            inference = InferenceObservation(lastInferenceTimestamp: now, lastInferenceEndpoint: endpoint, degraded: false)
        } else {
            inference = InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: degraded)
        }

        return LogScanResult(
            inference: inference,
            requestRate: summarize(parallelLimit: parallelLimit, now: now)
        )
    }

    private func pruneOldRequests(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        recentRequests.removeAll { $0.endTime < cutoff }
        if recentRequests.count > Self.bufferLimit {
            recentRequests.removeFirst(recentRequests.count - Self.bufferLimit)
        }
    }

    private func summarize(parallelLimit: Int, now: Date) -> RequestRateSnapshot {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        let window = recentRequests.filter { $0.endTime >= cutoff }
        let rpm = window.count

        var byEndpoint: [String: Int] = [:]
        for req in window {
            byEndpoint[req.endpoint, default: 0] += 1
        }

        let peakConcurrency = Self.maxOverlap(requests: window)
        let currentInflight = window.filter { $0.startTime <= now && $0.endTime >= now }.count

        return RequestRateSnapshot(
            requestsPerMinute: rpm,
            peakConcurrencyLastMinute: peakConcurrency,
            currentInflightEstimate: currentInflight,
            parallelLimit: max(0, parallelLimit),
            perEndpointLastMinute: byEndpoint
        )
    }

    static func maxOverlap(requests: [CompletedRequest]) -> Int {
        guard !requests.isEmpty else { return 0 }
        var events: [(time: Date, delta: Int)] = []
        events.reserveCapacity(requests.count * 2)
        for req in requests {
            events.append((req.startTime, 1))
            events.append((req.endTime, -1))
        }
        events.sort { a, b in
            if a.time == b.time { return a.delta > b.delta }
            return a.time < b.time
        }
        var current = 0
        var peak = 0
        for event in events {
            current += event.delta
            if current > peak { peak = current }
        }
        return peak
    }

    static func extractEndpoint(from line: String, matches endpoints: [String]) -> String? {
        endpoints.first(where: { line.contains($0) })
    }

    static func parseGinCompletion(line: String, now: Date) -> CompletedRequest? {
        guard line.contains("[GIN]") else { return nil }
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5 else { return nil }

        let statusField = parts[1]
        guard Int(statusField) != nil else { return nil }

        let latencyField = parts[2]
        guard let latency = parseLatency(latencyField) else { return nil }

        let methodPath = parts[4]
        guard let endpoint = extractPath(from: methodPath) else { return nil }

        return CompletedRequest(endTime: now, latency: latency, endpoint: endpoint)
    }

    static func parseLatency(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let suffixes: [(String, Double)] = [
            ("µs", 1e-6),
            ("us", 1e-6),
            ("ms", 1e-3),
            ("s", 1.0),
        ]
        for (suffix, multiplier) in suffixes where trimmed.hasSuffix(suffix) {
            let valuePart = trimmed.dropLast(suffix.count)
            if let value = Double(valuePart) {
                return value * multiplier
            }
        }
        return nil
    }

    static func extractPath(from methodPath: String) -> String? {
        if let firstQuote = methodPath.firstIndex(of: "\""),
           let closing = methodPath[methodPath.index(after: firstQuote)...].firstIndex(of: "\"") {
            return String(methodPath[methodPath.index(after: firstQuote)..<closing])
        }
        let tokens = methodPath.split(whereSeparator: \.isWhitespace)
        return tokens.last.map(String.init)
    }
}

actor GuardianBackend {
    private var logger: FileLogger
    private let processManager: ManagedProcess
    private let apiClient: OllamaAPIClient
    private let logMonitor: LogMonitor
    private let releaseChecker: OllamaReleaseChecker
    private let registryClient: OllamaRegistryClient

    init(logger: FileLogger) {
        self.logger = logger
        self.processManager = ManagedProcess(logger: logger)
        self.apiClient = OllamaAPIClient()
        self.logMonitor = LogMonitor()
        self.releaseChecker = OllamaReleaseChecker()
        self.registryClient = OllamaRegistryClient()
    }

    func fetchLatestRelease() async -> OllamaReleaseInfo? {
        await releaseChecker.latestRelease()
    }

    func fetchRemoteDigest(model: String) async -> String? {
        await registryClient.remoteManifestDigest(model: model)
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
        async let versionTask = apiClient.version(baseURL: config.resolvedOllamaBaseURL)
        async let loadedModelsTask = apiClient.loadedModels(baseURL: config.resolvedOllamaBaseURL)
        let system = SampleCollector.collectSystemMetrics()
        let process = SampleCollector.collectProcessMetrics()
        let version = await versionTask
        let loadedModels = await loadedModelsTask
        let parallelLimit = max(1, (loadedModels?.count ?? 0)) * max(1, config.numParallel)
        let scan = logMonitor.scan(path: config.managedLogPath, parallelLimit: parallelLimit)

        return SampleResult(
            system: system,
            process: process,
            version: version,
            loadedModels: loadedModels,
            inference: scan.inference,
            requestRate: scan.requestRate
        )
    }

    func fetchInstalledDigests(config: GuardianConfig) async -> [(name: String, digest: String)] {
        await apiClient.installedModelsWithDigests(baseURL: config.resolvedOllamaBaseURL) ?? []
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
