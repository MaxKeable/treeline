import Foundation
import Testing
@testable import treeline

struct CLIRunnerTests {

    @Test func passesArgumentsAsArrayNotShellString() async throws {
        let runner = CLIRunner()
        // /bin/echo will echo its argv joined by spaces, including ones
        // containing spaces and shell metacharacters. If they were being
        // interpreted by a shell the output would differ.
        let result = try await runner.run(
            CLIInvocation(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello world", "$HOME", "a; b"]
            )
        )
        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed == "hello world $HOME a; b")
        #expect(result.exitStatus == 0)
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        let runner = CLIRunner()
        do {
            _ = try await runner.run(
                CLIInvocation(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo boom 1>&2; exit 3"]
                )
            )
            Issue.record("expected nonZeroExit error")
        } catch let CLIError.nonZeroExit(status, stderr, _) {
            #expect(status == 3)
            #expect(stderr.contains("boom"))
        }
    }

    @Test func launchFailureSurfacesLaunchError() async throws {
        let runner = CLIRunner()
        do {
            _ = try await runner.run(
                CLIInvocation(
                    executableURL: URL(fileURLWithPath: "/definitely/not/a/binary"),
                    arguments: []
                )
            )
            Issue.record("expected launchFailed error")
        } catch CLIError.launchFailed {
            // expected
        }
    }
}
