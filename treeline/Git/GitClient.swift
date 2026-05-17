import Foundation

/// The resolved git identity for a path that lives inside a checkout or
/// worktree. `commonDirectory` is the stable Project identity per the V1 PRD;
/// `checkoutRoot` is the working tree the user originally selected.
struct GitIdentity: Equatable, Hashable, Sendable {
    let checkoutRoot: URL
    let commonDirectory: URL
}

enum GitClientError: Error, Equatable {
    case notInsideRepository(path: String, underlying: String)
    case emptyOutput(command: String)
}

/// Wraps the minimum set of `git rev-parse` calls needed to add a Project.
/// Worktree discovery, status, sync, and porcelain parsing belong in later
/// slices.
struct GitClient: Sendable {
    let runner: any CLIRunning
    let gitExecutableURL: URL

    init(runner: any CLIRunning, gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.runner = runner
        self.gitExecutableURL = gitExecutableURL
    }

    func resolveIdentity(at selectedPath: URL) async throws -> GitIdentity {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let checkoutRoot = try await revParse(["--show-toplevel"], workingDirectory: workingDirectory)
        let commonDirectory = try await revParse(["--git-common-dir"], workingDirectory: workingDirectory)

        let resolvedCheckout = Self.canonicalize(checkoutRoot)
        let resolvedCommonDirRaw: URL = commonDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirectory)
            : workingDirectory.appendingPathComponent(commonDirectory)
        let resolvedCommon = Self.canonicalize(resolvedCommonDirRaw.path)

        return GitIdentity(
            checkoutRoot: resolvedCheckout,
            commonDirectory: resolvedCommon
        )
    }

    /// Run `git rev-parse --abbrev-ref HEAD` and return the current branch
    /// name, or `nil` if HEAD is detached. Cheap enough for the dashboard.
    func currentBranch(at selectedPath: URL) async throws -> String? {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let trimmed = try await revParse(["--abbrev-ref", "HEAD"], workingDirectory: workingDirectory)
        // `--abbrev-ref HEAD` prints the literal string "HEAD" when HEAD is
        // detached. Treat that as "no branch" rather than a real branch name.
        return trimmed == "HEAD" ? nil : trimmed
    }

    /// Run `git status --porcelain` and return whether the working tree has
    /// any modifications, including untracked files. The porcelain format
    /// keeps this cheap and stable across git versions.
    func isWorkingTreeDirty(at selectedPath: URL) async throws -> Bool {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: ["status", "--porcelain"],
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Run `git worktree list --porcelain` from a path inside the repository
    /// and return every checkout/worktree git knows about, canonicalized.
    /// Bare repos (which show up as a `bare` flag with no working tree path)
    /// are skipped — Treeline only tracks paths the user can open.
    func listWorktreePaths(at selectedPath: URL) async throws -> [URL] {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            return Self.parseWorktreePaths(result.standardOutput).map { Self.canonicalize($0) }
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Parse the porcelain v1 format documented in `git-worktree(1)`. Records
    /// are blank-line separated; each starts with `worktree <path>`. We ignore
    /// every other attribute (HEAD, branch, locked, prunable) because at this
    /// slice we only need the working tree paths.
    static func parseWorktreePaths(_ porcelain: String) -> [URL] {
        var paths: [URL] = []
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("worktree ") else { continue }
            let value = String(line.dropFirst("worktree ".count))
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                paths.append(URL(fileURLWithPath: value))
            }
        }
        return paths
    }

    private func revParse(_ args: [String], workingDirectory: URL) async throws -> String {
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: ["rev-parse"] + args,
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw GitClientError.emptyOutput(command: args.joined(separator: " "))
            }
            return trimmed
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func directoryForExecution(at selectedPath: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: selectedPath.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            return selectedPath
        }
        return selectedPath.deletingLastPathComponent()
    }

    static func canonicalize(_ path: String) -> URL {
        canonicalize(URL(fileURLWithPath: path))
    }

    static func canonicalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
