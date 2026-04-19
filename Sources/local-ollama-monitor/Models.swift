import Foundation

enum WarmEndpointType: String, Codable, CaseIterable, Identifiable {
    case generate
    case embed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct WarmModelConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var endpointType: WarmEndpointType

    init(id: UUID = UUID(), name: String, endpointType: WarmEndpointType) {
        self.id = id
        self.name = name
        self.endpointType = endpointType
    }
}

struct GuardianConfig: Codable, Equatable {
    var ollamaBaseURL: String
    var ollamaHost: String
    var ollamaPort: Int
    var modelsDirectory: String
    var allowedOrigins: String
    var metricsBindHost: String
    var metricsPort: Int
    var controlPort: Int
    var controlBindHost: String
    var controlBearerToken: String
    var warmModels: [WarmModelConfig]
    var keepAlive: Int
    var contextLength: Int
    var numParallel: Int
    var maxQueue: Int
    var maxLoadedModels: Int
    var loadTimeout: String
    var kvCacheType: String
    var llmLibrary: String
    var gpuOverheadBytes: String
    var cpuThresholdPercent: Double
    var memoryThresholdMB: Double
    var unhealthySeconds: TimeInterval
    var reloadCooldownSeconds: TimeInterval
    var autoReloadEnabled: Bool
    var keepWarmEnabled: Bool
    var notificationsEnabled: Bool
    var debugEnabled: Bool
    var flashAttentionEnabled: Bool
    var noCloudEnabled: Bool
    var noPruneEnabled: Bool
    var schedSpreadEnabled: Bool
    var multiUserCacheEnabled: Bool
    var managedLogPath: String

    static let defaultLogPath = "\(NSHomeDirectory())/Library/Application Support/OllamaGuardian/logs/ollama.log"
    static let defaultModelsDirectory = "\(NSHomeDirectory())/.ollama/models"

    static let `default` = GuardianConfig(
        ollamaBaseURL: "http://127.0.0.1:11434",
        ollamaHost: "0.0.0.0",
        ollamaPort: 11434,
        modelsDirectory: defaultModelsDirectory,
        allowedOrigins: "*",
        metricsBindHost: "0.0.0.0",
        metricsPort: 9464,
        controlPort: 9465,
        controlBindHost: "0.0.0.0",
        controlBearerToken: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        warmModels: [
            WarmModelConfig(name: "gemma4:26b", endpointType: .generate),
            WarmModelConfig(name: "gemma4:e2b", endpointType: .generate),
            WarmModelConfig(name: "nomic-embed-text:latest", endpointType: .embed),
        ],
        keepAlive: -1,
        contextLength: 131072,
        numParallel: 1,
        maxQueue: 512,
        maxLoadedModels: 3,
        loadTimeout: "5m",
        kvCacheType: "f16",
        llmLibrary: "",
        gpuOverheadBytes: "0",
        cpuThresholdPercent: 65,
        memoryThresholdMB: 32_768,
        unhealthySeconds: 120,
        reloadCooldownSeconds: 300,
        autoReloadEnabled: true,
        keepWarmEnabled: true,
        notificationsEnabled: true,
        debugEnabled: false,
        flashAttentionEnabled: false,
        noCloudEnabled: true,
        noPruneEnabled: false,
        schedSpreadEnabled: false,
        multiUserCacheEnabled: false,
        managedLogPath: defaultLogPath
    )

    enum CodingKeys: String, CodingKey {
        case ollamaBaseURL
        case ollamaHost
        case ollamaPort
        case modelsDirectory
        case allowedOrigins
        case metricsBindHost
        case metricsPort
        case controlPort
        case controlBindHost
        case controlBearerToken
        case warmModels
        case keepAlive
        case contextLength
        case numParallel
        case maxQueue
        case maxLoadedModels
        case loadTimeout
        case kvCacheType
        case llmLibrary
        case gpuOverheadBytes
        case cpuThresholdPercent
        case memoryThresholdMB
        case unhealthySeconds
        case reloadCooldownSeconds
        case autoReloadEnabled
        case keepWarmEnabled
        case notificationsEnabled
        case debugEnabled
        case flashAttentionEnabled
        case noCloudEnabled
        case noPruneEnabled
        case schedSpreadEnabled
        case multiUserCacheEnabled
        case managedLogPath
    }

    init(
        ollamaBaseURL: String,
        ollamaHost: String,
        ollamaPort: Int,
        modelsDirectory: String,
        allowedOrigins: String,
        metricsBindHost: String,
        metricsPort: Int,
        controlPort: Int,
        controlBindHost: String,
        controlBearerToken: String,
        warmModels: [WarmModelConfig],
        keepAlive: Int,
        contextLength: Int,
        numParallel: Int,
        maxQueue: Int,
        maxLoadedModels: Int,
        loadTimeout: String,
        kvCacheType: String,
        llmLibrary: String,
        gpuOverheadBytes: String,
        cpuThresholdPercent: Double,
        memoryThresholdMB: Double,
        unhealthySeconds: TimeInterval,
        reloadCooldownSeconds: TimeInterval,
        autoReloadEnabled: Bool,
        keepWarmEnabled: Bool,
        notificationsEnabled: Bool,
        debugEnabled: Bool,
        flashAttentionEnabled: Bool,
        noCloudEnabled: Bool,
        noPruneEnabled: Bool,
        schedSpreadEnabled: Bool,
        multiUserCacheEnabled: Bool,
        managedLogPath: String
    ) {
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaHost = ollamaHost
        self.ollamaPort = ollamaPort
        self.modelsDirectory = modelsDirectory
        self.allowedOrigins = allowedOrigins
        self.metricsBindHost = metricsBindHost
        self.metricsPort = metricsPort
        self.controlPort = controlPort
        self.controlBindHost = controlBindHost
        self.controlBearerToken = controlBearerToken
        self.warmModels = warmModels
        self.keepAlive = keepAlive
        self.contextLength = contextLength
        self.numParallel = numParallel
        self.maxQueue = maxQueue
        self.maxLoadedModels = maxLoadedModels
        self.loadTimeout = loadTimeout
        self.kvCacheType = kvCacheType
        self.llmLibrary = llmLibrary
        self.gpuOverheadBytes = gpuOverheadBytes
        self.cpuThresholdPercent = cpuThresholdPercent
        self.memoryThresholdMB = memoryThresholdMB
        self.unhealthySeconds = unhealthySeconds
        self.reloadCooldownSeconds = reloadCooldownSeconds
        self.autoReloadEnabled = autoReloadEnabled
        self.keepWarmEnabled = keepWarmEnabled
        self.notificationsEnabled = notificationsEnabled
        self.debugEnabled = debugEnabled
        self.flashAttentionEnabled = flashAttentionEnabled
        self.noCloudEnabled = noCloudEnabled
        self.noPruneEnabled = noPruneEnabled
        self.schedSpreadEnabled = schedSpreadEnabled
        self.multiUserCacheEnabled = multiUserCacheEnabled
        self.managedLogPath = managedLogPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GuardianConfig.default

        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? fallback.ollamaBaseURL
        ollamaHost = try container.decodeIfPresent(String.self, forKey: .ollamaHost) ?? fallback.ollamaHost
        ollamaPort = try container.decodeIfPresent(Int.self, forKey: .ollamaPort) ?? fallback.ollamaPort
        modelsDirectory = try container.decodeIfPresent(String.self, forKey: .modelsDirectory) ?? fallback.modelsDirectory
        allowedOrigins = try container.decodeIfPresent(String.self, forKey: .allowedOrigins) ?? fallback.allowedOrigins
        metricsBindHost = try container.decodeIfPresent(String.self, forKey: .metricsBindHost) ?? fallback.metricsBindHost
        metricsPort = try container.decodeIfPresent(Int.self, forKey: .metricsPort) ?? fallback.metricsPort
        controlPort = try container.decodeIfPresent(Int.self, forKey: .controlPort) ?? fallback.controlPort
        controlBindHost = try container.decodeIfPresent(String.self, forKey: .controlBindHost) ?? fallback.controlBindHost
        controlBearerToken = try container.decodeIfPresent(String.self, forKey: .controlBearerToken) ?? fallback.controlBearerToken
        warmModels = try container.decodeIfPresent([WarmModelConfig].self, forKey: .warmModels) ?? fallback.warmModels
        keepAlive = try container.decodeIfPresent(Int.self, forKey: .keepAlive) ?? fallback.keepAlive
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? fallback.contextLength
        numParallel = try container.decodeIfPresent(Int.self, forKey: .numParallel) ?? fallback.numParallel
        maxQueue = try container.decodeIfPresent(Int.self, forKey: .maxQueue) ?? fallback.maxQueue
        maxLoadedModels = try container.decodeIfPresent(Int.self, forKey: .maxLoadedModels) ?? fallback.maxLoadedModels
        loadTimeout = try container.decodeIfPresent(String.self, forKey: .loadTimeout) ?? fallback.loadTimeout
        kvCacheType = try container.decodeIfPresent(String.self, forKey: .kvCacheType) ?? fallback.kvCacheType
        llmLibrary = try container.decodeIfPresent(String.self, forKey: .llmLibrary) ?? fallback.llmLibrary
        gpuOverheadBytes = try container.decodeIfPresent(String.self, forKey: .gpuOverheadBytes) ?? fallback.gpuOverheadBytes
        cpuThresholdPercent = try container.decodeIfPresent(Double.self, forKey: .cpuThresholdPercent) ?? fallback.cpuThresholdPercent
        memoryThresholdMB = try container.decodeIfPresent(Double.self, forKey: .memoryThresholdMB) ?? fallback.memoryThresholdMB
        unhealthySeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .unhealthySeconds) ?? fallback.unhealthySeconds
        reloadCooldownSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .reloadCooldownSeconds) ?? fallback.reloadCooldownSeconds
        autoReloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReloadEnabled) ?? fallback.autoReloadEnabled
        keepWarmEnabled = try container.decodeIfPresent(Bool.self, forKey: .keepWarmEnabled) ?? fallback.keepWarmEnabled
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? fallback.notificationsEnabled
        debugEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugEnabled) ?? fallback.debugEnabled
        flashAttentionEnabled = try container.decodeIfPresent(Bool.self, forKey: .flashAttentionEnabled) ?? fallback.flashAttentionEnabled
        noCloudEnabled = try container.decodeIfPresent(Bool.self, forKey: .noCloudEnabled) ?? fallback.noCloudEnabled
        noPruneEnabled = try container.decodeIfPresent(Bool.self, forKey: .noPruneEnabled) ?? fallback.noPruneEnabled
        schedSpreadEnabled = try container.decodeIfPresent(Bool.self, forKey: .schedSpreadEnabled) ?? fallback.schedSpreadEnabled
        multiUserCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiUserCacheEnabled) ?? fallback.multiUserCacheEnabled
        managedLogPath = try container.decodeIfPresent(String.self, forKey: .managedLogPath) ?? fallback.managedLogPath
    }

    var resolvedOllamaBaseURL: URL {
        URL(string: ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
    }
}

struct SystemMetrics: Codable, Equatable {
    var cpuPercent: Double
    var gpuPercent: Double
    var loadAverage1m: Double
    var memoryUsedBytes: UInt64
    var totalMemoryBytes: UInt64

    static let empty = SystemMetrics(cpuPercent: 0, gpuPercent: 0, loadAverage1m: 0, memoryUsedBytes: 0, totalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
}

struct ProcessMetrics: Codable, Equatable {
    var pid: Int32?
    var cpuPercent: Double
    var residentMemoryBytes: UInt64
    var threadCount: Int
    var running: Bool

    static let empty = ProcessMetrics(pid: nil, cpuPercent: 0, residentMemoryBytes: 0, threadCount: 0, running: false)
}

struct APIState: Codable, Equatable {
    var healthy: Bool
    var loadedModels: [String]
    var healthFailureStreak: Int
    var version: String

    static let empty = APIState(healthy: false, loadedModels: [], healthFailureStreak: 0, version: "")
}

struct InferenceObservation: Codable, Equatable {
    var lastInferenceTimestamp: Date?
    var lastInferenceEndpoint: String?
    var degraded: Bool

    static let empty = InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: false)
}

enum IssueSeverity: String, Codable, Equatable {
    case warning
    case error
}

struct UserFacingIssue: Codable, Equatable, Identifiable {
    var id: UUID
    var severity: IssueSeverity
    var title: String
    var summary: String
    var recoverySteps: [String]

    init(
        id: UUID = UUID(),
        severity: IssueSeverity = .error,
        title: String,
        summary: String,
        recoverySteps: [String]
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.summary = summary
        self.recoverySteps = recoverySteps
    }
}

struct GuardianSnapshot: Codable, Equatable {
    var system: SystemMetrics
    var process: ProcessMetrics
    var api: APIState
    var inference: InferenceObservation
    var issue: UserFacingIssue?
    var reloadInProgress: Bool
    var stuckState: Bool
    var lastReloadTimestamp: Date?
    var lastReloadReason: String?
    var reloadCount: Int
    var cooldownUntil: Date?
    var managedLogPath: String

    static let empty = GuardianSnapshot(
        system: .empty,
        process: .empty,
        api: .empty,
        inference: .empty,
        issue: nil,
        reloadInProgress: false,
        stuckState: false,
        lastReloadTimestamp: nil,
        lastReloadReason: nil,
        reloadCount: 0,
        cooldownUntil: nil,
        managedLogPath: GuardianConfig.default.managedLogPath
    )

    var loadedModelsCount: Int { api.loadedModels.count }
    var cooldownActive: Bool { cooldownUntil.map { $0 > Date() } ?? false }
}

enum ReloadTrigger: String, Codable {
    case manual
    case stuck
    case healthFailure
    case memorySpike
    case startup
}

struct ReloadEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var timestamp: Date
    var trigger: ReloadTrigger
    var message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), trigger: ReloadTrigger, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.trigger = trigger
        self.message = message
    }
}

struct DetectionInput: Equatable {
    var snapshot: GuardianSnapshot
    var config: GuardianConfig
    var now: Date
    var consecutiveHighCPUCount: Int
}

struct DetectionOutcome: Equatable {
    var stuck: Bool
    var reason: String?
}

struct StatusResponse: Codable {
    var ok: Bool
    var message: String
    var timestamp: Date
    var snapshot: GuardianSnapshot
}

struct MetricPoint: Identifiable, Equatable {
    var id: Date { timestamp }
    var timestamp: Date
    var value: Double
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case liveLogs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .liveLogs:
            return "Live Logs"
        case .settings:
            return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard:
            return "gauge.with.dots.needle.50percent"
        case .liveLogs:
            return "text.alignleft"
        case .settings:
            return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard:
            return "Health, load, and model state"
        case .liveLogs:
            return "Recent Ollama activity"
        case .settings:
            return "Runtime and network controls"
        }
    }
}
