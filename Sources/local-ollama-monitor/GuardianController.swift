import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class GuardianController: ObservableObject {
    static let shared = GuardianController()

    @Published var config: GuardianConfig
    @Published var snapshot: GuardianSnapshot
    @Published var selectedSection: SidebarSection = .dashboard
    @Published var reloadHistory: [ReloadEvent] = []
    @Published var lastErrorMessage: String?
    @Published private(set) var ollamaCPUHistory: [MetricPoint] = []
    @Published private(set) var gpuHistory: [MetricPoint] = []

    private let settingsStore: SettingsStore
    private var logger: FileLogger
    private let backend: GuardianBackend
    private let stateCache: SharedStateCache
    private var metricsServer: LightweightHTTPServer?
    private var controlServer: LightweightHTTPServer?
    private var sampleTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var mutatingActionInFlight = false
    private var consecutiveHighCPUCount = 0

    init(settingsStore: SettingsStore = .shared) {
        self.settingsStore = settingsStore
        let loadedConfig = settingsStore.load()
        self.config = loadedConfig
        self.snapshot = .empty
        self.logger = FileLogger(path: loadedConfig.managedLogPath)
        self.backend = GuardianBackend(logger: logger)
        self.stateCache = SharedStateCache(config: loadedConfig, snapshot: .empty)

        snapshot.managedLogPath = config.managedLogPath
        stateCache.update(snapshot: snapshot)
        Task {
            await requestNotificationsIfNeeded()
            await bootstrap()
        }
    }

    var menuBarSymbolName: String {
        if snapshot.reloadInProgress { return "arrow.triangle.2.circlepath.circle.fill" }
        if snapshot.stuckState { return "exclamationmark.triangle.fill" }
        return snapshot.api.healthy ? "cpu.fill" : "cpu"
    }

    var statusLine: String {
        if snapshot.issue != nil {
            return "Action Needed"
        }
        if let reason = snapshot.lastReloadReason, snapshot.reloadInProgress {
            return "Reloading: \(reason)"
        }
        if snapshot.stuckState {
            return "Stuck detected"
        }
        return snapshot.api.healthy ? "Healthy" : "Unhealthy"
    }

    func bootstrap() async {
        do {
            try await startManagedServices()
        } catch {
            presentIssue(for: error, fallbackTitle: "Guardian Startup Failed")
        }
    }

    func saveSettings() {
        do {
            try config.validate()
            try settingsStore.save(config)
            snapshot.managedLogPath = config.managedLogPath
            reconfigureLoggingIfNeeded()
            stateCache.update(config: config, snapshot: snapshot)
            restartServers()
        } catch {
            presentIssue(for: error, fallbackTitle: "Failed To Save Settings")
        }
    }

    func generateNewBearerToken() {
        config.controlBearerToken = Self.makeBearerToken()
        stateCache.update(config: config)
    }

    func openLiveLogs() {
        let escapedPath = config.managedLogPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "printf '\\\\e]1;Ollama Guardian Logs\\\\a'; tail -n 120 -f \\"\(escapedPath)\\""
        end tell
        """

        Task.detached { [logger] in
            do {
                _ = try Shell.run("/usr/bin/osascript", arguments: ["-e", script])
            } catch {
                logger.write("open live logs failed: \(error.localizedDescription)")
                await MainActor.run {
                    GuardianController.shared.lastErrorMessage = "Failed to open live logs: \(error.localizedDescription)"
                }
            }
        }
    }

    func manualRestart() {
        runMutatingAction(name: "manual restart") { [weak self] in
            guard let self else { return }
            try await self.reloadOllama(trigger: .manual, message: "Manual restart requested")
        }
    }

    func warmModels() {
        runMutatingAction(name: "warm models") { [weak self] in
            guard let self else { return }
            let currentConfig = await MainActor.run { self.config }
            try await self.backend.warmConfiguredModels(config: currentConfig)
        }
    }

    func clearCooldown() {
        snapshot.cooldownUntil = nil
        stateCache.update(snapshot: snapshot)
    }

    func recentLogLines(limit: Int) -> String {
        let lines = max(1, min(limit, 500))
        guard let contents = try? String(contentsOfFile: config.managedLogPath, encoding: .utf8) else {
            return ""
        }
        let token = config.controlBearerToken
        return contents
            .split(whereSeparator: \.isNewline)
            .suffix(lines)
            .joined(separator: "\n")
            .replacingOccurrences(of: token, with: "<redacted>")
    }

    func prometheusMetrics() -> String {
        let current = stateCache.read().snapshot
        var lines: [String] = []
        lines.append("# HELP ollama_guardian_up Whether the guardian is running.")
        lines.append("# TYPE ollama_guardian_up gauge")
        lines.append("ollama_guardian_up 1")
        lines.append("# HELP ollama_guardian_system_cpu_percent System CPU percent.")
        lines.append("# TYPE ollama_guardian_system_cpu_percent gauge")
        lines.append("ollama_guardian_system_cpu_percent \(current.system.cpuPercent)")
        lines.append("# HELP ollama_guardian_system_gpu_percent Apple GPU device utilization percent.")
        lines.append("# TYPE ollama_guardian_system_gpu_percent gauge")
        lines.append("ollama_guardian_system_gpu_percent \(current.system.gpuPercent)")
        lines.append("# HELP ollama_guardian_system_load_1m System load average over 1 minute.")
        lines.append("# TYPE ollama_guardian_system_load_1m gauge")
        lines.append("ollama_guardian_system_load_1m \(current.system.loadAverage1m)")
        lines.append("# HELP ollama_guardian_system_memory_used_bytes System memory used.")
        lines.append("# TYPE ollama_guardian_system_memory_used_bytes gauge")
        lines.append("ollama_guardian_system_memory_used_bytes \(current.system.memoryUsedBytes)")
        lines.append("# HELP ollama_guardian_ollama_cpu_percent Ollama process CPU percent.")
        lines.append("# TYPE ollama_guardian_ollama_cpu_percent gauge")
        lines.append("ollama_guardian_ollama_cpu_percent \(current.process.cpuPercent)")
        lines.append("# HELP ollama_guardian_ollama_resident_memory_bytes Ollama process RSS.")
        lines.append("# TYPE ollama_guardian_ollama_resident_memory_bytes gauge")
        lines.append("ollama_guardian_ollama_resident_memory_bytes \(current.process.residentMemoryBytes)")
        lines.append("# HELP ollama_guardian_ollama_threads Ollama process thread count.")
        lines.append("# TYPE ollama_guardian_ollama_threads gauge")
        lines.append("ollama_guardian_ollama_threads \(current.process.threadCount)")
        lines.append("# HELP ollama_guardian_loaded_models Loaded Ollama models.")
        lines.append("# TYPE ollama_guardian_loaded_models gauge")
        lines.append("ollama_guardian_loaded_models \(current.loadedModelsCount)")
        lines.append("# HELP ollama_guardian_api_healthy Whether the Ollama API is healthy.")
        lines.append("# TYPE ollama_guardian_api_healthy gauge")
        lines.append("ollama_guardian_api_healthy \(current.api.healthy ? 1 : 0)")
        lines.append("# HELP ollama_guardian_last_inference_timestamp_seconds Last seen inference timestamp.")
        lines.append("# TYPE ollama_guardian_last_inference_timestamp_seconds gauge")
        lines.append("ollama_guardian_last_inference_timestamp_seconds \(Int(current.inference.lastInferenceTimestamp?.timeIntervalSince1970 ?? 0))")
        lines.append("# HELP ollama_guardian_last_reload_timestamp_seconds Last reload timestamp.")
        lines.append("# TYPE ollama_guardian_last_reload_timestamp_seconds gauge")
        lines.append("ollama_guardian_last_reload_timestamp_seconds \(Int(current.lastReloadTimestamp?.timeIntervalSince1970 ?? 0))")
        lines.append("# HELP ollama_guardian_reload_in_progress Whether a reload is active.")
        lines.append("# TYPE ollama_guardian_reload_in_progress gauge")
        lines.append("ollama_guardian_reload_in_progress \(current.reloadInProgress ? 1 : 0)")
        lines.append("# HELP ollama_guardian_stuck_state Whether the guardian considers Ollama stuck.")
        lines.append("# TYPE ollama_guardian_stuck_state gauge")
        lines.append("ollama_guardian_stuck_state \(current.stuckState ? 1 : 0)")
        lines.append("# HELP ollama_guardian_reload_total Total reload count.")
        lines.append("# TYPE ollama_guardian_reload_total counter")
        lines.append("ollama_guardian_reload_total \(current.reloadCount)")
        lines.append("# HELP ollama_guardian_health_failure_streak Consecutive failed health checks.")
        lines.append("# TYPE ollama_guardian_health_failure_streak gauge")
        lines.append("ollama_guardian_health_failure_streak \(current.api.healthFailureStreak)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func requestNotificationsIfNeeded() async {
        guard config.notificationsEnabled else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func startManagedServices() async throws {
        try config.validate()
        restartServers()
        startSamplingLoop()
        let currentConfig = config
        try await backend.startManagedProcess(config: currentConfig)
        let version = try await backend.waitForHealthyAPI(baseURL: currentConfig.resolvedOllamaBaseURL)
        snapshot.api.version = version
        snapshot.api.healthy = true
        snapshot.api.healthFailureStreak = 0
        if config.keepWarmEnabled {
            try await backend.warmConfiguredModels(config: currentConfig)
        }
        clearIssue(
            matchingTitles: [
                "Install Ollama First",
                "Log Directory Is Not Writable",
                "Log File Could Not Be Opened",
                "Ollama Exited Immediately",
                "Ollama API Did Not Come Up",
            ]
        )
        await refreshSnapshot()
    }

    private func restartServers() {
        metricsServer?.stop()
        controlServer?.stop()

        metricsServer = LightweightHTTPServer(host: config.metricsBindHost, port: UInt16(config.metricsPort), queueLabel: "ollama.guardian.metrics", logger: logger) { [weak self] request in
            guard let self else { return .text(status: "500 Internal Server Error", "missing controller\n") }
            if request.path == "/health" {
                return .text("ok\n")
            }
            if request.path == "/metrics" {
                return .text(contentType: "text/plain; version=0.0.4; charset=utf-8", self.prometheusMetrics())
            }
            return .text(status: "404 Not Found", "not found\n")
        }

        controlServer = LightweightHTTPServer(host: config.controlBindHost, port: UInt16(config.controlPort), queueLabel: "ollama.guardian.control", logger: logger) { [weak self] request in
            guard let self else { return .text(status: "500 Internal Server Error", "missing controller\n") }
            return self.handleControlRequest(request)
        }

        do {
            try metricsServer?.start()
        } catch {
            presentIssue(
                GuardianRuntimeError.listenerBindFailure(
                    service: "Metrics",
                    host: config.metricsBindHost,
                    port: config.metricsPort
                ).userIssue
            )
        }

        do {
            try controlServer?.start()
        } catch {
            presentIssue(
                GuardianRuntimeError.listenerBindFailure(
                    service: "Control API",
                    host: config.controlBindHost,
                    port: config.controlPort
                ).userIssue
            )
        }
    }

    private func startSamplingLoop() {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refreshSnapshot()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshSnapshot() async {
        let currentConfig = config
        let result = await backend.collectSample(config: currentConfig)

        snapshot.system = result.system
        snapshot.process = result.process
        appendMetricSamples(at: Date())

        if let version = result.version, let loadedModels = result.loadedModels {
            snapshot.api = APIState(healthy: true, loadedModels: loadedModels, healthFailureStreak: 0, version: version)
        } else {
            snapshot.api.healthy = false
            snapshot.api.healthFailureStreak += 1
        }

        if let timestamp = result.inference.lastInferenceTimestamp {
            snapshot.inference.lastInferenceTimestamp = timestamp
            snapshot.inference.lastInferenceEndpoint = result.inference.lastInferenceEndpoint
            snapshot.inference.degraded = false
        } else if result.inference.degraded {
            snapshot.inference.degraded = true
        }

        if snapshot.process.cpuPercent >= config.cpuThresholdPercent {
            consecutiveHighCPUCount += 1
        } else {
            consecutiveHighCPUCount = 0
        }

        let outcome = DetectionEngine.evaluate(
            DetectionInput(snapshot: snapshot, config: config, now: Date(), consecutiveHighCPUCount: consecutiveHighCPUCount)
        )
        snapshot.stuckState = outcome.stuck
        stateCache.update(snapshot: snapshot)

        if outcome.stuck, config.autoReloadEnabled {
            runMutatingAction(name: "auto reload") { [weak self] in
                guard let self else { return }
                try await self.reloadOllama(trigger: .stuck, message: outcome.reason ?? "Stuck state detected")
            }
        }

        if snapshot.api.healthy, snapshot.process.running, snapshot.issue?.title == "Ollama API Did Not Come Up" {
            clearIssue()
        }
    }

    private func reloadOllama(trigger: ReloadTrigger, message: String) async throws {
        snapshot.reloadInProgress = true
        stateCache.update(snapshot: snapshot)
        defer {
            snapshot.reloadInProgress = false
            stateCache.update(snapshot: snapshot)
        }

        logger.write("reload requested trigger=\(trigger.rawValue) message=\(message)")
        let currentConfig = config
        try await backend.stopManagedProcess(force: true)
        try await backend.startManagedProcess(config: currentConfig)
        let version = try await backend.waitForHealthyAPI(baseURL: currentConfig.resolvedOllamaBaseURL)
        snapshot.api.version = version
        snapshot.api.healthy = true
        snapshot.api.healthFailureStreak = 0
        if config.keepWarmEnabled {
            try await backend.warmConfiguredModels(config: currentConfig)
        }

        let event = ReloadEvent(trigger: trigger, message: message)
        reloadHistory.insert(event, at: 0)
        snapshot.lastReloadTimestamp = event.timestamp
        snapshot.lastReloadReason = message
        snapshot.reloadCount += 1
        snapshot.cooldownUntil = Date().addingTimeInterval(config.reloadCooldownSeconds)
        snapshot.stuckState = false
        clearIssue(
            matchingTitles: [
                "Install Ollama First",
                "Log Directory Is Not Writable",
                "Log File Could Not Be Opened",
                "Ollama Exited Immediately",
                "Ollama API Did Not Come Up",
            ]
        )
        stateCache.update(snapshot: snapshot)

        if config.notificationsEnabled, Bundle.main.bundleURL.pathExtension == "app" {
            sendNotification(title: "Ollama Guardian reloaded Ollama", body: message)
        }
    }

    private func runMutatingAction(name: String, operation: @escaping () async throws -> Void) {
        guard !mutatingActionInFlight else { return }
        mutatingActionInFlight = true
        stateCache.update(mutatingActionInFlight: true)
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                await refreshSnapshot()
            } catch {
                await MainActor.run {
                    self.presentIssue(for: error, fallbackTitle: "\(name.capitalized) Failed")
                }
            }
            self.mutatingActionInFlight = false
            self.stateCache.update(snapshot: self.snapshot, mutatingActionInFlight: false)
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func reconfigureLoggingIfNeeded() {
        guard logger.path != config.managedLogPath else { return }
        let newLogger = FileLogger(path: config.managedLogPath)
        logger = newLogger
        snapshot.managedLogPath = config.managedLogPath
        stateCache.update(snapshot: snapshot)
        Task {
            await backend.setLogger(newLogger)
        }
    }

    static func makeBearerToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func clearIssue(matchingTitles titles: [String]? = nil) {
        if let titles, let currentTitle = snapshot.issue?.title, !titles.contains(currentTitle) {
            return
        }
        snapshot.issue = nil
        lastErrorMessage = nil
        stateCache.update(snapshot: snapshot)
    }

    private func presentIssue(_ issue: UserFacingIssue) {
        snapshot.issue = issue
        lastErrorMessage = issue.summary
        logger.write("issue: \(issue.title) - \(issue.summary)")
        stateCache.update(snapshot: snapshot)
    }

    private func presentIssue(for error: Error, fallbackTitle: String) {
        if let runtimeError = error as? GuardianRuntimeError {
            presentIssue(runtimeError.userIssue)
            return
        }

        let issue = UserFacingIssue(
            title: fallbackTitle,
            summary: error.localizedDescription,
            recoverySteps: [
                "Open Live Logs in the app to inspect the latest runtime output.",
                "Check the Settings page for invalid ports, hosts, or file paths.",
                "Try the action again after correcting the underlying problem.",
            ]
        )
        presentIssue(issue)
    }

    private func appendMetricSamples(at timestamp: Date) {
        ollamaCPUHistory = appendedHistory(from: ollamaCPUHistory, value: snapshot.process.cpuPercent, timestamp: timestamp)
        gpuHistory = appendedHistory(from: gpuHistory, value: snapshot.system.gpuPercent, timestamp: timestamp)
    }

    private func appendedHistory(from history: [MetricPoint], value: Double, timestamp: Date) -> [MetricPoint] {
        var updated = history
        updated.append(MetricPoint(timestamp: timestamp, value: value))
        if updated.count > 72 {
            updated.removeFirst(updated.count - 72)
        }
        return updated
    }

    private func handleControlRequest(_ request: HTTPRequest) -> HTTPResponse {
        let current = stateCache.read()
        guard request.authorizationBearerToken == current.config.controlBearerToken else {
            return .json(status: "401 Unauthorized", StatusResponse(ok: false, message: "unauthorized", timestamp: Date(), snapshot: current.snapshot))
        }

        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return .json(StatusResponse(ok: true, message: "ok", timestamp: Date(), snapshot: current.snapshot))
        case ("POST", "/api/actions/restart"):
            if current.mutatingActionInFlight {
                return .json(status: "409 Conflict", StatusResponse(ok: false, message: "another action is already running", timestamp: Date(), snapshot: current.snapshot))
            }
            Task { @MainActor in self.manualRestart() }
            return .json(StatusResponse(ok: true, message: "restart queued", timestamp: Date(), snapshot: current.snapshot))
        case ("POST", "/api/actions/warm"):
            if current.mutatingActionInFlight {
                return .json(status: "409 Conflict", StatusResponse(ok: false, message: "another action is already running", timestamp: Date(), snapshot: current.snapshot))
            }
            Task { @MainActor in self.warmModels() }
            return .json(StatusResponse(ok: true, message: "warmup queued", timestamp: Date(), snapshot: current.snapshot))
        case ("POST", "/api/actions/clear-cooldown"):
            Task { @MainActor in self.clearCooldown() }
            return .json(StatusResponse(ok: true, message: "cooldown cleared", timestamp: Date(), snapshot: current.snapshot))
        case ("GET", "/api/logs/recent"):
            let lines = Int(request.query["lines"] ?? "50") ?? 50
            return .json([
                "ok": "true",
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "logs": recentLogLines(limit: lines),
            ])
        default:
            return .json(status: "404 Not Found", StatusResponse(ok: false, message: "not found", timestamp: Date(), snapshot: snapshot))
        }
    }
}
