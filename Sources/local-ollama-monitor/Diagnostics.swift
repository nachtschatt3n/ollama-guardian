import Foundation

enum GuardianRuntimeError: LocalizedError, Equatable {
    case invalidConfiguration(title: String, summary: String, recovery: [String])
    case missingOllamaExecutable
    case failedToPrepareLogDirectory(path: String)
    case failedToOpenLogFile(path: String)
    case managedProcessExitedEarly(details: String?)
    case apiStartupTimeout(baseURL: String)
    case listenerBindFailure(service: String, host: String, port: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(_, summary, _):
            return summary
        case .missingOllamaExecutable:
            return "Ollama is not installed or is not on PATH."
        case let .failedToPrepareLogDirectory(path):
            return "The guardian could not prepare the Ollama log directory at \(path)."
        case let .failedToOpenLogFile(path):
            return "The guardian could not open the Ollama log file at \(path)."
        case let .managedProcessExitedEarly(details):
            return details.map { "Ollama exited before becoming healthy: \($0)" } ?? "Ollama exited before becoming healthy."
        case let .apiStartupTimeout(baseURL):
            return "Timed out waiting for the Ollama API at \(baseURL)."
        case let .listenerBindFailure(service, host, port):
            return "The \(service) listener could not bind to \(host):\(port)."
        }
    }

    var userIssue: UserFacingIssue {
        switch self {
        case let .invalidConfiguration(title, summary, recovery):
            return UserFacingIssue(title: title, summary: summary, recoverySteps: recovery)
        case .missingOllamaExecutable:
            return UserFacingIssue(
                title: "Install Ollama First",
                summary: "The guardian could not find the `ollama` command, so it cannot start or manage the local runtime.",
                recoverySteps: [
                    "Install Ollama with `brew install ollama` or from the official Ollama download.",
                    "Confirm it works by running `ollama --version` in Terminal.",
                    "Relaunch Ollama Guardian after the install finishes.",
                ]
            )
        case let .failedToPrepareLogDirectory(path):
            return UserFacingIssue(
                title: "Log Directory Is Not Writable",
                summary: "The guardian could not create the folder it uses to capture Ollama logs.",
                recoverySteps: [
                    "Check that this path exists and is writable: \(path)",
                    "Choose a different managed log path in Settings if needed.",
                    "Relaunch the guardian after fixing permissions.",
                ]
            )
        case let .failedToOpenLogFile(path):
            return UserFacingIssue(
                title: "Log File Could Not Be Opened",
                summary: "The guardian could not open the managed Ollama log file for writing.",
                recoverySteps: [
                    "Verify that this file path is writable: \(path)",
                    "Remove a stale file or choose a different managed log path in Settings.",
                    "Try starting Ollama Guardian again after fixing the file permissions.",
                ]
            )
        case let .managedProcessExitedEarly(details):
            return UserFacingIssue(
                title: "Ollama Exited Immediately",
                summary: details ?? "Ollama stopped before the guardian could confirm the API was healthy.",
                recoverySteps: [
                    "Open Live Logs in the app to inspect the latest Ollama output.",
                    "Run `ollama serve` manually in Terminal to confirm the runtime starts cleanly.",
                    "If the port is already taken, change the Ollama port in Settings or stop the conflicting service.",
                ]
            )
        case let .apiStartupTimeout(baseURL):
            return UserFacingIssue(
                title: "Ollama API Did Not Come Up",
                summary: "The guardian started Ollama but did not receive a healthy response from \(baseURL) in time.",
                recoverySteps: [
                    "Open Live Logs and check for model loading or port-binding errors.",
                    "Verify the Ollama Base URL, Bind Host, and Ollama Port in Settings.",
                    "Try `curl \(baseURL)/api/version` in Terminal to confirm the API responds.",
                ]
            )
        case let .listenerBindFailure(service, host, port):
            return UserFacingIssue(
                title: "\(service) Port Is Busy",
                summary: "The guardian could not bind the \(service.lowercased()) listener on \(host):\(port).",
                recoverySteps: [
                    "Change the \(service.lowercased()) port in Settings or stop the other process using \(port).",
                    "If you are exposing the service on the network, confirm the bind host is valid for this Mac.",
                    "Save settings and reopen the app once the port conflict is resolved.",
                ]
            )
        }
    }
}

enum ExecutableLocator {
    static func findExecutable(
        named name: String,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        fallbackDirectories: [String] = []
    ) -> String? {
        let fileManager = FileManager.default

        for directory in fallbackDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        for directory in (searchPath ?? "").split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}

extension GuardianConfig {
    func validate() throws {
        let trimmedBaseURL = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmedBaseURL) != nil else {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Ollama Base URL Is Invalid",
                summary: "The Ollama Base URL must be a valid URL such as `http://127.0.0.1:11434`.",
                recovery: [
                    "Open Settings and enter a full URL that includes the scheme, host, and port.",
                    "A typical local value is `http://127.0.0.1:11434`.",
                ]
            )
        }

        try validatePort(ollamaPort, label: "Ollama Port")
        try validatePort(metricsPort, label: "Metrics Port")
        try validatePort(controlPort, label: "Control Port")

        if ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Bind Host Is Required",
                summary: "The Ollama bind host cannot be empty.",
                recovery: [
                    "Use `127.0.0.1` for local-only access or `0.0.0.0` / a LAN IP for network access.",
                ]
            )
        }

        if metricsBindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            controlBindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Bind Hosts Are Required",
                summary: "Metrics and control API bind hosts must not be empty.",
                recovery: [
                    "Use `127.0.0.1` for local-only access or `0.0.0.0` / a LAN IP for network access.",
                ]
            )
        }

        if managedLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Managed Log Path Is Required",
                summary: "The managed log path cannot be empty because the guardian stores Ollama output there.",
                recovery: [
                    "Choose a writable path in Settings, for example the default Application Support location.",
                ]
            )
        }

        if controlBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Bearer Token Is Required",
                summary: "The control API must have a bearer token so remote actions stay protected.",
                recovery: [
                    "Use the Generate New Token button in Settings.",
                    "Save settings after generating the token.",
                ]
            )
        }

        if warmModels.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "Warm Model Entries Need Names",
                summary: "Every warm model row must contain a model tag.",
                recovery: [
                    "Fill in each warm model name or remove the empty row.",
                ]
            )
        }
    }

    private func validatePort(_ port: Int, label: String) throws {
        guard (1...65_535).contains(port) else {
            throw GuardianRuntimeError.invalidConfiguration(
                title: "\(label) Is Invalid",
                summary: "\(label) must be between 1 and 65535.",
                recovery: [
                    "Pick an unused TCP port in the valid range.",
                    "Common defaults are 11434 for Ollama, 9464 for metrics, and 9465 for the control API.",
                ]
            )
        }
    }
}
