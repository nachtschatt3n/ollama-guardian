import Foundation

struct VerificationFailure: Error {
    let message: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw VerificationFailure(message: message)
    }
}

private func testSettingsStoreRoundTripPersistsWarmModels() throws {
    let suiteName = "ollama-guardian-verification-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let store = SettingsStore(defaults: defaults)

    var config = GuardianConfig.default
    config.controlBearerToken = "test-token"
    config.warmModels.append(WarmModelConfig(name: "custom:model", endpointType: .generate))

    try store.save(config)
    let loaded = store.load()

    try expect(loaded.controlBearerToken == "test-token", "SettingsStore failed to persist the bearer token")
    try expect(loaded.warmModels.contains(where: { $0.name == "custom:model" }), "SettingsStore failed to persist the custom warm model")
}

private func testLogParserFindsNativeAndOpenAIEndpoints() throws {
    let native = LogMonitor.extractEndpoint(from: "POST /api/generate HTTP/1.1", matches: ["/api/generate", "/v1/chat/completions"])
    let openAI = LogMonitor.extractEndpoint(from: "POST /v1/chat/completions HTTP/1.1", matches: ["/api/generate", "/v1/chat/completions"])

    try expect(native == "/api/generate", "Native endpoint parsing failed")
    try expect(openAI == "/v1/chat/completions", "OpenAI-compatible endpoint parsing failed")
}

private func testDetectionTriggersOnHighCPUAndNoInference() throws {
    let config = GuardianConfig.default
    let snapshot = GuardianSnapshot(
        system: .empty,
        process: ProcessMetrics(pid: 1, cpuPercent: 91, residentMemoryBytes: 1_024, running: true),
        api: APIState(healthy: true, loadedModels: ["gemma4:26b"], healthFailureStreak: 0, version: "1.0.0", latestRelease: nil),
        inference: InferenceObservation(lastInferenceTimestamp: Date().addingTimeInterval(-400), lastInferenceEndpoint: "/api/generate", degraded: false),
        requestRate: .empty,
        modelUpdates: [],
        tts: .empty,
        issue: nil,
        reloadInProgress: false,
        stuckState: false,
        lastReloadTimestamp: nil,
        lastReloadReason: nil,
        reloadCount: 0,
        cooldownUntil: nil,
        managedLogPath: GuardianConfig.defaultLogPath
    )

    let outcome = DetectionEngine.evaluate(
        DetectionInput(snapshot: snapshot, config: config, now: Date(), consecutiveHighCPUCount: 2)
    )

    try expect(outcome.stuck, "DetectionEngine should flag high CPU with no inference as stuck")
}

private func testDetectionSkipsInferenceRuleWhenLogsAreDegraded() throws {
    let config = GuardianConfig.default
    let snapshot = GuardianSnapshot(
        system: .empty,
        process: ProcessMetrics(pid: 1, cpuPercent: 91, residentMemoryBytes: 1_024, running: true),
        api: APIState(healthy: true, loadedModels: ["gemma4:26b"], healthFailureStreak: 0, version: "1.0.0", latestRelease: nil),
        inference: InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: true),
        requestRate: .empty,
        modelUpdates: [],
        tts: .empty,
        issue: nil,
        reloadInProgress: false,
        stuckState: false,
        lastReloadTimestamp: nil,
        lastReloadReason: nil,
        reloadCount: 0,
        cooldownUntil: nil,
        managedLogPath: GuardianConfig.defaultLogPath
    )

    let outcome = DetectionEngine.evaluate(
        DetectionInput(snapshot: snapshot, config: config, now: Date(), consecutiveHighCPUCount: 2)
    )

    try expect(!outcome.stuck, "DetectionEngine should suppress the no-inference rule when logs are degraded")
}

private func testHTTPRequestParsesBearerToken() throws {
    let header = "Authorization: " + "Bearer sample-control-token"
    let raw = "GET /api/status HTTP/1.1\r\n\(header)\r\n\r\n"
    let request = LightweightHTTPServer.parse(requestString: raw, rawData: Data(raw.utf8))
    try expect(request?.authorizationBearerToken == "sample-control-token", "HTTP request parsing failed to extract the bearer token")
}

private func testExecutableLocatorFindsBinaryInSuppliedSearchPath() throws {
    let path = ExecutableLocator.findExecutable(named: "swift", searchPath: "/usr/bin:/bin", fallbackDirectories: [])
    try expect(path == "/usr/bin/swift", "ExecutableLocator failed to find swift in the supplied PATH")
}

private func testGuardianConfigValidationRejectsInvalidPort() throws {
    var config = GuardianConfig.default
    config.ollamaPort = 70_000

    do {
        try config.validate()
        throw VerificationFailure(message: "Config validation should reject an invalid Ollama port")
    } catch let error as GuardianRuntimeError {
        try expect(
            error == .invalidConfiguration(
                title: "Ollama Port Is Invalid",
                summary: "Ollama Port must be between 1 and 65535.",
                recovery: [
                    "Pick an unused TCP port in the valid range.",
                    "Common defaults are 11434 for Ollama, 9464 for metrics, and 9465 for the control API.",
                ]
            ),
            "Config validation returned the wrong invalid-port error"
        )
    }
}

private func testGuardianConfigValidationRejectsEmptyBearerToken() throws {
    var config = GuardianConfig.default
    config.controlBearerToken = "   "

    do {
        try config.validate()
        throw VerificationFailure(message: "Config validation should reject an empty control bearer token")
    } catch let error as GuardianRuntimeError {
        try expect(
            error == .invalidConfiguration(
                title: "Bearer Token Is Required",
                summary: "The control API must have a bearer token so remote actions stay protected.",
                recovery: [
                    "Use the Generate New Token button in Settings.",
                    "Save settings after generating the token.",
                ]
            ),
            "Config validation returned the wrong empty-token error"
        )
    }
}

private func testRuntimeSettingsIgnoreControlPlaneOnlyChanges() throws {
    let applied = GuardianConfig.default
    var saved = applied
    saved.metricsPort += 1
    saved.controlPort += 1
    saved.controlBearerToken = "different-token"

    try expect(saved.runtimeSettings == applied.runtimeSettings, "Runtime comparison should ignore metrics/control-only changes")

    saved = applied
    saved.ollamaPort += 1
    try expect(saved.runtimeSettings != applied.runtimeSettings, "Runtime comparison should detect Ollama runtime changes")
}

private func testLogMonitorParsesGinCompletionLine() throws {
    let now = Date()
    let line = "[GIN] 2026/05/16 - 14:33:01 | 200 |   742.31ms |       127.0.0.1 | POST     \"/api/generate\""
    let request = LogMonitor.parseGinCompletion(line: line, now: now)
    try expect(request != nil, "gin completion line should be parsed")
    try expect(request?.endpoint == "/api/generate", "gin endpoint should be /api/generate")
    try expect((request?.latency ?? 0) > 0.7 && (request?.latency ?? 0) < 0.8, "gin latency should round-trip to ~0.742s")
}

private func testLogMonitorMaxOverlapComputesPeakConcurrency() throws {
    let now = Date()
    let requests: [CompletedRequest] = [
        CompletedRequest(endTime: now.addingTimeInterval(-5), latency: 10, endpoint: "/api/generate"),
        CompletedRequest(endTime: now.addingTimeInterval(-3), latency: 8, endpoint: "/api/generate"),
        CompletedRequest(endTime: now.addingTimeInterval(-1), latency: 6, endpoint: "/api/generate"),
    ]
    let peak = LogMonitor.maxOverlap(requests: requests)
    try expect(peak == 3, "All three intervals overlap — peak should be 3")
}

private func testOllamaRegistryParsesModelReferences() throws {
    let (ns1, name1, tag1) = OllamaRegistryClient.parse(model: "llama3.2:1b")
    try expect(ns1 == "library" && name1 == "llama3.2" && tag1 == "1b", "library/llama3.2:1b parse failed")
    let (ns2, name2, tag2) = OllamaRegistryClient.parse(model: "mistral")
    try expect(ns2 == "library" && name2 == "mistral" && tag2 == "latest", "default tag should be latest")
    let (ns3, name3, tag3) = OllamaRegistryClient.parse(model: "myuser/my-model:custom")
    try expect(ns3 == "myuser" && name3 == "my-model" && tag3 == "custom", "namespaced model parse failed")
}

private func testApiStateSemverCompareDetectsNewerRelease() throws {
    var api = APIState.empty
    api.version = "0.5.3"
    api.latestRelease = OllamaReleaseInfo(
        latestTag: "v0.5.4",
        publishedAt: Date(),
        htmlURL: URL(string: "https://example.com")!,
        fetchedAt: Date()
    )
    try expect(api.updateAvailable, "v0.5.4 should be newer than 0.5.3")

    api.version = "0.5.4"
    try expect(!api.updateAvailable, "equal versions should not flag as update available")
}

private func testMissingOllamaIssueProvidesRecoverySteps() throws {
    let issue = GuardianRuntimeError.missingOllamaExecutable.userIssue
    try expect(issue.title == "Install Ollama First", "Missing Ollama issue should explain the install requirement")
    try expect(issue.recoverySteps.count >= 2, "Missing Ollama issue should include recovery steps")
}

private func testLogRotationTruncatesInPlaceAndKeepsGenerations() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ollama-guardian-rotation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("ollama.log").path

    // A writer holding an append handle stands in for the long-lived `ollama serve` child.
    let handle = try LogRotator.openAppendHandle(path: path)
    defer { try? handle.close() }
    let megabyte = Data(repeating: 0x41, count: 1024 * 1024)
    for _ in 0..<2 { try handle.write(contentsOf: megabyte) }

    let belowLimit = LogRotator.rotateIfNeeded(path: path, maxSizeMB: 8, maxFiles: 2)
    try expect(!belowLimit.rotated, "A 2 MB log should not rotate against an 8 MB limit")

    let first = LogRotator.rotateIfNeeded(path: path, maxSizeMB: 1, maxFiles: 2)
    try expect(first.rotated, "A 2 MB log should rotate against a 1 MB limit")

    let liveSize = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
    try expect(liveSize == 0, "The live log should be truncated to zero, got \(liveSize) bytes")
    try expect(
        FileManager.default.fileExists(atPath: "\(path).1"),
        "Rotation should leave the previous contents in ollama.log.1"
    )

    // The pre-existing append handle must keep writing into the same (now empty) inode rather
    // than leaving a sparse gap — this is what O_APPEND buys us.
    try handle.write(contentsOf: Data("after rotation\n".utf8))
    let afterWrite = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
    try expect(afterWrite == 15, "Post-rotation writes should land at offset 0, got \(afterWrite) bytes")

    // A second rotation shifts .1 to .2 and drops anything past maxFiles.
    for _ in 0..<2 { try handle.write(contentsOf: megabyte) }
    let second = LogRotator.rotateIfNeeded(path: path, maxSizeMB: 1, maxFiles: 2)
    try expect(second.rotated, "The refilled log should rotate again")
    try expect(
        FileManager.default.fileExists(atPath: "\(path).2"),
        "The older generation should have been shifted to ollama.log.2"
    )
    try expect(
        !FileManager.default.fileExists(atPath: "\(path).3"),
        "Rotation should not keep more generations than maxFiles"
    )

    let disabled = LogRotator.rotateIfNeeded(path: path, maxSizeMB: 0, maxFiles: 2)
    try expect(!disabled.rotated, "maxSizeMB of 0 should disable rotation")
}

private func testLogMonitorRecoversAfterRotation() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ollama-guardian-monitor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("ollama.log").path
    let line = "[GIN] 2026/08/13 - 10:00:00 | 200 |     742.1ms |  192.168.30.20 | POST     \"/api/generate\"\n"

    try Data(String(repeating: line, count: 3).utf8).write(to: URL(fileURLWithPath: path))
    let monitor = LogMonitor()
    let before = monitor.scan(path: path, parallelLimit: 1)
    try expect(before.inference.lastInferenceTimestamp != nil, "The first scan should observe the request")
    try expect(monitor.offset > 0, "The first scan should advance the read offset")

    // Simulate the rotation: the file is truncated underneath the monitor, then the server writes
    // fresh lines into it — so it is now shorter than the offset the monitor carried over.
    try Data().write(to: URL(fileURLWithPath: path))
    try Data(line.utf8).write(to: URL(fileURLWithPath: path))

    let after = monitor.scan(path: path, parallelLimit: 1)
    try expect(
        after.inference.lastInferenceTimestamp != nil,
        "The monitor should re-read from the top after truncation instead of flatlining"
    )
}

private func testReaperFindsOrphanedRunnersOnly() throws {
    // Real shapes taken from `ps -Ao pid=,ppid=,command=` on the Mac mini.
    let psOutput = """
    10447 1 /Applications/Ollama.app/Contents/Resources/ollama runner --mlx-engine --model gemma4:e2b-mlx --port 54607
    10459 1 /Applications/Ollama.app/Contents/Resources/llama-server --model /Users/mu/.ollama/models/blobs/sha256-970aa --port 54650
    91552 91511 /Applications/Ollama.app/Contents/Resources/llama-server --model /Users/mu/.ollama/models/blobs/sha256-712 --port 49520
    64901 91511 /Applications/Ollama.app/Contents/Resources/ollama runner --mlx-engine --model gemma4:e2b-mlx --port 51122
    91511 91503 /Applications/Ollama.app/Contents/Resources/ollama serve
    4242 1 /opt/homebrew/bin/llama-server --model /Users/mu/other/model.gguf --port 8081
    """

    let orphans = RunnerReaper.orphanedRunners(
        in: psOutput,
        runtimeDirectory: "/Applications/Ollama.app/Contents/Resources"
    )
    let pids = Set(orphans.map(\.pid))

    try expect(pids == [10447, 10459], "Should reap exactly the two launchd-parented runners, got \(pids.sorted())")
    try expect(!pids.contains(91552) && !pids.contains(64901), "Runners of a live server must never be reaped")
    try expect(!pids.contains(91511), "`ollama serve` itself must never be matched as a runner")
    try expect(!pids.contains(4242), "An unrelated llama-server outside the Ollama runtime directory must be left alone")
}

private func testReaperRejectsServeAndForeignBinaries() throws {
    let directory = "/Applications/Ollama.app/Contents/Resources"

    try expect(
        RunnerReaper.isRunnerCommand("\(directory)/ollama runner --mlx-engine --model x", runtimeDirectory: directory),
        "The MLX runner invocation should match"
    )
    try expect(
        RunnerReaper.isRunnerCommand("\(directory)/llama-server --model x", runtimeDirectory: directory),
        "The GGUF runner should match"
    )
    try expect(
        !RunnerReaper.isRunnerCommand("\(directory)/ollama serve", runtimeDirectory: directory),
        "`ollama serve` must not be treated as a runner"
    )
    try expect(
        !RunnerReaper.isRunnerCommand("/opt/homebrew/bin/ollama runner --model x", runtimeDirectory: directory),
        "A runner from a different install must not match"
    )
    try expect(
        !RunnerReaper.isRunnerCommand("/usr/bin/llama-server", runtimeDirectory: directory),
        "A same-named binary elsewhere must not match"
    )
}

@main
enum VerificationRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Settings round-trip persists warm models", testSettingsStoreRoundTripPersistsWarmModels),
            ("Log parser finds native and OpenAI endpoints", testLogParserFindsNativeAndOpenAIEndpoints),
            ("Detection flags high CPU with no inference", testDetectionTriggersOnHighCPUAndNoInference),
            ("Detection suppresses no-inference rule when logs degrade", testDetectionSkipsInferenceRuleWhenLogsAreDegraded),
            ("HTTP parser extracts bearer token", testHTTPRequestParsesBearerToken),
            ("Executable locator finds binaries in PATH", testExecutableLocatorFindsBinaryInSuppliedSearchPath),
            ("Config validation rejects invalid ports", testGuardianConfigValidationRejectsInvalidPort),
            ("Config validation rejects empty bearer tokens", testGuardianConfigValidationRejectsEmptyBearerToken),
            ("Runtime settings ignore control-plane-only changes", testRuntimeSettingsIgnoreControlPlaneOnlyChanges),
            ("Missing Ollama issue includes install guidance", testMissingOllamaIssueProvidesRecoverySteps),
            ("LogMonitor parses gin completion lines", testLogMonitorParsesGinCompletionLine),
            ("LogMonitor max overlap computes peak concurrency", testLogMonitorMaxOverlapComputesPeakConcurrency),
            ("Registry parses model references", testOllamaRegistryParsesModelReferences),
            ("APIState semver compare detects newer releases", testApiStateSemverCompareDetectsNewerRelease),
            ("Log rotation truncates in place and keeps generations", testLogRotationTruncatesInPlaceAndKeepsGenerations),
            ("LogMonitor recovers after a rotation", testLogMonitorRecoversAfterRotation),
            ("Reaper finds orphaned runners only", testReaperFindsOrphanedRunnersOnly),
            ("Reaper rejects serve and foreign binaries", testReaperRejectsServeAndForeignBinaries),
        ]

        var failures: [String] = []

        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch let error as VerificationFailure {
                failures.append("\(name): \(error.message)")
                print("FAIL \(name): \(error.message)")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                print("FAIL \(name): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            print("All \(tests.count) verification tests passed.")
        } else {
            fputs("Verification failed:\n", stderr)
            for failure in failures {
                fputs("- \(failure)\n", stderr)
            }
            exit(1)
        }
    }
}
