import Charts
import SwiftUI

private struct GuardianTheme {
    let colorScheme: ColorScheme

    var canvasTop: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.98, alpha: 1))
    }

    var canvasBottom: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.92, alpha: 1))
    }

    var chromeBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 0.98))
            : Color(nsColor: NSColor(calibratedWhite: 0.98, alpha: 0.98))
    }

    var sidebarTop: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1))
    }

    var sidebarBottom: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.19, alpha: 1))
    }

    var surface: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.86)
    }

    var surfaceStrong: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.93)
    }

    var surfaceMuted: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
    }

    var surfaceBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var sidebarText: Color { .white }
    var sidebarSecondary: Color { Color.white.opacity(0.76) }
    var sidebarMuted: Color { Color.white.opacity(0.50) }

    var consoleBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1))
    }

    var consoleText: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.73, green: 0.90, blue: 0.78, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.83, green: 0.97, blue: 0.86, alpha: 1))
    }

    var accent: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.42, green: 0.65, blue: 0.92, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.19, green: 0.45, blue: 0.74, alpha: 1))
    }

    var cpu: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.33, green: 0.77, blue: 0.63, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.58, blue: 0.46, alpha: 1))
    }

    var gpu: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.99, green: 0.64, blue: 0.34, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.44, blue: 0.22, alpha: 1))
    }

    var danger: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(calibratedRed: 0.99, green: 0.46, blue: 0.49, alpha: 1))
            : Color(nsColor: NSColor(calibratedRed: 0.74, green: 0.22, blue: 0.27, alpha: 1))
    }

    var buttonBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
    }
}

private func formatNumber(_ value: Double, _ specifier: String) -> String {
    String(format: specifier, value)
}

private func memoryString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Bundle {
    var guardianVersionString: String {
        if let version = infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "dev"
    }
}

struct MainShellView: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            commandBar
            HStack(spacing: 0) {
                SidebarView()
                Divider()
                detailPane
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(
            LinearGradient(
                colors: [theme.canvasTop, theme.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var commandBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ollama Guardian")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(commandSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
                title: guardian.statusLine,
                systemImage: guardian.snapshot.api.healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: guardian.snapshot.api.healthy ? theme.cpu : theme.danger
            )

            ActionButton(title: "Reload", systemImage: "arrow.clockwise") {
                guardian.manualRestart()
            }

            ActionButton(title: "Warm Models", systemImage: "flame.fill") {
                guardian.warmModels()
            }

            if guardian.selectedSection == .settings {
                ActionButton(title: "Save Settings", systemImage: "square.and.arrow.down") {
                    guardian.saveSettings()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(theme.chromeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.surfaceBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch guardian.selectedSection {
        case .dashboard:
            DashboardPane()
        case .liveLogs:
            LiveLogsPane()
        case .settings:
            SettingsPane()
        }
    }

    private var commandSubtitle: String {
        switch guardian.selectedSection {
        case .dashboard:
            return "Local health, load, and model residency at a glance"
        case .liveLogs:
            return "Recent Ollama activity with optional auto-follow"
        case .settings:
            return "Runtime, model, and remote access settings"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 8) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarButton(section: section, isSelected: guardian.selectedSection == section)
                }
            }

            Spacer()

            sidebarStatusCard
            sidebarFooterCard
        }
        .padding(20)
        .frame(width: 276)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [theme.sidebarTop, theme.sidebarBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var sidebarStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(
                title: guardian.statusLine,
                systemImage: guardian.snapshot.api.healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: guardian.snapshot.api.healthy ? theme.cpu : theme.danger
            )

            Text("\(guardian.snapshot.loadedModelsCount) model\(guardian.snapshot.loadedModelsCount == 1 ? "" : "s") loaded")
                .foregroundStyle(theme.sidebarSecondary)
        }
        .padding(16)
        .background(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sidebarFooterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledSidebarValue(label: "Metrics", value: "http://\(guardian.config.metricsBindHost):\(guardian.config.metricsPort)/metrics")
            LabeledSidebarValue(label: "Control API", value: "http://\(guardian.config.controlBindHost):\(guardian.config.controlPort)/api/status")

            Divider()
                .overlay(theme.sidebarMuted.opacity(0.28))

            Text("Guardian \(Bundle.main.guardianVersionString)")
                .font(.caption.monospaced())
                .foregroundStyle(theme.sidebarSecondary)
            Text("Ollama \(guardian.snapshot.api.version.nilIfEmpty ?? "—")")
                .font(.caption.monospaced())
                .foregroundStyle(theme.sidebarMuted)
        }
        .padding(16)
        .background(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct DashboardPane: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let issue = guardian.snapshot.issue {
                    IssueCard(issue: issue)
                }
                heroCard
                graphRow
                summaryGrid
                HStack(alignment: .top, spacing: 18) {
                    loadedModelsCard
                    remoteOpsCard
                }
                reloadHistoryCard
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(guardian.snapshot.api.healthy ? "Ollama is reachable" : "Guardian is watching for recovery")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text("Managed process: \(guardian.snapshot.process.running ? "Running" : "Stopped") • PID \(guardian.snapshot.process.pid.map(String.init) ?? "—")")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("Warm set: \(guardian.config.warmModels.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    StatusPill(
                        title: guardian.snapshot.api.healthy ? "API Healthy" : "API Unhealthy",
                        systemImage: guardian.snapshot.api.healthy ? "checkmark.circle.fill" : "xmark.circle.fill",
                        tint: guardian.snapshot.api.healthy ? theme.cpu : theme.danger
                    )

                    if guardian.snapshot.issue == nil, let lastErrorMessage = guardian.lastErrorMessage {
                        Text(lastErrorMessage)
                            .font(.caption)
                            .foregroundStyle(theme.danger)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 14) {
                KeyFactCard(title: "Host CPU", value: "\(formatNumber(guardian.snapshot.system.cpuPercent, "%.1f"))%", subtitle: "active CPU only")
                KeyFactCard(title: "Metal GPU", value: "\(formatNumber(guardian.snapshot.system.gpuPercent, "%.0f"))%", subtitle: "device utilization")
                KeyFactCard(title: "Memory Used", value: memoryString(guardian.snapshot.system.memoryUsedBytes), subtitle: "of \(memoryString(guardian.snapshot.system.totalMemoryBytes))")
                KeyFactCard(title: "Load 1m", value: formatNumber(guardian.snapshot.system.loadAverage1m, "%.2f"), subtitle: "system average")
            }
        }
        .padding(24)
        .background(theme.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
    }

    private var graphRow: some View {
        HStack(spacing: 18) {
            SparklineCard(
                title: "Ollama CPU",
                value: "\(formatNumber(guardian.snapshot.process.cpuPercent, "%.1f"))%",
                subtitle: "Process CPU across recent samples",
                points: guardian.ollamaCPUHistory,
                color: theme.cpu
            )

            SparklineCard(
                title: "Metal GPU",
                value: "\(formatNumber(guardian.snapshot.system.gpuPercent, "%.0f"))%",
                subtitle: "Apple GPU device utilization from IOKit",
                points: guardian.gpuHistory,
                color: theme.gpu
            )
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 18) {
            MetricTile(title: "Ollama Memory", value: memoryString(guardian.snapshot.process.residentMemoryBytes), detail: "Resident memory footprint")
            MetricTile(title: "Threads", value: "\(guardian.snapshot.process.threadCount)", detail: "Runner thread count")
            MetricTile(title: "Loaded Models", value: "\(guardian.snapshot.loadedModelsCount)", detail: "From `/api/ps`")
            MetricTile(title: "Last Inference", value: guardian.snapshot.inference.lastInferenceTimestamp.map(DateFormatter.guardianShort.string(from:)) ?? "Never", detail: guardian.snapshot.inference.lastInferenceEndpoint ?? "No endpoint detected")
            MetricTile(title: "Last Reload", value: guardian.snapshot.lastReloadTimestamp.map(DateFormatter.guardianShort.string(from:)) ?? "Never", detail: guardian.snapshot.lastReloadReason ?? "No reloads yet")
            MetricTile(title: "Cooldown", value: guardian.snapshot.cooldownActive ? "Active" : "Ready", detail: guardian.snapshot.cooldownUntil.map(DateFormatter.guardianShort.string(from:)) ?? "No cooldown")
        }
    }

    private var loadedModelsCard: some View {
        SurfaceCard(title: "Loaded Models", subtitle: "What Ollama currently reports as resident") {
            if guardian.snapshot.api.loadedModels.isEmpty {
                Text("No models are currently reported by `/api/ps`.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(guardian.snapshot.api.loadedModels, id: \.self) { model in
                        HStack {
                            Image(systemName: "cube.transparent.fill")
                                .foregroundStyle(theme.accent)
                            Text(model)
                                .font(.body.monospaced())
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var remoteOpsCard: some View {
        SurfaceCard(title: "Remote Observability", subtitle: "Network endpoints and control surfaces") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledValue(label: "Metrics", value: "http://\(guardian.config.metricsBindHost):\(guardian.config.metricsPort)/metrics")
                LabeledValue(label: "Control", value: "http://\(guardian.config.controlBindHost):\(guardian.config.controlPort)/api/status")
                Text("Prometheus can scrape over the network when Metrics Bind Host is `0.0.0.0` or your LAN IP. GPU is reported as whole-device utilization, which is a useful signal for Ollama on this Mac mini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reloadHistoryCard: some View {
        SurfaceCard(title: "Reload History", subtitle: "Recent watchdog or manual interventions") {
            if guardian.reloadHistory.isEmpty {
                Text("No reloads recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(guardian.reloadHistory.prefix(10)) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text(DateFormatter.guardianShort.string(from: event.timestamp))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 190, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.trigger.rawValue.capitalized)
                                    .font(.headline)
                                Text(event.message)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

struct LiveLogsPane: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme
    @State private var lineLimit = 220
    @State private var followLatest = true

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    private var logLines: [String] {
        let value = guardian.recentLogLines(limit: lineLimit)
        if value.isEmpty {
            return ["No log content yet at the managed Ollama log file."]
        }
        return value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private var logSignature: String {
        "\(logLines.count)-\(logLines.last ?? "")-\(lineLimit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let issue = guardian.snapshot.issue {
                IssueCard(issue: issue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Live Logs")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Recent Ollama server output from the managed log file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                Stepper("Showing \(lineLimit) lines", value: $lineLimit, in: 80...500, step: 20)

                Toggle("Follow latest entry", isOn: $followLatest)
                    .toggleStyle(.switch)
                    .fixedSize()

                Spacer()

                ActionButton(title: "Open in Terminal", systemImage: "terminal") {
                    guardian.openLiveLogs()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM")
                    }
                    .padding(18)
                }
                .background(theme.consoleBackground)
                .foregroundStyle(theme.consoleText)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(theme.surfaceBorder, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: guardian.selectedSection) { _, newValue in
                    if newValue == .liveLogs, followLatest {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: logSignature) { _, _ in
                    if guardian.selectedSection == .liveLogs, followLatest {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: followLatest) { _, newValue in
                    if newValue {
                        scrollToBottom(proxy)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }
    private let kvCacheOptions = ["f16", "q8_0", "q4_0"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let issue = guardian.snapshot.issue {
                    IssueCard(issue: issue)
                }

                SurfaceCard(
                    title: "Server & Model Runtime",
                    subtitle: "Based on `ollama serve --help`, the Ollama FAQ, and the official envconfig list. This surfaces the practical server options for this guardian-managed node."
                ) {
                    VStack(alignment: .leading, spacing: 22) {
                        SettingsSubsection(title: "Network & Storage", subtitle: "Server address, model path, browser origins, and managed logs") {
                            VStack(spacing: 12) {
                                textSettingRow(
                                    "Ollama Base URL",
                                    help: "The base URL the guardian uses when it calls the local Ollama HTTP API. This should normally match your bind host and port."
                                ) {
                                    TextField("http://127.0.0.1:11434", text: $guardian.config.ollamaBaseURL)
                                }
                                textSettingRow(
                                    "Bind Host",
                                    help: "Sets OLLAMA_HOST together with the port. Use 127.0.0.1 for local-only access, or 0.0.0.0 / a LAN IP to expose Ollama on the network."
                                ) {
                                    TextField("0.0.0.0", text: $guardian.config.ollamaHost)
                                }
                                intTextSettingRow(
                                    "Ollama Port",
                                    help: "The TCP port Ollama listens on. This is written as part of OLLAMA_HOST and should stay aligned with the base URL above.",
                                    value: $guardian.config.ollamaPort
                                )
                                textSettingRow(
                                    "Models Directory",
                                    help: "Sets OLLAMA_MODELS. Ollama stores pulled models and blobs in this directory."
                                ) {
                                    TextField(GuardianConfig.defaultModelsDirectory, text: $guardian.config.modelsDirectory)
                                        .font(.body.monospaced())
                                }
                                textSettingRow(
                                    "Allowed Origins",
                                    help: "Sets OLLAMA_ORIGINS. This controls which browser or app origins are allowed to access the Ollama server."
                                ) {
                                    TextField("*", text: $guardian.config.allowedOrigins)
                                        .font(.body.monospaced())
                                }
                                textSettingRow(
                                    "Managed Log Path",
                                    help: "The log file the guardian writes Ollama stdout and stderr to, and the same file it reads for live log view and inference detection."
                                ) {
                                    TextField("Managed log path", text: $guardian.config.managedLogPath)
                                        .font(.body.monospaced())
                                }
                            }
                        }

                        Divider()
                            .overlay(theme.surfaceBorder)

                        SettingsSubsection(title: "Performance & Loading", subtitle: "Concurrency, model residency, loading behavior, and memory controls") {
                            VStack(spacing: 12) {
                                intTextSettingRow(
                                    "Keep Alive",
                                    help: "Sets OLLAMA_KEEP_ALIVE. Negative values such as -1 keep models loaded, 0 unloads immediately, and positive values keep models warm for that many seconds.",
                                    value: $guardian.config.keepAlive,
                                    note: "-1 keeps models warm"
                                )
                                intTextSettingRow(
                                    "Context Length",
                                    help: "Sets OLLAMA_CONTEXT_LENGTH. This is the default context window used unless a request overrides it.",
                                    value: $guardian.config.contextLength
                                )
                                intTextSettingRow(
                                    "Parallel",
                                    help: "Sets OLLAMA_NUM_PARALLEL. This is the maximum number of parallel requests each loaded model will process at once.",
                                    value: $guardian.config.numParallel
                                )
                                intTextSettingRow(
                                    "Max Queue",
                                    help: "Sets OLLAMA_MAX_QUEUE. When Ollama is busy, additional requests are queued up to this limit before new ones are rejected.",
                                    value: $guardian.config.maxQueue
                                )
                                intTextSettingRow(
                                    "Max Loaded Models",
                                    help: "Sets OLLAMA_MAX_LOADED_MODELS. This controls how many models Ollama may keep resident concurrently if memory allows.",
                                    value: $guardian.config.maxLoadedModels
                                )
                                textSettingRow(
                                    "Load Timeout",
                                    help: "Sets OLLAMA_LOAD_TIMEOUT. This is how long model loads are allowed to stall before Ollama gives up."
                                ) {
                                    TextField("5m", text: $guardian.config.loadTimeout)
                                }
                                pickerSettingRow(
                                    "K/V Cache Type",
                                    help: "Sets OLLAMA_KV_CACHE_TYPE. Lower-precision cache types reduce memory use at the cost of some precision."
                                ) {
                                    Picker("K/V Cache Type", selection: $guardian.config.kvCacheType) {
                                        ForEach(kvCacheOptions, id: \.self) { option in
                                            Text(option).tag(option)
                                        }
                                    }
                                    .frame(width: 220)
                                }
                                textSettingRow(
                                    "LLM Library",
                                    help: "Sets OLLAMA_LLM_LIBRARY. Leave blank for auto-detection, or specify a backend library if you need to force one."
                                ) {
                                    TextField("auto", text: $guardian.config.llmLibrary)
                                }
                                textSettingRow(
                                    "GPU Overhead (bytes)",
                                    help: "Sets OLLAMA_GPU_OVERHEAD. Use this to reserve a portion of VRAM so Ollama leaves headroom for the system or other GPU work."
                                ) {
                                    TextField("0", text: $guardian.config.gpuOverheadBytes)
                                }
                            }
                        }

                        Divider()
                            .overlay(theme.surfaceBorder)

                        SettingsSubsection(title: "Server Features", subtitle: "Current practical server toggles from the Ollama CLI and official docs") {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading, spacing: 12) {
                                    settingToggle("Auto Reload Enabled", help: "Guardian-side watchdog behavior. When enabled, the guardian may restart Ollama automatically when it detects a stuck state.", isOn: $guardian.config.autoReloadEnabled)
                                    settingToggle("Keep Warm Enabled", help: "Guardian-side behavior. When enabled, the configured warm models are pinged after startup and reloads.", isOn: $guardian.config.keepWarmEnabled)
                                    settingToggle("Notifications Enabled", help: "When enabled, the guardian posts local macOS notifications for reload events and failures.", isOn: $guardian.config.notificationsEnabled)
                                    settingToggle("Debug Logging", help: "Sets OLLAMA_DEBUG. Enables additional verbose Ollama debug output in the managed log.", isOn: $guardian.config.debugEnabled)
                                    settingToggle("Flash Attention", help: "Sets OLLAMA_FLASH_ATTENTION. This can reduce memory use at larger context sizes on supported hardware and models.", isOn: $guardian.config.flashAttentionEnabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .leading, spacing: 12) {
                                    settingToggle("Disable Ollama Cloud", help: "Sets OLLAMA_NO_CLOUD. This disables Ollama cloud features such as remote inference and web search.", isOn: $guardian.config.noCloudEnabled)
                                    settingToggle("Disable Prune on Startup", help: "Sets OLLAMA_NOPRUNE. This prevents Ollama from pruning unused model blobs when the server starts.", isOn: $guardian.config.noPruneEnabled)
                                    settingToggle("Spread Scheduling", help: "Sets OLLAMA_SCHED_SPREAD. When enabled, Ollama prefers spreading model work across all available GPUs instead of a single best-fit GPU.", isOn: $guardian.config.schedSpreadEnabled)
                                    settingToggle("Multi-user Cache", help: "Sets OLLAMA_MULTIUSER_CACHE. This helps prompt caching work better across multiple users or clients hitting the same server.", isOn: $guardian.config.multiUserCacheEnabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Divider()
                            .overlay(theme.surfaceBorder)

                        SettingsSubsection(title: "Warm Models", subtitle: "Models that should be primed after startup and reloads") {
                            VStack(spacing: 12) {
                                ForEach($guardian.config.warmModels) { $model in
                                    HStack(spacing: 12) {
                                        textSettingRow(
                                            "Model",
                                            help: "The Ollama model tag that should be warmed. These are pinged in order after startup and reloads."
                                        ) {
                                            TextField("Model name", text: $model.name)
                                        }
                                        pickerSettingRow(
                                            "Warm Endpoint",
                                            help: "Choose whether this model should be warmed with `/api/generate` or `/api/embed`, depending on how the model is used."
                                        ) {
                                            Picker("Endpoint", selection: $model.endpointType) {
                                                ForEach(WarmEndpointType.allCases) { endpoint in
                                                    Text(endpoint.title).tag(endpoint)
                                                }
                                            }
                                            .frame(width: 160)
                                        }
                                    }
                                }

                                HStack {
                                    Button("Add Warm Model") {
                                        guardian.config.warmModels.append(WarmModelConfig(name: "", endpointType: .generate))
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    SurfaceCard(title: "Watchdog Thresholds", subtitle: "Signals that drive stuck detection and cooldown") {
                        VStack(spacing: 12) {
                            doubleTextSettingRow(
                                "CPU Threshold %",
                                help: "If Ollama CPU stays above this threshold while no inference activity is seen, the guardian may treat that as a stuck state.",
                                value: $guardian.config.cpuThresholdPercent
                            )
                            doubleTextSettingRow(
                                "Memory Threshold MB",
                                help: "Optional memory ceiling for secondary stuck-state heuristics.",
                                value: $guardian.config.memoryThresholdMB
                            )
                            doubleTextSettingRow(
                                "Unhealthy Seconds",
                                help: "How long Ollama can sit without inference activity before the guardian considers it suspicious when other stuck signals are present.",
                                value: $guardian.config.unhealthySeconds
                            )
                            doubleTextSettingRow(
                                "Reload Cooldown Seconds",
                                help: "How long the guardian waits after a reload before allowing another automatic reload.",
                                value: $guardian.config.reloadCooldownSeconds
                            )
                        }
                    }

                    SurfaceCard(title: "Remote APIs", subtitle: "Prometheus scraping and AI-SRE control access") {
                        VStack(spacing: 12) {
                            textSettingRow(
                                "Metrics Bind Host",
                                help: "The address the guardian metrics server listens on. Use 0.0.0.0 or a LAN IP if Prometheus scrapes over the network."
                            ) {
                                TextField("0.0.0.0", text: $guardian.config.metricsBindHost)
                            }
                            intTextSettingRow(
                                "Metrics Port",
                                help: "The port used for `/health` and `/metrics`.",
                                value: $guardian.config.metricsPort
                            )
                            textSettingRow(
                                "Control Bind Host",
                                help: "The address the authenticated control API listens on."
                            ) {
                                TextField("0.0.0.0", text: $guardian.config.controlBindHost)
                            }
                            intTextSettingRow(
                                "Control Port",
                                help: "The port used for the authenticated remote operations API.",
                                value: $guardian.config.controlPort
                            )
                            textSettingRow(
                                "Bearer Token",
                                help: "The shared bearer token required to access the control API from your remote AI-SRE agent."
                            ) {
                                SecureField("Bearer token", text: $guardian.config.controlBearerToken)
                                    .font(.body.monospaced())
                            }

                            HStack {
                                Button("Generate New Token") {
                                    guardian.generateNewBearerToken()
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func textSettingRow<Content: View>(
        _ title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            HelpLabel(title: title, help: help)
                .frame(width: 200, alignment: .leading)
            content()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pickerSettingRow<Content: View>(
        _ title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            HelpLabel(title: title, help: help)
                .frame(width: 200, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func intTextSettingRow(
        _ title: String,
        help: String,
        value: Binding<Int>,
        note: String? = nil
    ) -> some View {
        textSettingRow(title, help: help) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(title, text: intStringBinding(value))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func doubleTextSettingRow(
        _ title: String,
        help: String,
        value: Binding<Double>
    ) -> some View {
        textSettingRow(title, help: help) {
            TextField(title, text: doubleStringBinding(value))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingToggle(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HelpLabel(title: title, help: help)
        }
        .toggleStyle(.switch)
    }

    private func intStringBinding(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(value.wrappedValue) },
            set: { newValue in
                let filtered = newValue.filter { $0.isNumber || $0 == "-" }
                if let parsed = Int(filtered) {
                    value.wrappedValue = parsed
                } else if filtered.isEmpty {
                    value.wrappedValue = 0
                }
            }
        )
    }

    private func doubleStringBinding(_ value: Binding<Double>) -> Binding<String> {
        Binding(
            get: {
                let raw = String(value.wrappedValue)
                if raw.hasSuffix(".0") {
                    return String(raw.dropLast(2))
                }
                return raw
            },
            set: { newValue in
                let normalized = newValue
                    .replacingOccurrences(of: ",", with: ".")
                    .filter { $0.isNumber || $0 == "." || $0 == "-" }
                if let parsed = Double(normalized) {
                    value.wrappedValue = parsed
                } else if normalized.isEmpty {
                    value.wrappedValue = 0
                }
            }
        )
    }
}

struct SparklineCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var title: String
    var value: String
    var subtitle: String
    var points: [MetricPoint]
    var color: Color

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }

            if points.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.surfaceMuted)
                    .overlay {
                        Text("Waiting for samples…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 108)
            } else {
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Usage", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Usage", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color)
                    .lineStyle(.init(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 108)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
    }
}

struct SurfaceCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
    }
}

struct IssueCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var issue: UserFacingIssue

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(issue.severity == .error ? theme.danger : theme.accent)
                Text(issue.title)
                    .font(.title3.bold())
                Spacer()
            }

            Text(issue.summary)
                .foregroundStyle(.secondary)

            if !issue.recoverySteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(issue.recoverySteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(step)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceStrong)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(issue.severity == .error ? theme.danger.opacity(0.35) : theme.accent.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct KeyFactCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var title: String
    var value: String
    var subtitle: String

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MetricTile: View {
    @Environment(\.colorScheme) private var colorScheme

    var title: String
    var value: String
    var detail: String

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

struct SidebarButton: View {
    @EnvironmentObject private var guardian: GuardianController
    @Environment(\.colorScheme) private var colorScheme

    var section: SidebarSection
    var isSelected: Bool

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        Button {
            guardian.selectedSection = section
        } label: {
            HStack(spacing: 14) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)

                Text(section.title)
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.white.opacity(colorScheme == .dark ? 0.10 : 0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? theme.sidebarText : theme.sidebarSecondary)
        .help(section.subtitle)
    }
}

struct ActionButton: View {
    @Environment(\.colorScheme) private var colorScheme

    var title: String
    var systemImage: String
    var action: () -> Void

    private var theme: GuardianTheme { GuardianTheme(colorScheme: colorScheme) }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(theme.buttonBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LabeledValue: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}

struct LabeledSidebarValue: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

struct SettingsSubsection<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
    }
}

struct HelpLabel: View {
    var title: String
    var help: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}
