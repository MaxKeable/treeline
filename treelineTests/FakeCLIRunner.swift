import Foundation
@testable import treeline

/// Records every invocation it receives and returns canned results keyed by
/// the argument list. Used by GitClient and dashboard tests so we never shell
/// out during unit tests.
final class FakeCLIRunner: CLIRunning, @unchecked Sendable {
    struct Stub {
        let result: Result<CLIResult, CLIError>
    }

    private let lock = NSLock()
    private var stubs: [[String]: Stub] = [:]
    private var recordedInvocations: [CLIInvocation] = []

    var invocations: [CLIInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func stub(arguments: [String], stdout: String = "", stderr: String = "", exit: Int32 = 0) {
        lock.lock()
        defer { lock.unlock() }
        stubs[arguments] = Stub(result: .success(
            CLIResult(standardOutput: stdout, standardError: stderr, exitStatus: exit)
        ))
    }

    func stubFailure(arguments: [String], error: CLIError) {
        lock.lock()
        defer { lock.unlock() }
        stubs[arguments] = Stub(result: .failure(error))
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIResult {
        let stub: Stub?
        lock.lock()
        recordedInvocations.append(invocation)
        stub = stubs[invocation.arguments]
        lock.unlock()

        guard let stub else {
            throw CLIError.launchFailed("no stub for arguments \(invocation.arguments)")
        }
        switch stub.result {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
