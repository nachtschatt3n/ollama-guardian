import Foundation

/// Size-based rotation for the logs of the managed child processes (`ollama serve`, the TTS
/// server).
///
/// Those children inherit a write file descriptor at spawn time and hold it for their whole
/// lifetime — days or weeks. We therefore cannot rotate by renaming: the descriptor follows the
/// inode, so the child would keep writing into the renamed file and the live log would stay
/// empty forever.
///
/// Instead this uses the classic *copytruncate* strategy: copy the current contents aside, then
/// truncate the file in place so the child keeps writing to the same inode from offset 0. That
/// only works if the child's descriptor was opened `O_APPEND` (see `ManagedProcess.openLogHandle`),
/// because a plain descriptor keeps its own offset and would leave a multi-gigabyte sparse hole
/// after the truncation.
///
/// The trade-off is a small race: lines written between the copy and the truncation are lost.
/// That is acceptable for runtime logs and is what `logrotate copytruncate` does too.
enum LogRotator {
    struct Outcome: Equatable {
        var rotated: Bool
        var bytesReclaimed: UInt64
    }

    /// Rotates `path` if it grew past `maxSizeMB`, keeping `maxFiles` generations.
    ///
    /// - Returns: the outcome, or `nil` when rotation is disabled or nothing had to be done.
    @discardableResult
    static func rotateIfNeeded(path: String, maxSizeMB: Int, maxFiles: Int) -> Outcome {
        guard maxSizeMB > 0, maxFiles > 0 else { return Outcome(rotated: false, bytesReclaimed: 0) }

        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return Outcome(rotated: false, bytesReclaimed: 0)
        }

        let limit = UInt64(maxSizeMB) * 1024 * 1024
        guard size > limit else { return Outcome(rotated: false, bytesReclaimed: 0) }

        // Shift the already-rotated generations along; nothing holds a descriptor on those, so a
        // plain rename is safe. The oldest one falls off the end.
        try? fileManager.removeItem(atPath: "\(path).\(maxFiles)")
        for generation in stride(from: maxFiles - 1, through: 1, by: -1) {
            let source = "\(path).\(generation)"
            guard fileManager.fileExists(atPath: source) else { continue }
            let destination = "\(path).\(generation + 1)"
            try? fileManager.removeItem(atPath: destination)
            try? fileManager.moveItem(atPath: source, toPath: destination)
        }

        // Copy the live log aside, then truncate the original in place.
        let firstGeneration = "\(path).1"
        try? fileManager.removeItem(atPath: firstGeneration)
        do {
            try fileManager.copyItem(atPath: path, toPath: firstGeneration)
        } catch {
            return Outcome(rotated: false, bytesReclaimed: 0)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            return Outcome(rotated: false, bytesReclaimed: 0)
        }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
        } catch {
            return Outcome(rotated: false, bytesReclaimed: 0)
        }

        return Outcome(rotated: true, bytesReclaimed: size)
    }

    /// Opens a write handle in append mode, creating the file and its directory if needed.
    ///
    /// `O_APPEND` is what makes `rotateIfNeeded` safe: every write is positioned at the current
    /// end of file by the kernel, so a truncation to zero immediately takes effect for the child
    /// process instead of leaving a sparse gap.
    static func openAppendHandle(path: String) throws -> FileHandle {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else {
            throw GuardianRuntimeError.failedToOpenLogFile(path: path)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
