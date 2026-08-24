import Foundation

/// Cleans up Ollama model-runner processes that outlived their server.
///
/// `ollama serve` spawns one child *runner* per loaded model — `ollama runner --mlx-engine …`
/// for the MLX path, `llama-server` for the GGUF path — each holding that model's weights and
/// listening on an ephemeral localhost port. When the server is stopped abruptly (SIGKILL, a
/// crash, a machine that never got to run the termination handler) those children survive and
/// are reparented to launchd. They keep their model resident, and because `ollama ps` reports
/// only the *current* server's own runners, that memory is invisible to every normal check.
///
/// This is not hypothetical: a Guardian restart on 2026-08-13 left two runners behind, and by
/// 2026-08-24 one of them was still holding 6.2 GB for a model nothing was talking to — enough
/// to halve the live model's throughput once the box started swapping.
///
/// Port-based conflict detection does not catch these, because runners bind ephemeral ports
/// rather than the well-known Ollama port.
enum RunnerReaper {
    struct RunnerProcess: Equatable {
        var pid: Int32
        var parentPid: Int32
        var command: String
    }

    /// Parses `ps -Ao pid=,ppid=,command=` output and returns the runners that have been
    /// orphaned.
    ///
    /// Two conditions must both hold, and the pairing is what makes this safe:
    ///
    /// - The executable lives in `runtimeDirectory` — the directory of the resolved `ollama`
    ///   binary. This keeps us from touching an unrelated `llama-server` the user runs from
    ///   somewhere else.
    /// - The parent is `launchd` (pid 1). A runner whose parent is still alive belongs to a
    ///   running server — possibly one this Guardian does not manage — and must be left alone.
    static func orphanedRunners(in psOutput: String, runtimeDirectory: String) -> [RunnerProcess] {
        let directory = runtimeDirectory.hasSuffix("/") ? String(runtimeDirectory.dropLast()) : runtimeDirectory
        var found: [RunnerProcess] = []

        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let parentPid = Int32(fields[1]) else { continue }

            let command = fields.dropFirst(2).joined(separator: " ")
            guard parentPid == 1 else { continue }
            guard isRunnerCommand(command, runtimeDirectory: directory) else { continue }

            found.append(RunnerProcess(pid: pid, parentPid: parentPid, command: command))
        }

        return found
    }

    static func isRunnerCommand(_ command: String, runtimeDirectory: String) -> Bool {
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        guard (executable as NSString).deletingLastPathComponent == runtimeDirectory else { return false }

        let name = (executable as NSString).lastPathComponent
        if name == "llama-server" { return true }
        // The MLX path re-executes the ollama binary itself as `ollama runner …`; plain
        // `ollama serve` must not match.
        return name == "ollama" && command.contains(" runner")
    }

    /// Finds and terminates orphaned runners. Returns how many were killed.
    ///
    /// - Parameter ollamaPath: path to the resolved `ollama` binary; its directory is what
    ///   scopes the search.
    @discardableResult
    static func reapOrphans(ollamaPath: String, logger: FileLogger) -> Int {
        guard let psPath = ExecutableLocator.findExecutable(named: "ps", fallbackDirectories: ["/bin", "/usr/bin"]) else {
            logger.write("ps not found; skipping orphaned-runner sweep")
            return 0
        }

        // Resolve symlinks first: /usr/local/bin/ollama usually points into the app bundle,
        // and the runners are spawned from the bundle path, not the symlink.
        let resolved = URL(fileURLWithPath: ollamaPath).resolvingSymlinksInPath().path
        let runtimeDirectory = (resolved as NSString).deletingLastPathComponent

        let output: String
        do {
            output = try Shell.run(psPath, arguments: ["-Ao", "pid=,ppid=,command="])
        } catch {
            logger.write("orphaned-runner sweep failed to list processes: \(error)")
            return 0
        }

        let orphans = orphanedRunners(in: output, runtimeDirectory: runtimeDirectory)
        for orphan in orphans {
            logger.write("reaping orphaned ollama runner pid=\(orphan.pid): \(orphan.command)")
            kill(orphan.pid, SIGTERM)
        }
        guard !orphans.isEmpty else { return 0 }

        Thread.sleep(forTimeInterval: 1.0)
        for orphan in orphans where kill(orphan.pid, 0) == 0 {
            logger.write("orphaned runner pid=\(orphan.pid) ignored SIGTERM; sending SIGKILL")
            kill(orphan.pid, SIGKILL)
        }

        return orphans.count
    }

    /// Terminates the runner children of `parentPid`.
    ///
    /// Called while stopping a managed server: `ollama serve` cleans up its own runners on a
    /// graceful shutdown, but not when it has to be SIGKILLed, which is exactly when orphans
    /// are created. Collect the children *before* the parent dies — afterwards they have been
    /// reparented and the link is gone.
    @discardableResult
    static func terminateChildren(of parentPid: Int32, ollamaPath: String, logger: FileLogger) -> Int {
        guard let psPath = ExecutableLocator.findExecutable(named: "ps", fallbackDirectories: ["/bin", "/usr/bin"]) else {
            return 0
        }
        let resolved = URL(fileURLWithPath: ollamaPath).resolvingSymlinksInPath().path
        let runtimeDirectory = (resolved as NSString).deletingLastPathComponent

        guard let output = try? Shell.run(psPath, arguments: ["-Ao", "pid=,ppid=,command="]) else { return 0 }

        var children: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  ppid == parentPid else { continue }
            let command = fields.dropFirst(2).joined(separator: " ")
            guard isRunnerCommand(command, runtimeDirectory: runtimeDirectory) else { continue }
            children.append(pid)
        }

        for pid in children {
            logger.write("terminating runner child pid=\(pid) of ollama serve pid=\(parentPid)")
            kill(pid, SIGTERM)
        }
        return children.count
    }
}
