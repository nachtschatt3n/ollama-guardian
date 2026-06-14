import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class GuardianController: ObservableObject {
    static let shared = GuardianController()

    @Published var config: GuardianConfig
    @Published private(set) var savedConfig: GuardianConfig
    @Published private(set) var appliedRuntimeConfig: GuardianConfig
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
    private var updateCheckTask: Task<Void, Never>?
    private var mutatingActionInFlight = false
    private var consecutiveHighCPUCount = 0
    private var ttsHealthFailureStreak = 0
    private var ttsRestartInFlight = false
    private var lastTTSRestart: Date?
    private var lastTTSStart: Date?
    private static let ttsStartupGraceSeconds: TimeInterval = 45

    private static let releaseInfoDefaultsKey = "com.ollamaguardian.latestRelease"
    private static let modelUpdatesDefaultsKey = "com.ollamaguardian.modelUpdates"
    private static let updateCheckInterval: TimeInterval = 60 * 60 * 24

    init(settingsStore: SettingsStore = .shared) {
        self.settingsStore = settingsStore
        let loadedConfig = settingsStore.load()
        self.config = loadedConfig
        self.savedConfig = loadedConfig
        self.appliedRuntimeConfig = loadedConfig
        self.snapshot = .empty
        self.logger = FileLogger(path: loadedConfig.managedLogPath)
        self.backend = GuardianBackend(logger: logger)
        self.stateCache = SharedStateCache(config: loadedConfig, snapshot: .empty)

        snapshot.managedLogPath = config.managedLogPath
        rehydrateUpdateCaches()
        stateCache.update(snapshot: snapshot)
        Task {
            await requestNotificationsIfNeeded()
            await bootstrap()
            await maybeRunUpdateChecks()
            startUpdateCheckLoop()
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

    var hasPendingRuntimeChanges: Bool {
        savedConfig.runtimeSettings != appliedRuntimeConfig.runtimeSettings
    }

    var metricsEndpoint: String {
        "http://\(savedConfig.metricsBindHost):\(savedConfig.metricsPort)/metrics"
    }

    var controlStatusEndpoint: String {
        "http://\(savedConfig.controlBindHost):\(savedConfig.controlPort)/api/status"
    }

    var activeWarmModelSummary: String {
        appliedRuntimeConfig.warmModels.map(\.name).joined(separator: ", ")
    }

    func bootstrap() async {
        do {
            try await startManagedServices()
        } catch {
            presentIssue(for: error, fallbackTitle: "Guardian Startup Failed")
        }
        // TTS fallback server is supervised independently of Ollama: start it even
        // if Ollama bootstrap failed, and let the sampling loop keep it healthy.
        await startTTSIfEnabled()
    }

    func restartTTS() {
        Task { [weak self] in
            guard let self else { return }
            await self.startTTSIfEnabled(forceRestart: true)
        }
    }

    private func startTTSIfEnabled(forceRestart: Bool = false) async {
        let cfg = savedConfig.tts
        snapshot.tts.enabled = cfg.enabled
        snapshot.tts.port = cfg.port
        snapshot.tts.endpoint = cfg.speechEndpoint
        snapshot.tts.model = cfg.model

        guard cfg.enabled else {
            if await backend.ttsRunning { try? await backend.stopTTS(force: true) }
            snapshot.tts.running = false
            snapshot.tts.healthy = false
            snapshot.tts.pid = nil
            stateCache.update(snapshot: snapshot)
            return
        }
        if await backend.ttsRunning, !forceRestart {
            stateCache.update(snapshot: snapshot)
            return
        }
        do {
            try await backend.startTTS(config: cfg)
            lastTTSStart = Date()
            ttsHealthFailureStreak = 0
            snapshot.tts.running = await backend.ttsRunning
            snapshot.tts.pid = await backend.ttsPid
            snapshot.tts.lastError = nil
            if forceRestart { snapshot.tts.restartCount += 1 }
        } catch {
            snapshot.tts.running = false
            snapshot.tts.healthy = false
            snapshot.tts.lastError = (error as? GuardianRuntimeError)?.userIssue.summary ?? error.localizedDescription
            logger.write("tts start failed: \(snapshot.tts.lastError ?? "unknown")")
        }
        stateCache.update(snapshot: snapshot)
    }

    private func refreshTTS() async {
        let cfg = savedConfig.tts
        snapshot.tts.enabled = cfg.enabled
        snapshot.tts.port = cfg.port
        snapshot.tts.endpoint = cfg.speechEndpoint
        snapshot.tts.model = cfg.model

        guard cfg.enabled else {
            if await backend.ttsRunning { try? await backend.stopTTS(force: true) }
            snapshot.tts.running = false
            snapshot.tts.healthy = false
            snapshot.tts.pid = nil
            ttsHealthFailureStreak = 0
            stateCache.update(snapshot: snapshot)
            return
        }

        let running = await backend.ttsRunning
        snapshot.tts.running = running
        snapshot.tts.pid = await backend.ttsPid

        var loading = false
        if running {
            let health = await backend.ttsHealth(config: cfg)
            snapshot.tts.healthy = health.healthy
            if health.healthy {
                snapshot.tts.lastError = nil
            } else {
                snapshot.tts.lastError = health.detail
                loading = (health.detail == "loading")
            }
        } else {
            snapshot.tts.healthy = false
        }

        // Restart only on a real crash, or sustained unhealthy *after* the startup
        // grace window (the server needs a few seconds to bind + load the model, during
        // which connection failures / "loading" are expected and must not trigger a restart).
        let inGrace = lastTTSStart.map { Date().timeIntervalSince($0) < Self.ttsStartupGraceSeconds } ?? false
        let crashed = !running
        let unhealthyBeyondGrace = running && !snapshot.tts.healthy && !loading && !inGrace
        let needsRestart = crashed || unhealthyBeyondGrace
        ttsHealthFailureStreak = needsRestart ? ttsHealthFailureStreak + 1 : 0
        let cooldownOK = lastTTSRestart.map { Date().timeIntervalSince($0) > 30 } ?? true
        if ttsHealthFailureStreak >= 2, cooldownOK, !ttsRestartInFlight {
            ttsRestartInFlight = true
            lastTTSRestart = Date()
            snapshot.tts.restartCount += 1
            logger.write("auto-restarting tts (streak=\(ttsHealthFailureStreak) detail=\(snapshot.tts.lastError ?? "n/a"))")
            do {
                try await backend.startTTS(config: cfg)
                lastTTSStart = Date()
                snapshot.tts.lastError = nil
            } catch {
                snapshot.tts.lastError = (error as? GuardianRuntimeError)?.userIssue.summary ?? error.localizedDescription
            }
            ttsHealthFailureStreak = 0
            ttsRestartInFlight = false
        }
        stateCache.update(snapshot: snapshot)
    }

    func saveSettings() {
        do {
            try config.validate()
            let previousTTS = savedConfig.tts
            let newSavedConfig = config
            try settingsStore.save(newSavedConfig)
            savedConfig = newSavedConfig
            stateCache.update(config: savedConfig, snapshot: snapshot)
            restartServers()

            // TTS launch parameters (model/seed/voice/paths/port) only take effect on a
            // process restart; apply them when the TTS config changed.
            if newSavedConfig.tts != previousTTS {
                restartTTS()
            }

            if hasPendingRuntimeChanges, promptToRestartForSavedSettings() {
                runMutatingAction(name: "apply saved settings") { [weak self] in
                    guard let self else { return }
                    try await self.reloadOllama(trigger: .manual, message: "Applying saved settings")
                }
            }
        } catch {
            presentIssue(for: error, fallbackTitle: "Failed To Save Settings")
        }
    }

    func generateNewBearerToken() {
        config.controlBearerToken = Self.makeBearerToken()
        stateCache.update(config: config)
    }

    func openLiveLogs() {
        let escapedPath = appliedRuntimeConfig.managedLogPath.replacingOccurrences(of: "\"", with: "\\\"")
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
            let currentConfig = await MainActor.run { self.appliedRuntimeConfig }
            try await self.backend.warmConfiguredModels(config: currentConfig)
        }
    }

    func clearCooldown() {
        snapshot.cooldownUntil = nil
        stateCache.update(snapshot: snapshot)
    }

    func checkForUpdatesNow() {
        Task { await runUpdateChecks(force: true) }
    }

    private func startUpdateCheckLoop() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60 * 6))
                guard let self else { return }
                await self.maybeRunUpdateChecks()
            }
        }
    }

    private func maybeRunUpdateChecks() async {
        let now = Date()
        let fetchedAt = snapshot.api.latestRelease?.fetchedAt
        let modelsCheckedAt = snapshot.modelUpdates.map(\.checkedAt).min()
        let releaseStale = fetchedAt.map { now.timeIntervalSince($0) >= Self.updateCheckInterval } ?? true
        let modelsStale = modelsCheckedAt.map { now.timeIntervalSince($0) >= Self.updateCheckInterval } ?? true
        guard releaseStale || modelsStale else { return }
        await runUpdateChecks(force: false)
    }

    private func runUpdateChecks(force: Bool) async {
        if let release = await backend.fetchLatestRelease() {
            snapshot.api.latestRelease = release
            persistReleaseInfo(release)
        }

        let installed = await backend.fetchInstalledDigests(config: appliedRuntimeConfig)
        if !installed.isEmpty {
            var statuses: [ModelUpdateStatus] = []
            let now = Date()
            for entry in installed {
                let local = OllamaRegistryClient.normalizeDigest(entry.digest)
                let remote = await backend.fetchRemoteDigest(model: entry.name)
                statuses.append(ModelUpdateStatus(
                    modelName: entry.name,
                    localDigest: local,
                    remoteDigest: remote.map(OllamaRegistryClient.normalizeDigest),
                    checkedAt: now
                ))
            }
            snapshot.modelUpdates = statuses
            persistModelUpdates(statuses)
        }

        stateCache.update(snapshot: snapshot)
        _ = force
    }

    private func rehydrateUpdateCaches() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.releaseInfoDefaultsKey),
           let release = try? decoder.decode(OllamaReleaseInfo.self, from: data) {
            snapshot.api.latestRelease = release
        }
        if let data = defaults.data(forKey: Self.modelUpdatesDefaultsKey),
           let statuses = try? decoder.decode([ModelUpdateStatus].self, from: data) {
            snapshot.modelUpdates = statuses
        }
    }

    private func persistReleaseInfo(_ release: OllamaReleaseInfo) {
        if let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: Self.releaseInfoDefaultsKey)
        }
    }

    private func persistModelUpdates(_ statuses: [ModelUpdateStatus]) {
        if let data = try? JSONEncoder().encode(statuses) {
            UserDefaults.standard.set(data, forKey: Self.modelUpdatesDefaultsKey)
        }
    }

    func recentLogLines(limit: Int) -> String {
        let lines = max(1, min(limit, 500))
        guard let contents = try? String(contentsOfFile: appliedRuntimeConfig.managedLogPath, encoding: .utf8) else {
            return ""
        }
        let token = savedConfig.controlBearerToken
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
        lines.append("# HELP ollama_guardian_requests_per_minute Completed Ollama requests in the last 60 seconds.")
        lines.append("# TYPE ollama_guardian_requests_per_minute gauge")
        lines.append("ollama_guardian_requests_per_minute \(current.requestRate.requestsPerMinute)")
        lines.append("# HELP ollama_guardian_inflight_peak_60s Peak concurrent in-flight Ollama requests in the last 60 seconds.")
        lines.append("# TYPE ollama_guardian_inflight_peak_60s gauge")
        lines.append("ollama_guardian_inflight_peak_60s \(current.requestRate.peakConcurrencyLastMinute)")
        lines.append("# HELP ollama_guardian_inflight_current Currently in-flight Ollama requests estimated from log timings.")
        lines.append("# TYPE ollama_guardian_inflight_current gauge")
        lines.append("ollama_guardian_inflight_current \(current.requestRate.currentInflightEstimate)")
        lines.append("# HELP ollama_guardian_parallel_limit Loaded models multiplied by configured parallel slots.")
        lines.append("# TYPE ollama_guardian_parallel_limit gauge")
        lines.append("ollama_guardian_parallel_limit \(current.requestRate.parallelLimit)")
        lines.append("# HELP ollama_guardian_model_update_available Whether a newer registry digest is available for a loaded model.")
        lines.append("# TYPE ollama_guardian_model_update_available gauge")
        for status in current.modelUpdates {
            let escaped = status.modelName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("ollama_guardian_model_update_available{model=\"\(escaped)\"} \(status.updateAvailable ? 1 : 0)")
        }
        lines.append("# HELP ollama_guardian_ollama_update_available Whether a newer Ollama release is published on GitHub.")
        lines.append("# TYPE ollama_guardian_ollama_update_available gauge")
        lines.append("ollama_guardian_ollama_update_available \(current.api.updateAvailable ? 1 : 0)")
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
        lines.append("# HELP ollama_guardian_tts_enabled Whether the local TTS fallback is enabled.")
        lines.append("# TYPE ollama_guardian_tts_enabled gauge")
        lines.append("ollama_guardian_tts_enabled \(current.tts.enabled ? 1 : 0)")
        lines.append("# HELP ollama_guardian_tts_up Whether the managed TTS server process is running.")
        lines.append("# TYPE ollama_guardian_tts_up gauge")
        lines.append("ollama_guardian_tts_up \(current.tts.running ? 1 : 0)")
        lines.append("# HELP ollama_guardian_tts_healthy Whether the TTS server reports healthy.")
        lines.append("# TYPE ollama_guardian_tts_healthy gauge")
        lines.append("ollama_guardian_tts_healthy \(current.tts.healthy ? 1 : 0)")
        lines.append("# HELP ollama_guardian_tts_restart_total Times the guardian restarted the TTS server.")
        lines.append("# TYPE ollama_guardian_tts_restart_total counter")
        lines.append("ollama_guardian_tts_restart_total \(current.tts.restartCount)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func requestNotificationsIfNeeded() async {
        guard savedConfig.notificationsEnabled else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func startManagedServices() async throws {
        try savedConfig.validate()
        restartServers()
        startSamplingLoop()
        let currentConfig = savedConfig
        try await backend.startManagedProcess(config: currentConfig)
        let version = try await backend.waitForHealthyAPI(baseURL: currentConfig.resolvedOllamaBaseURL)
        snapshot.api.version = version
        snapshot.api.healthy = true
        snapshot.api.healthFailureStreak = 0
        if currentConfig.keepWarmEnabled {
            try await backend.warmConfiguredModels(config: currentConfig)
        }
        adoptAppliedRuntimeConfig(currentConfig)
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

        metricsServer = LightweightHTTPServer(host: savedConfig.metricsBindHost, port: UInt16(savedConfig.metricsPort), queueLabel: "ollama.guardian.metrics", logger: logger) { [weak self] request in
            guard let self else { return .text(status: "500 Internal Server Error", "missing controller\n") }
            if request.path == "/health" {
                return .text("ok\n")
            }
            if request.path == "/metrics" {
                return .text(contentType: "text/plain; version=0.0.4; charset=utf-8", self.prometheusMetrics())
            }
            return .text(status: "404 Not Found", "not found\n")
        }

        controlServer = LightweightHTTPServer(host: savedConfig.controlBindHost, port: UInt16(savedConfig.controlPort), queueLabel: "ollama.guardian.control", logger: logger) { [weak self] request in
            guard let self else { return .text(status: "500 Internal Server Error", "missing controller\n") }
            return self.handleControlRequest(request)
        }

        var listenerIssue: UserFacingIssue?
        do {
            try metricsServer?.start()
        } catch {
            listenerIssue = GuardianRuntimeError.listenerBindFailure(
                service: "Metrics",
                host: savedConfig.metricsBindHost,
                port: savedConfig.metricsPort
            ).userIssue
            presentIssue(
                listenerIssue!
            )
        }

        do {
            try controlServer?.start()
        } catch {
            listenerIssue = GuardianRuntimeError.listenerBindFailure(
                service: "Control API",
                host: savedConfig.controlBindHost,
                port: savedConfig.controlPort
            ).userIssue
            presentIssue(
                listenerIssue!
            )
        }

        if listenerIssue == nil {
            clearIssue(matchingTitles: ["Metrics Port Is Busy", "Control API Port Is Busy"])
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
        let runtimeConfig = appliedRuntimeConfig
        let policyConfig = savedConfig
        let result = await backend.collectSample(config: runtimeConfig)

        snapshot.system = result.system
        snapshot.process = result.process
        snapshot.requestRate = result.requestRate
        appendMetricSamples(at: Date())

        if let version = result.version, let loadedModels = result.loadedModels {
            let preservedRelease = snapshot.api.latestRelease
            snapshot.api = APIState(healthy: true, loadedModels: loadedModels, healthFailureStreak: 0, version: version, latestRelease: preservedRelease)
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

        if snapshot.process.cpuPercent >= policyConfig.cpuThresholdPercent {
            consecutiveHighCPUCount += 1
        } else {
            consecutiveHighCPUCount = 0
        }

        let outcome = DetectionEngine.evaluate(
            DetectionInput(snapshot: snapshot, config: policyConfig, now: Date(), consecutiveHighCPUCount: consecutiveHighCPUCount)
        )
        snapshot.stuckState = outcome.stuck
        stateCache.update(snapshot: snapshot)

        if outcome.stuck, policyConfig.autoReloadEnabled {
            runMutatingAction(name: "auto reload") { [weak self] in
                guard let self else { return }
                try await self.reloadOllama(trigger: .stuck, message: outcome.reason ?? "Stuck state detected")
            }
        }

        if snapshot.api.healthy, snapshot.process.running, snapshot.issue?.title == "Ollama API Did Not Come Up" {
            clearIssue()
        }

        await refreshTTS()
    }

    private func reloadOllama(trigger: ReloadTrigger, message: String) async throws {
        snapshot.reloadInProgress = true
        stateCache.update(snapshot: snapshot)
        defer {
            snapshot.reloadInProgress = false
            stateCache.update(snapshot: snapshot)
        }

        logger.write("reload requested trigger=\(trigger.rawValue) message=\(message)")
        let currentConfig = savedConfig
        try await backend.stopManagedProcess(force: true)
        try await backend.startManagedProcess(config: currentConfig)
        let version = try await backend.waitForHealthyAPI(baseURL: currentConfig.resolvedOllamaBaseURL)
        snapshot.api.version = version
        snapshot.api.healthy = true
        snapshot.api.healthFailureStreak = 0
        if currentConfig.keepWarmEnabled {
            try await backend.warmConfiguredModels(config: currentConfig)
        }
        adoptAppliedRuntimeConfig(currentConfig)

        let event = ReloadEvent(trigger: trigger, message: message)
        reloadHistory.insert(event, at: 0)
        snapshot.lastReloadTimestamp = event.timestamp
        snapshot.lastReloadReason = message
        snapshot.reloadCount += 1
        snapshot.cooldownUntil = Date().addingTimeInterval(savedConfig.reloadCooldownSeconds)
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

        if savedConfig.notificationsEnabled, Bundle.main.bundleURL.pathExtension == "app" {
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

    private func adoptAppliedRuntimeConfig(_ newConfig: GuardianConfig) {
        appliedRuntimeConfig = newConfig
        snapshot.managedLogPath = newConfig.managedLogPath
        stateCache.update(snapshot: snapshot)

        guard logger.path != newConfig.managedLogPath else { return }
        let newLogger = FileLogger(path: newConfig.managedLogPath)
        logger = newLogger
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

    private func promptToRestartForSavedSettings() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restart Ollama to apply saved settings?"
        alert.informativeText = "The updated runtime settings are saved. Restart Ollama now to load them, or keep the current runtime and apply them on the next restart."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
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
