import Foundation

/// A single CLI invocation expressed as an executable URL plus an argument
/// array. Treeline deliberately avoids shell-string execution so arguments
/// containing spaces, quotes, or other shell metacharacters cannot be
/// misinterpreted.
struct CLIInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?

    init(executableURL: URL, arguments: [String] = [], workingDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

struct CLIResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let exitStatus: Int32
}

enum CLIError: Error, Equatable {
    case nonZeroExit(status: Int32, standardError: String, standardOutput: String)
    case launchFailed(String)
}

/// Single chokepoint for `Process` execution. All git / gh invocations should
/// flow through a conforming type so behaviour can be tested with a fake.
///
/// `runStreaming` is the surface user-triggered git actions use so the action
/// sheet can render output as it arrives instead of after the process exits.
/// A default implementation is provided so test fakes that only care about the
/// batch behaviour can stay as-is — they just get a single "everything at once"
/// callback at completion time.
protocol CLIRunning: Sendable {
    func run(_ invocation: CLIInvocation) async throws -> CLIResult

    /// Run `invocation` and surface stdout/stderr lines through `onLine` as
    /// they appear. The returned `CLIResult` still carries the complete output
    /// strings for callers that need them after the fact (logging, error
    /// reporting). `onLine` is hopped onto the main actor so SwiftUI views can
    /// mutate `@Observable` state directly without an extra hop.
    func runStreaming(
        _ invocation: CLIInvocation,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CLIResult
}

extension CLIRunning {
    func runStreaming(
        _ invocation: CLIInvocation,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CLIResult {
        // Default: run to completion, then synthesize line events from the
        // captured output. Tests that don't care about timing get the same
        // final state without extra plumbing.
        let result: CLIResult
        do {
            result = try await run(invocation)
        } catch let CLIError.nonZeroExit(status, stderr, stdout) {
            await emitLines(stdout + stderr, onLine: onLine)
            throw CLIError.nonZeroExit(status: status, standardError: stderr, standardOutput: stdout)
        }
        await emitLines(result.standardOutput + result.standardError, onLine: onLine)
        return result
    }

    private func emitLines(
        _ combined: String,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async {
        for line in combined.split(separator: "\n", omittingEmptySubsequences: false) {
            let copy = String(line)
            await MainActor.run { onLine(copy) }
        }
    }
}

struct CLIRunner: CLIRunning {
    func run(_ invocation: CLIInvocation) async throws -> CLIResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(invocation)
        }.value
    }

    func runStreaming(
        _ invocation: CLIInvocation,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CLIResult {
        // The actual process work runs on a detached task so the calling
        // actor isn't blocked while git runs; readability handlers forward
        // each chunk back to the main actor as lines arrive.
        try await Task.detached(priority: .userInitiated) {
            try Self.runStreamingBlocking(invocation, onLine: onLine)
        }.value
    }

    private static func runBlocking(_ invocation: CLIInvocation) throws -> CLIResult {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        if let workingDirectory = invocation.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CLIError.launchFailed(String(describing: error))
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let status = process.terminationStatus

        if status != 0 {
            throw CLIError.nonZeroExit(
                status: status,
                standardError: stderr,
                standardOutput: stdout
            )
        }

        return CLIResult(standardOutput: stdout, standardError: stderr, exitStatus: status)
    }

    /// Streaming variant of `runBlocking`. Buffers partial chunks until a
    /// newline arrives so we never emit a half-line; flushes whatever is left
    /// in the buffer when the stream closes so callers don't miss the final
    /// terminator-less line (common with `git push`/`pull` progress output).
    private static func runStreamingBlocking(
        _ invocation: CLIInvocation,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        if let workingDirectory = invocation.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Shared mutable state across pipe handlers and the waiting thread.
        // A simple lock keeps the appends safe; the handlers are short and
        // not on a hot path so contention is negligible. Stdout / stderr each
        // carry their own line buffer so a partial chunk on one stream doesn't
        // leak its prefix into the other when emitted.
        final class Sink: @unchecked Sendable {
            var stdout = ""
            var stderr = ""
            var stdoutBuffer = ""
            var stderrBuffer = ""
            let lock = NSLock()

            enum Channel { case stdout, stderr }

            func append(
                _ data: Data,
                channel: Channel,
                onLine: @escaping @MainActor @Sendable (String) -> Void
            ) {
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                lock.lock()
                defer { lock.unlock() }
                switch channel {
                case .stdout:
                    stdout.append(chunk)
                    drain(&stdoutBuffer, chunk: chunk, onLine: onLine)
                case .stderr:
                    stderr.append(chunk)
                    drain(&stderrBuffer, chunk: chunk, onLine: onLine)
                }
            }

            private func drain(
                _ buffer: inout String,
                chunk: String,
                onLine: @escaping @MainActor @Sendable (String) -> Void
            ) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { Task { @MainActor in onLine(line) } }
                }
            }

            func flushAll(onLine: @escaping @MainActor @Sendable (String) -> Void) {
                lock.lock()
                defer { lock.unlock() }
                for pending in [stdoutBuffer, stderrBuffer] where !pending.isEmpty {
                    let line = pending
                    DispatchQueue.main.async { Task { @MainActor in onLine(line) } }
                }
                stdoutBuffer.removeAll()
                stderrBuffer.removeAll()
            }
        }

        let sink = Sink()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            sink.append(handle.availableData, channel: .stdout, onLine: onLine)
        }
        stderrHandle.readabilityHandler = { handle in
            sink.append(handle.availableData, channel: .stderr, onLine: onLine)
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw CLIError.launchFailed(String(describing: error))
        }

        process.waitUntilExit()

        // Detach the handlers and drain anything that arrived between the
        // last readability callback and exit. Without this we'd drop the
        // tail of short commands whose entire output is < one read.
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        sink.append(stdoutHandle.availableData, channel: .stdout, onLine: onLine)
        sink.append(stderrHandle.availableData, channel: .stderr, onLine: onLine)
        sink.flushAll(onLine: onLine)

        let status = process.terminationStatus
        if status != 0 {
            throw CLIError.nonZeroExit(
                status: status,
                standardError: sink.stderr,
                standardOutput: sink.stdout
            )
        }
        return CLIResult(standardOutput: sink.stdout, standardError: sink.stderr, exitStatus: status)
    }
}
