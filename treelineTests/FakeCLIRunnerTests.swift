import Foundation
import Testing
@testable import treeline

struct FakeCLIRunnerTests {
    @Test func handlesConcurrentRunsWithoutLosingInvocations() async throws {
        let runner = FakeCLIRunner()
        let arguments = ["status", "--porcelain"]
        let iterations = 300

        runner.stub(arguments: arguments, stdout: "clean\n")

        let invocation = CLIInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        try await withThrowingTaskGroup(of: CLIResult.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    try await runner.run(invocation)
                }
            }

            var resultCount = 0
            for try await result in group {
                resultCount += 1
                #expect(result.standardOutput == "clean\n")
            }

            #expect(resultCount == iterations)
        }

        #expect(runner.invocations.count == iterations)
        #expect(runner.invocations.allSatisfy { $0 == invocation })
    }
}
