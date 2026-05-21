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
    /// The working tree has uncommitted changes and the action would touch
    /// it. Surfaced before any worktree-modifying git invocation runs so we
    /// never half-apply a switch or pull. The caller is expected to convert
    /// this into a user-facing message — Treeline doesn't auto-stash.
    case dirtyWorkingTree(path: String)
    /// Streaming git action exited non-zero. Carries the full output so the
    /// action sheet can show it verbatim instead of re-deriving from the
    /// stream callback.
    case actionFailed(status: Int32, output: String)
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

    /// Number of files with uncommitted changes — tracked modifications,
    /// staged changes, and untracked files. Gitignored entries don't show up
    /// in porcelain output so they're naturally excluded. Returns `0` for a
    /// clean working tree; callers use the count to render the indicator next
    /// to the current branch and to gate the Commit button.
    ///
    /// We re-parse rather than re-using `isWorkingTreeDirty` because that
    /// helper short-circuits on the first character and would force a second
    /// invocation just to get the count.
    func changedFileCount(at selectedPath: URL) async throws -> Int {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: ["status", "--porcelain"],
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            return result.standardOutput
                .split(separator: "\n", omittingEmptySubsequences: true)
                .count
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
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

    /// Run `git for-each-ref` against local heads and remote-tracking refs and
    /// return a unified list. The format is pipe-separated so we never have to
    /// escape spaces in branch or upstream names:
    ///
    ///   <HEAD marker `*` or empty>|<full refname>|<upstream short name>
    ///
    /// Symbolic remote HEAD refs (e.g. `refs/remotes/origin/HEAD`) are dropped
    /// — they're aliases for an existing entry and would otherwise show up as
    /// a duplicate row that detaches HEAD when clicked.
    func listBranches(at selectedPath: URL) async throws -> [BranchListing] {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        let format = "%(HEAD)|%(refname)|%(upstream:short)"
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: [
                "for-each-ref",
                "--format=\(format)",
                "refs/heads",
                "refs/remotes",
            ],
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.run(invocation)
            return Self.parseBranchListings(result.standardOutput)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw GitClientError.notInsideRepository(
                path: workingDirectory.path,
                underlying: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func parseBranchListings(_ output: String) -> [BranchListing] {
        var listings: [BranchListing] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            // `%(HEAD)` is "*" for the current branch and " " (space) otherwise.
            let headMarker = parts[0].trimmingCharacters(in: .whitespaces)
            let refname = String(parts[1])
            let upstreamShort = String(parts[2]).trimmingCharacters(in: .whitespaces)

            if refname.hasPrefix("refs/heads/") {
                let name = String(refname.dropFirst("refs/heads/".count))
                listings.append(BranchListing(
                    id: refname,
                    displayName: name,
                    shortName: name,
                    kind: .local,
                    upstream: upstreamShort.isEmpty ? nil : upstreamShort,
                    isCurrent: headMarker == "*"
                ))
            } else if refname.hasPrefix("refs/remotes/") {
                let rest = String(refname.dropFirst("refs/remotes/".count))
                // Remote refs are `<remote>/<branch>`. Skip the symbolic
                // `<remote>/HEAD` entry — it duplicates the real branch row.
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let remote = String(rest[..<slash])
                let branch = String(rest[rest.index(after: slash)...])
                if branch == "HEAD" { continue }
                listings.append(BranchListing(
                    id: refname,
                    displayName: rest,
                    shortName: branch,
                    kind: .remote(remote: remote),
                    upstream: nil,
                    isCurrent: false
                ))
            }
        }
        // Locals first, then remotes; both groups sorted by display name. Keeps
        // the row order stable across refreshes without re-running `for-each-ref`
        // with a specific sort key.
        return listings.sorted { lhs, rhs in
            switch (lhs.kind, rhs.kind) {
            case (.local, .remote): return true
            case (.remote, .local): return false
            default: return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    /// Spec for one user-triggered git action. Built by the dashboard layer
    /// and handed to `runAction` so we never duplicate the streaming /
    /// error-mapping boilerplate across pull/push/fetch/switch/create.
    struct ActionInvocation: Sendable {
        let arguments: [String]
        /// `true` for actions that touch the working tree (switch, pull). The
        /// caller passes the result of `isWorkingTreeDirty` down — keeping the
        /// check at the call site means tests can exercise the dirty-tree
        /// guard without stubbing every single action variant.
        let requiresCleanWorkingTree: Bool
    }

    /// Stream a user-triggered git action, surfacing every stdout/stderr line
    /// through `onLine` so the action sheet can render output live. Returns
    /// the full combined output on success; throws `actionFailed` with the
    /// captured output on non-zero exit so callers don't have to assemble it
    /// from the stream themselves.
    @discardableResult
    func runAction(
        _ action: ActionInvocation,
        at selectedPath: URL,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        if action.requiresCleanWorkingTree {
            let dirty = try await isWorkingTreeDirty(at: selectedPath)
            if dirty {
                throw GitClientError.dirtyWorkingTree(path: workingDirectory.path)
            }
        }
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: action.arguments,
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.runStreaming(invocation, onLine: onLine)
            return combinedOutput(result)
        } catch let CLIError.nonZeroExit(status, stderr, stdout) {
            throw GitClientError.actionFailed(
                status: status,
                output: combinedOutput(stdout: stdout, stderr: stderr)
            )
        } catch let CLIError.launchFailed(reason) {
            throw GitClientError.actionFailed(status: -1, output: "Failed to launch git: \(reason)")
        }
    }

    private func combinedOutput(_ result: CLIResult) -> String {
        combinedOutput(stdout: result.standardOutput, stderr: result.standardError)
    }

    private func combinedOutput(stdout: String, stderr: String) -> String {
        // git writes most progress to stderr — keep both so the sheet matches
        // what the user would see in their terminal.
        let pieces = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "\n")
    }

    /// Convenience constructors for the v1 action set. Kept on `GitClient` so
    /// the call sites read like `gitClient.fetchAction()` instead of building
    /// argument arrays by hand at every button press.
    func fetchAction() -> ActionInvocation {
        ActionInvocation(arguments: ["fetch", "--all", "--prune"], requiresCleanWorkingTree: false)
    }

    func pullAction() -> ActionInvocation {
        // No `--rebase`: per design we honour git's default merge behaviour.
        ActionInvocation(arguments: ["pull"], requiresCleanWorkingTree: true)
    }

    /// `branch` is the current local branch name. When set, the action upgrades
    /// to `push -u origin <branch>` so the first push also sets upstream — the
    /// common case for newly-created branches.
    func pushAction(currentBranch: String?, hasUpstream: Bool) -> ActionInvocation {
        if let branch = currentBranch, !hasUpstream {
            return ActionInvocation(
                arguments: ["push", "-u", "origin", branch],
                requiresCleanWorkingTree: false
            )
        }
        return ActionInvocation(arguments: ["push"], requiresCleanWorkingTree: false)
    }

    /// Composite "stage everything tracked + new, then commit" action.
    ///
    /// Runs two git invocations sequentially under one streaming session:
    ///   1. `git add -A`  — stages new, modified, and deleted files; respects
    ///                      `.gitignore` automatically so we never sweep up
    ///                      ignored junk.
    ///   2. `git commit -m <subject> [-m <body>]` — git treats the second
    ///                      `-m` as a body separated from the subject by a
    ///                      blank line, which matches conventional commit
    ///                      message formatting.
    ///
    /// Output from both calls is forwarded to `onLine` in order so the user
    /// sees the staging summary followed by the commit summary in one place.
    /// A failure in step 1 short-circuits step 2 so we never end up with a
    /// partial-stage + no-commit situation that's hard to reason about.
    @discardableResult
    func runCommit(
        subject: String,
        body: String?,
        at selectedPath: URL,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let workingDirectory = try directoryForExecution(at: selectedPath)
        // Stage everything except gitignored entries.
        try await runStreamingCommand(
            arguments: ["add", "-A"],
            workingDirectory: workingDirectory,
            onLine: onLine
        )

        // Build the commit command. Empty subject would let git launch
        // EDITOR — guard against that explicitly with a friendlier message.
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubject.isEmpty else {
            throw GitClientError.actionFailed(status: -1, output: "Commit subject is empty.")
        }
        var args: [String] = ["commit", "-m", trimmedSubject]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-m", body])
        }

        let output = try await runStreamingCommand(
            arguments: args,
            workingDirectory: workingDirectory,
            onLine: onLine
        )
        return output
    }

    /// Private helper that wraps a single streaming git invocation with the
    /// same error mapping `runAction` uses. Extracted so `runCommit` doesn't
    /// have to duplicate the do/catch ladder twice.
    @discardableResult
    private func runStreamingCommand(
        arguments: [String],
        workingDirectory: URL,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let invocation = CLIInvocation(
            executableURL: gitExecutableURL,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
        do {
            let result = try await runner.runStreaming(invocation, onLine: onLine)
            return combinedOutput(result)
        } catch let CLIError.nonZeroExit(status, stderr, stdout) {
            throw GitClientError.actionFailed(
                status: status,
                output: combinedOutput(stdout: stdout, stderr: stderr)
            )
        } catch let CLIError.launchFailed(reason) {
            throw GitClientError.actionFailed(status: -1, output: "Failed to launch git: \(reason)")
        }
    }

    /// Rename a local branch. `git branch -m <old> <new>` works whether the
    /// branch is currently checked out or not, and refuses (with a clear
    /// error surfaced in the action sheet) if `new` already exists — that's
    /// the desired safety behaviour. No `-M` (force) variant in v1: a rename
    /// that clobbers another branch is rarely what the user actually wants.
    ///
    /// Doesn't touch the working tree, so the dirty-tree guard stays off.
    func renameAction(from oldName: String, to newName: String) -> ActionInvocation {
        ActionInvocation(
            arguments: ["branch", "-m", oldName, newName],
            requiresCleanWorkingTree: false
        )
    }

    func switchAction(toLocal name: String) -> ActionInvocation {
        ActionInvocation(arguments: ["switch", name], requiresCleanWorkingTree: true)
    }

    /// Switch to a remote-tracking ref, creating (or reusing) a local branch
    /// that tracks it. `--track` together with `-c <local>` makes the call
    /// idempotent: if the local branch already exists git will error and the
    /// sheet surfaces the message rather than silently doing something
    /// surprising.
    func switchAction(toRemote ref: String, localName: String) -> ActionInvocation {
        ActionInvocation(
            arguments: ["switch", "-c", localName, "--track", ref],
            requiresCleanWorkingTree: true
        )
    }

    /// Create a new branch. When `checkout` is true we use `switch -c` so the
    /// new branch becomes HEAD; otherwise `git branch` so HEAD stays put.
    func createBranchAction(name: String, base: String?, checkout: Bool) -> ActionInvocation {
        var args: [String]
        if checkout {
            args = ["switch", "-c", name]
            if let base, !base.isEmpty { args.append(base) }
        } else {
            args = ["branch", name]
            if let base, !base.isEmpty { args.append(base) }
        }
        // Creating a branch off HEAD doesn't touch the worktree — but checking
        // it out does. Block on dirty tree only when we'd actually move HEAD.
        return ActionInvocation(arguments: args, requiresCleanWorkingTree: checkout)
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
