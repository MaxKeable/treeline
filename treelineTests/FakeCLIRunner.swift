import Foundation
@testable import treeline

/// Records every invocation it receives and returns canned results keyed by
/// the argument list. Used by GitClient and dashboard tests so we never shell
/// out during unit tests.
final class FakeCLIRunner: CLIRunning, @unchecked Sendable {
    struct Stub {
        let result: Result<CLIResult, CLIError>
    }

    private var stubs: [[String]: Stub] = [:]
    private(set) var invocations: [CLIInvocation] = []

    func stub(arguments: [String], stdout: String = "", stderr: String = "", exit: Int32 = 0) {
        stubs[arguments] = Stub(result: .success(
            CLIResult(standardOutput: stdout, standardError: stderr, exitStatus: exit)
        ))
    }

    func stubFailure(arguments: [String], error: CLIError) {
        stubs[arguments] = Stub(result: .failure(error))
    }

    func run(_ invocation: CLIInvocation) async throws -> CLIResult {
        invocations.append(invocation)
        guard let stub = stubs[invocation.arguments] else {
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
