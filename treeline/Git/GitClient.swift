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

    /// Run `git status --porcelain=v2 --branch --untracked-files=no` and
    /// derive how the current branch sits relative to its upstream. Porcelain
    /// v2 emits stable `# branch.*` headers that already carry the ahead/behind
    /// counts, so we get sync state in one cheap call instead of a separate
    /// rev-list walk. Returns `nil` when the headers are unparseable (e.g. an
    /// empty repository) so the caller can render "unknown" without throwing.
    func branchSync(at selectedPath: URL) async throws -> BranchSync? {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            return Self.parseBranchSync(result.standardOutput)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Parse the `# branch.*` headers emitted by `git status --porcelain=v2
    /// --branch`. Documented in `git-status(1)`:
    ///
    ///   # branch.head <name>     — branch name, or `(detached)` for detached HEAD
    ///   # branch.upstream <name> — present only when an upstream is configured
    ///   # branch.ab +<a> -<b>    — present only alongside branch.upstream
    ///
    /// We ignore file entries and `# branch.oid` because none of them affect
    /// sync state.
    static func parseBranchSync(_ porcelain: String) -> BranchSync? {
        var head: String?
        var hasUpstream = false
        var ahead: Int?
        var behind: Int?

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                head = String(line.dropFirst("# branch.head ".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# branch.upstream ") {
                hasUpstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let value = String(line.dropFirst("# branch.ab ".count))
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                // Format is `+<ahead> -<behind>`; strip the sign before parsing
                // so a malformed stream falls through to .unknown rather than
                // pretending a count of zero.
                let aheadPart = parts[0].hasPrefix("+") ? parts[0].dropFirst() : parts[0]
                let behindPart = parts[1].hasPrefix("-") ? parts[1].dropFirst() : parts[1]
                ahead = Int(aheadPart)
                behind = Int(behindPart)
            }
        }

        guard let head else { return nil }
        if head == "(detached)" { return .detached }
        if !hasUpstream { return .noUpstream }
        guard let ahead, let behind else { return nil }

        switch (ahead, behind) {
        case (0, 0): return .upToDate
        case (let a, 0) where a > 0: return .ahead(a)
        case (0, let b) where b > 0: return .behind(b)
        case (let a, let b) where a > 0 && b > 0: return .diverged(ahead: a, behind: b)
        default: return nil
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
