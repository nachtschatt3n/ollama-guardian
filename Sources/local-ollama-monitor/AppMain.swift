import AppKit
import Combine
import SwiftUI

@MainActor
final class HostingWindowController: NSWindowController {
    init(title: String, size: NSSize, minSize: NSSize, autosaveName: String, content: AnyView) {
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = minSize
        window.center()
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(autosaveName)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let guardian = GuardianController.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    private lazy var mainWindowController = HostingWindowController(
        title: "Ollama Guardian",
        size: NSSize(width: 1260, height: 860),
        minSize: NSSize(width: 1080, height: 720),
        autosaveName: "OllamaGuardianMainWindow",
        content: AnyView(MainShellView().environmentObject(guardian))
    )

    private let statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
    private let apiMenuItem = NSMenuItem(title: "API: Unknown", action: nil, keyEquivalent: "")
    private let modelsMenuItem = NSMenuItem(title: "Loaded models: 0", action: nil, keyEquivalent: "")
    private let inferenceMenuItem = NSMenuItem(title: "Last inference: Never", action: nil, keyEquivalent: "")
    private let reloadMenuItem = NSMenuItem(title: "Last reload: Never", action: nil, keyEquivalent: "")
    private let metricsMenuItem = NSMenuItem(title: "Metrics: --", action: nil, keyEquivalent: "")
    private let controlMenuItem = NSMenuItem(title: "Control API: --", action: nil, keyEquivalent: "")
    private let ttsMenuItem = NSMenuItem(title: "TTS Fallback: --", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        bindGuardian()
        updateMenu()
    }

    private func installApplicationIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    @objc private func showAboutPanel() {
        let credits = NSMutableAttributedString(string: "github.com/nachtschatt3n/local-ollama-monitor", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let url = URL(string: "https://github.com/nachtschatt3n/local-ollama-monitor") {
            credits.addAttribute(.link, value: url, range: NSRange(location: 0, length: credits.length))
        }

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Ollama Guardian",
            .credits: credits,
        ]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            options[.applicationVersion] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            options[.version] = build
        }
        if let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String {
            options[.init(rawValue: "Copyright")] = copyright
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func checkForUpdates() {
        guardian.checkForUpdatesNow()
    }

    @objc private func openDashboard() {
        showMainWindow(section: .dashboard)
    }

    @objc private func openSettings() {
        showMainWindow(section: .settings)
    }

    @objc private func openLogs() {
        showMainWindow(section: .liveLogs)
    }

    @objc private func reloadOllama() {
        guardian.manualRestart()
    }

    @objc private func warmModels() {
        guardian.warmModels()
    }

    @objc private func restartTTSFallback() {
        guardian.restartTTS()
    }

    @objc private func clearCooldown() {
        guardian.clearCooldown()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showMainWindow(section: SidebarSection) {
        guardian.selectedSection = section
        mainWindowController.showAndActivate()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.title = ""
        }
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func configureMenu() {
        [statusMenuItem, apiMenuItem, modelsMenuItem, inferenceMenuItem, reloadMenuItem, metricsMenuItem, controlMenuItem, ttsMenuItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }

        menu.addItem(.separator())

        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let reloadItem = NSMenuItem(title: "Reload Ollama", action: #selector(reloadOllama), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let warmItem = NSMenuItem(title: "Warm Models", action: #selector(warmModels), keyEquivalent: "w")
        warmItem.target = self
        menu.addItem(warmItem)

        let logsItem = NSMenuItem(title: "Open Live Logs", action: #selector(openLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        let cooldownItem = NSMenuItem(title: "Clear Cooldown", action: #selector(clearCooldown), keyEquivalent: "")
        cooldownItem.target = self
        menu.addItem(cooldownItem)

        let ttsRestartItem = NSMenuItem(title: "Restart TTS Fallback", action: #selector(restartTTSFallback), keyEquivalent: "")
        ttsRestartItem.target = self
        menu.addItem(ttsRestartItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Ollama Guardian", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func bindGuardian() {
        guardian.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)

        guardian.$savedConfig
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)

        guardian.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
            .store(in: &cancellables)
    }

    private func updateMenu() {
        let snapshot = guardian.snapshot
        statusMenuItem.title = "Status: \(guardian.statusLine)"
        apiMenuItem.title = "API: \(snapshot.api.healthy ? "Healthy" : "Unhealthy")"
        modelsMenuItem.title = "Loaded models: \(snapshot.loadedModelsCount)"
        inferenceMenuItem.title = "Last inference: \(snapshot.inference.lastInferenceTimestamp.map(DateFormatter.guardianShort.string(from:)) ?? "Never")"
        reloadMenuItem.title = "Last reload: \(snapshot.lastReloadTimestamp.map(DateFormatter.guardianShort.string(from:)) ?? "Never")"
        metricsMenuItem.title = "Metrics: \(guardian.metricsEndpoint)"
        controlMenuItem.title = "Control API: \(guardian.controlStatusEndpoint)"
        let tts = snapshot.tts
        let ttsStatus = !tts.enabled ? "Disabled" : (tts.healthy ? "Healthy" : (tts.running ? (tts.lastError == "loading" ? "Loading" : "Unhealthy") : "Down"))
        ttsMenuItem.title = "TTS Fallback: \(ttsStatus)"
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = GuardianBrandRenderer.trayImage()
        button.contentTintColor = nil
    }
}

@main
enum OllamaGuardianMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
