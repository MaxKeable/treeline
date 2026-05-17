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
protocol CLIRunning: Sendable {
    func run(_ invocation: CLIInvocation) async throws -> CLIResult
}

struct CLIRunner: CLIRunning {
    func run(_ invocation: CLIInvocation) async throws -> CLIResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(invocation)
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
}
