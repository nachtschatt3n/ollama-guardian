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
        process: ProcessMetrics(pid: 1, cpuPercent: 91, residentMemoryBytes: 1_024, threadCount: 12, running: true),
        api: APIState(healthy: true, loadedModels: ["gemma4:26b"], healthFailureStreak: 0, version: "1.0.0"),
        inference: InferenceObservation(lastInferenceTimestamp: Date().addingTimeInterval(-400), lastInferenceEndpoint: "/api/generate", degraded: false),
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
        process: ProcessMetrics(pid: 1, cpuPercent: 91, residentMemoryBytes: 1_024, threadCount: 12, running: true),
        api: APIState(healthy: true, loadedModels: ["gemma4:26b"], healthFailureStreak: 0, version: "1.0.0"),
        inference: InferenceObservation(lastInferenceTimestamp: nil, lastInferenceEndpoint: nil, degraded: true),
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

private func testMissingOllamaIssueProvidesRecoverySteps() throws {
    let issue = GuardianRuntimeError.missingOllamaExecutable.userIssue
    try expect(issue.title == "Install Ollama First", "Missing Ollama issue should explain the install requirement")
    try expect(issue.recoverySteps.count >= 2, "Missing Ollama issue should include recovery steps")
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
            ("Missing Ollama issue includes install guidance", testMissingOllamaIssueProvidesRecoverySteps),
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
