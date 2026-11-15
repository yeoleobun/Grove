import Foundation

public struct GitPorcelainWorktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool = false
    public var isDetached: Bool = false
    public var isLocked: Bool = false
    public var lockReason: String?
    public var isPrunable: Bool = false
    public var prunableReason: String?

    public init(path: String) {
        self.path = PathNormalizer.canonicalPath(path)
    }
}

public enum PathNormalizer {
    public static func canonicalPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            return parent.resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
                .standardizedFileURL.path
        }
        return url.standardizedFileURL.path
    }
}

public enum LinkedWorktreeRemovalMode: String, CaseIterable, Sendable {
    case gitWorktreeRemove
    case trashSourceAndPrune

    public var title: String {
        switch self {
        case .gitWorktreeRemove:
            return "Standard Git Remove (`git worktree remove`)"
        case .trashSourceAndPrune:
            return "Move Worktree Folder to Trash & Prune Git"
        }
    }
}

public struct WorktreeRemovalOptions: Sendable {
    public var mode: LinkedWorktreeRemovalMode
    public var forceIfDirtyOrLocked: Bool
    public var deleteLocalBranch: Bool
    public var forceDeleteBranch: Bool
    public var preserveCommits: Bool

    public init(
        mode: LinkedWorktreeRemovalMode = .gitWorktreeRemove,
        forceIfDirtyOrLocked: Bool = false,
        deleteLocalBranch: Bool = false,
        forceDeleteBranch: Bool = false,
        preserveCommits: Bool = false
    ) {
        self.mode = mode
        self.forceIfDirtyOrLocked = forceIfDirtyOrLocked
        self.deleteLocalBranch = deleteLocalBranch
        self.forceDeleteBranch = forceDeleteBranch
        self.preserveCommits = preserveCommits
    }
}

public struct ProjectRemovalOptions: Sendable {
    public var removeLinkedWorktrees: Bool

    public init(removeLinkedWorktrees: Bool = true) {
        self.removeLinkedWorktrees = removeLinkedWorktrees
    }
}

public enum GitWorktreeError: LocalizedError {
    case dirtyWorktreeRequiresConfirmation(path: String, count: Int)
    case lockedWorktreeRequiresConfirmation(path: String, reason: String?)
    case emptyCommitMessage
    case cannotCommitConflicts
    case detachedHeadCannotPush
    case noRemoteConfigured
    case branchRequiresForceDelete(branch: String, gitStderr: String)
    case gitCommandFailed(message: String)
    case cannotUseWorktreeRemoveOnMainCheckout

    public var errorDescription: String? {
        switch self {
        case let .dirtyWorktreeRequiresConfirmation(path, count):
            return "Worktree at '\(path)' has \(count) uncommitted file(s). Confirm force removal or move to Trash."
        case let .lockedWorktreeRequiresConfirmation(path, reason):
            if let reason, !reason.isEmpty {
                return "Worktree at '\(path)' is locked (\(reason))."
            }
            return "Worktree at '\(path)' is locked."
        case .emptyCommitMessage:
            return "Please enter a commit message."
        case .cannotCommitConflicts:
            return "This checkout has unresolved merge conflicts. Please resolve them in your code editor before committing."
        case .detachedHeadCannotPush:
            return "This checkout is on a detached commit with no branch name to push."
        case .noRemoteConfigured:
            return "No Git remote (such as 'origin') is configured for this repository."
        case let .branchRequiresForceDelete(branch, _):
            return "Branch '\(branch)' requires confirmation to force delete (`git branch -D`)."
        case let .gitCommandFailed(message):
            return message
        case .cannotUseWorktreeRemoveOnMainCheckout:
            return "The main repository checkout cannot be removed as a linked worktree; remove the project instead."
        }
    }
}

public struct PreferredGitBase: Sendable {
    public let hasRemote: Bool
    public let remoteBase: String?
    public let localBase: String?

    public init(hasRemote: Bool = false, remoteBase: String? = nil, localBase: String? = nil) {
        self.hasRemote = hasRemote
        self.remoteBase = remoteBase
        self.localBase = localBase
    }
}

public struct StatusAndUpstreamSnapshot: Sendable {
    public let status: GitWorkingTreeStatus
    public let upstreamRef: String?
    public let unpushedCount: Int
    public let behindUpstreamCount: Int
}

public enum GitWorktreeService {
    private static let conflictCodes: Set<String> = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]

    /// Finds the enclosing git working tree root for `path` (if any) by walking ancestors for `.git`.
    public static func enclosingWorktreeRoot(for path: String) -> String? {
        var current = PathNormalizer.canonicalPath(path)
        let fm = FileManager.default

        while true {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current {
                return nil
            }
            current = parent
        }
    }

    /// Resolves the canonical git common directory (`.git` of the main repo) in pure Swift
    /// without spawning a `git` subprocess whenever standard `.git` layout is present.
    public static func resolveGitCommonDir(for worktreeRoot: String) -> String? {
        let dotGit = (worktreeRoot as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else {
            return nil
        }

        if isDir.boolValue {
            return PathNormalizer.canonicalPath(dotGit)
        }

        if let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("gitdir:") {
                let rawGitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let resolvedGitDir = rawGitDir.hasPrefix("/")
                    ? rawGitDir
                    : (worktreeRoot as NSString).appendingPathComponent(rawGitDir)

                let commonDirFile = (resolvedGitDir as NSString).appendingPathComponent("commondir")
                if let relCommon = try? String(contentsOfFile: commonDirFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !relCommon.isEmpty {
                    let fullCommon = relCommon.hasPrefix("/")
                        ? relCommon
                        : (resolvedGitDir as NSString).appendingPathComponent(relCommon)
                    return PathNormalizer.canonicalPath(fullCommon)
                }

                return PathNormalizer.canonicalPath(resolvedGitDir)
            }
        }

        if let result = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreeRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"]
        ), result.succeeded {
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return PathNormalizer.canonicalPath(trimmed)
            }
        }
        return nil
    }

    /// Lists all worktrees belonging to the git repository at `repoPath`.
    /// Uses a zero-subprocess fast path when the repo has no `.git/worktrees` entries.
    public static func listWorktrees(for repoPath: String, gitCommonDir: String? = nil) -> [GitPorcelainWorktree] {
        if let commonDir = gitCommonDir,
           (commonDir as NSString).lastPathComponent == ".git" {
            let worktreesMetaDir = (commonDir as NSString).appendingPathComponent("worktrees")
            let hasLinkedEntries = ((try? FileManager.default.contentsOfDirectory(atPath: worktreesMetaDir))?.isEmpty == false)
            if !hasLinkedEntries {
                let mainRoot = (commonDir as NSString).deletingLastPathComponent
                let headInfo = readHeadFast(dotGitDir: commonDir)
                var single = GitPorcelainWorktree(path: mainRoot)
                single.branch = headInfo.branch
                single.head = headInfo.shortSHA
                single.isDetached = headInfo.isDetached
                return [single]
            }
        }

        guard let result = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", repoPath, "worktree", "list", "--porcelain"]
        ), result.succeeded else {
            return []
        }
        return parsePorcelainOutput(result.stdout)
    }

    private static func readHeadFast(dotGitDir: String) -> (branch: String?, shortSHA: String?, isDetached: Bool) {
        let headPath = (dotGitDir as NSString).appendingPathComponent("HEAD")
        guard let headRaw = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !headRaw.isEmpty else {
            return (nil, nil, false)
        }

        if headRaw.hasPrefix("ref: ") {
            let ref = String(headRaw.dropFirst("ref: ".count))
            let branch = ref.hasPrefix("refs/heads/")
                ? String(ref.dropFirst("refs/heads/".count))
                : ref
            let refPath = (dotGitDir as NSString).appendingPathComponent(ref)
            let sha = (try? String(contentsOfFile: refPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shortSHA = sha.map { String($0.prefix(7)) }
            return (branch, shortSHA, false)
        } else {
            return (nil, String(headRaw.prefix(7)), true)
        }
    }

    public static func parsePorcelainOutput(_ output: String) -> [GitPorcelainWorktree] {
        var items: [GitPorcelainWorktree] = []
        var current: GitPorcelainWorktree?

        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                if let entry = current {
                    items.append(entry)
                    current = nil
                }
                continue
            }

            if line.hasPrefix("worktree ") {
                if let entry = current {
                    items.append(entry)
                }
                let rawPath = String(line.dropFirst("worktree ".count))
                current = GitPorcelainWorktree(path: rawPath)
            } else if line.hasPrefix("HEAD ") {
                let sha = String(line.dropFirst("HEAD ".count))
                current?.head = sha
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "bare" {
                current?.isBare = true
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "locked" {
                current?.isLocked = true
            } else if line.hasPrefix("locked ") {
                current?.isLocked = true
                current?.lockReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                current?.isPrunable = true
            } else if line.hasPrefix("prunable ") {
                current?.isPrunable = true
                current?.prunableReason = String(line.dropFirst("prunable ".count))
            }
        }

        if let entry = current {
            items.append(entry)
        }
        return items
    }

    /// Inspects both working-tree dirty state (`staged`, `modified`, `untracked`, `conflict`) AND
    /// remote upstream tracking (`ahead` / `behind`) in a single `git status --porcelain=v1 --branch` invocation.
    public static func inspectStatusAndUpstream(at worktreePath: String) -> StatusAndUpstreamSnapshot {
        guard FileManager.default.fileExists(atPath: worktreePath) else {
            return StatusAndUpstreamSnapshot(
                status: GitWorkingTreeStatus(inspectionError: "Working directory is unavailable."),
                upstreamRef: nil,
                unpushedCount: 0,
                behindUpstreamCount: 0
            )
        }

        let args = [
            "--no-optional-locks",
            "-C", worktreePath,
            "status",
            "--porcelain=v1",
            "--branch",
            "--untracked-files=all",
            "--ignored=matching",
            "-z"
        ]

        guard let result = try? ShellRunner.run(executable: "git", arguments: args),
              result.succeeded else {
            return StatusAndUpstreamSnapshot(
                status: GitWorkingTreeStatus(inspectionError: "Git status failed. Cleanup is blocked until inspection succeeds."),
                upstreamRef: nil,
                unpushedCount: 0,
                behindUpstreamCount: 0
            )
        }

        var upstreamRef: String?
        var ahead = 0
        var behind = 0

        var ignoredCount = 0
        var stagedCount = 0
        var modifiedCount = 0
        var untrackedCount = 0
        var conflictCount = 0
        var sampleFiles: [String] = []

        var skipRenameSource = false
        for line in result.stdout.components(separatedBy: "\0") where !line.isEmpty {
            if skipRenameSource { skipRenameSource = false; continue }
            if line.hasPrefix("## ") {
                let parsed = parseBranchStatusHeader(String(line.dropFirst(3)))
                upstreamRef = parsed.upstreamRef
                ahead = parsed.ahead
                behind = parsed.behind
                continue
            }

            guard line.count >= 4 else { continue }
            let xy = String(line.prefix(2))
            let chars = Array(xy)
            let x = chars[0]
            let y = chars[1]

            skipRenameSource = x == "R" || x == "C" || y == "R" || y == "C"
            if xy == "!!" {
                ignoredCount += 1
            } else if conflictCodes.contains(xy) {
                conflictCount += 1
            } else if xy == "??" {
                untrackedCount += 1
            } else if y != " " {
                modifiedCount += 1
            } else if x != " " {
                stagedCount += 1
            } else {
                continue
            }

            if sampleFiles.count < 30 {
                sampleFiles.append(line)
            }
        }

        let status = GitWorkingTreeStatus(
            ignoredCount: ignoredCount,
            stagedCount: stagedCount,
            modifiedCount: modifiedCount,
            untrackedCount: untrackedCount,
            conflictCount: conflictCount,
            sampleFiles: sampleFiles
        )

        return StatusAndUpstreamSnapshot(
            status: status,
            upstreamRef: upstreamRef,
            unpushedCount: ahead,
            behindUpstreamCount: behind
        )
    }

    public static func parseBranchStatusHeader(
        _ header: String
    ) -> (upstreamRef: String?, ahead: Int, behind: Int) {
        guard let dotsRange = header.range(of: "...") else {
            return (nil, 0, 0)
        }

        let afterDots = String(header[dotsRange.upperBound...])
        if let bracketStart = afterDots.range(of: " ["),
           afterDots.hasSuffix("]") {
            let upstream = String(afterDots[..<bracketStart.lowerBound]).trimmingCharacters(in: .whitespaces)
            let innerStart = bracketStart.upperBound
            let innerEnd = afterDots.index(before: afterDots.endIndex)
            let inner = String(afterDots[innerStart..<innerEnd])

            if inner == "gone" {
                return (nil, 0, 0)
            }

            var ahead = 0
            var behind = 0
            for token in inner.components(separatedBy: ",") {
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead "),
                   let n = Int(trimmed.dropFirst("ahead ".count)) {
                    ahead = n
                } else if trimmed.hasPrefix("behind "),
                          let n = Int(trimmed.dropFirst("behind ".count)) {
                    behind = n
                }
            }
            return (upstream.isEmpty ? nil : upstream, ahead, behind)
        } else {
            let upstream = afterDots.trimmingCharacters(in: .whitespaces)
            return (upstream.isEmpty ? nil : upstream, 0, 0)
        }
    }

    /// Resolves the repository's preferred comparison base (`origin/main` if remote exists, plus local `main`/`master`)
    /// and whether a Git remote is configured.
    public static func resolvePreferredBase(in repoPath: String, gitCommonDir: String? = nil) -> PreferredGitBase {
        if let configured = try? ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "config", "--get", "grove.integrationTarget"]), configured.succeeded {
            let target = configured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                return PreferredGitBase(remoteBase: target)
            }
        }
        var hasRemote = false
        if let commonDir = gitCommonDir {
            let configPath = (commonDir as NSString).appendingPathComponent("config")
            if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8),
               cfg.contains("[remote ") {
                hasRemote = true
            }
        }

        guard let result = try? ShellRunner.run(
            executable: "git",
            arguments: [
                "--no-optional-locks",
                "-C", repoPath,
                "for-each-ref",
                "--format=%(refname:short)\t%(symref:short)",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
                "refs/remotes/origin/master",
                "refs/heads/main",
                "refs/heads/master"
            ]
        ), result.succeeded else {
            return PreferredGitBase(hasRemote: hasRemote)
        }

        var availableRefs = Set<String>()
        var originHeadTarget: String?

        for line in result.stdout.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let ref = parts[0]
            availableRefs.insert(ref)
            if ref.hasPrefix("origin/") || ref == "origin" {
                hasRemote = true
            }
            if ref == "origin/HEAD" || ref == "origin" {
                if parts.count > 1, !parts[1].isEmpty {
                    originHeadTarget = parts[1]
                }
            }
        }

        let remoteBase: String?
        if let target = originHeadTarget, target != "origin/HEAD" {
            remoteBase = target
        } else if availableRefs.contains("origin/main") {
            remoteBase = "origin/main"
        } else if availableRefs.contains("origin/master") {
            remoteBase = "origin/master"
        } else {
            remoteBase = nil
        }

        let localBase: String?
        if availableRefs.contains("main") {
            localBase = "main"
        } else if availableRefs.contains("master") {
            localBase = "master"
        } else {
            localBase = nil
        }

        return PreferredGitBase(hasRemote: hasRemote, remoteBase: remoteBase, localBase: localBase)
    }

    public static func setIntegrationTarget(_ target: String, in repoPath: String) throws {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            throw GitWorktreeError.gitCommandFailed(message: "Enter a branch or remote-tracking ref, such as main or origin/main.")
        }
        let resolved = try ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "rev-parse", "--verify", "--end-of-options", trimmed + "^{commit}"])
        guard resolved.succeeded else { throw GitWorktreeError.gitCommandFailed(message: "Integration target does not resolve to a commit.") }
        let saved = try ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "config", "grove.integrationTarget", trimmed])
        guard saved.succeeded else { throw GitWorktreeError.gitCommandFailed(message: "Could not save integration target.") }
    }

    /// Computes ahead/behind commit counts, squash-merge state, and unmerged/unpushed commit summaries.
    public static func inspectBranchComparison(
        at worktreePath: String,
        kind: WorktreeKind,
        branchName: String?,
        upstreamRef: String?,
        unpushedCount: Int,
        behindUpstreamCount: Int,
        preferredBase: PreferredGitBase
    ) -> GitBranchComparison? {
        guard kind != .prunable, FileManager.default.fileExists(atPath: worktreePath) else {
            return nil
        }

        let lastCommit = parseCommitsOutput(
            (try? ShellRunner.run(
                executable: "git",
                arguments: ["--no-optional-locks", "-C", worktreePath, "log", "-1", "--format=%h\t%s\t%cr\t%ct"]
            ))?.stdout ?? ""
        ).first

        let hasRemote = preferredBase.hasRemote || upstreamRef != nil

        let candidateBase: String?
        if let remote = preferredBase.remoteBase {
            candidateBase = remote
        } else if let local = preferredBase.localBase, branchName != local {
            candidateBase = local
        } else {
            candidateBase = nil
        }

        guard let baseRef = candidateBase else {
            var unpushedCommits: [GitCommitSummary] = []
            if unpushedCount > 0, let upstreamRef {
                unpushedCommits = fetchRecentCommits(at: worktreePath, range: "\(upstreamRef)..HEAD")
            }
            return GitBranchComparison(
                hasRemote: hasRemote,
                upstreamRef: upstreamRef,
                unpushedCount: unpushedCount,
                behindUpstreamCount: behindUpstreamCount,
                baseRef: nil,
                aheadOfBaseCount: 0,
                behindBaseCount: 0,
                isSquashMergedIntoBase: false,
                unmergedCommits: unpushedCommits,
                lastCommit: lastCommit
            )
        }

        guard let countRes = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "rev-list", "--left-right", "--count", "\(baseRef)...HEAD"]
        ), countRes.succeeded else {
            return GitBranchComparison(
                hasRemote: hasRemote,
                upstreamRef: upstreamRef,
                unpushedCount: unpushedCount,
                behindUpstreamCount: behindUpstreamCount,
                baseRef: nil,
                aheadOfBaseCount: 0,
                behindBaseCount: 0,
                isSquashMergedIntoBase: false,
                unmergedCommits: [],
                lastCommit: lastCommit
            )
        }

        let nums = countRes.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .compactMap { Int($0) }

        guard nums.count == 2 else { return nil }
        let behind = nums[0]
        let ahead = nums[1]

        var isSquashMerged = false
        var unmerged: [GitCommitSummary] = []

        if ahead > 0 {
            if kind == .linked {
                isSquashMerged = isBranchMergedViaTree(at: worktreePath, baseRef: baseRef)
            }
            if !isSquashMerged {
                unmerged = fetchRecentCommits(at: worktreePath, range: "\(baseRef)..HEAD")
            }
        } else if unpushedCount > 0, let upstreamRef {
            unmerged = fetchRecentCommits(at: worktreePath, range: "\(upstreamRef)..HEAD")
        }

        return GitBranchComparison(
            hasRemote: hasRemote,
            upstreamRef: upstreamRef,
            unpushedCount: unpushedCount,
            behindUpstreamCount: behindUpstreamCount,
            baseRef: baseRef,
            aheadOfBaseCount: ahead,
            behindBaseCount: behind,
            isSquashMergedIntoBase: isSquashMerged,
            unmergedCommits: unmerged,
            lastCommit: lastCommit
        )
    }

    private static func fetchRecentCommits(at worktreePath: String, range: String) -> [GitCommitSummary] {
        guard let logRes = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "log", range, "-n", "10", "--format=%h\t%s\t%cr\t%ct"]
        ), logRes.succeeded else {
            return []
        }
        return parseCommitsOutput(logRes.stdout)
    }

    /// Detects squash-merged or rebase-merged branches/worktrees in ~2 ms with zero working-tree or index side effects:
    /// runs an in-memory 3-way merge (`git merge-tree --write-tree <baseRef> <branchRef>`) and checks whether the resulting
    /// root tree OID is identical to `<baseRef>^{tree}`.
    public static func isBranchMergedViaTree(
        at worktreePath: String,
        baseRef: String,
        branchRef: String = "HEAD",
        cachedBaseTreeOID: String? = nil
    ) -> Bool {
        let baseTreeOID: String
        if let cachedBaseTreeOID, !cachedBaseTreeOID.isEmpty {
            baseTreeOID = cachedBaseTreeOID
        } else {
            guard let baseTreeRes = try? ShellRunner.run(
                executable: "git",
                arguments: ["--no-optional-locks", "-C", worktreePath, "rev-parse", "--verify", "\(baseRef)^{tree}"]
            ), baseTreeRes.succeeded else {
                return false
            }
            baseTreeOID = baseTreeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !baseTreeOID.isEmpty else { return false }

        guard let mergeRes = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "merge-tree", "--write-tree", baseRef, branchRef]
        ), mergeRes.succeeded else {
            return false
        }
        let mergedTreeOID = mergeRes.stdout
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return !mergedTreeOID.isEmpty && mergedTreeOID == baseTreeOID
    }

    private static func parseCommitsOutput(_ raw: String) -> [GitCommitSummary] {
        var commits: [GitCommitSummary] = []
        for line in raw.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let commitDate: Date?
            if parts.count >= 4, let unixSec = TimeInterval(parts[3]), unixSec > 0 {
                commitDate = Date(timeIntervalSince1970: unixSec)
            } else {
                commitDate = nil
            }
            commits.append(
                GitCommitSummary(
                    shortHash: parts[0],
                    subject: parts[1],
                    relativeTime: parts[2],
                    committedAt: commitDate
                )
            )
        }
        return commits
    }

    // MARK: - Basic Git Actions (Commit & Push)

    /// Stages all changes (`git add -A`) and creates a commit in `worktreePath`, optionally pushing right afterward.
    public static func commitChanges(
        at worktreePath: String,
        message: String,
        pushAfterCommit: Bool = false
    ) throws -> (commitHash: String?, pushedDestination: String?) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw GitWorktreeError.emptyCommitMessage
        }

        let live = inspectStatusAndUpstream(at: worktreePath)
        if live.status.conflictCount > 0 {
            throw GitWorktreeError.cannotCommitConflicts
        }

        let addResult = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", worktreePath, "add", "-A"]
        )
        if !addResult.succeeded {
            let err = addResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.gitCommandFailed(message: err.isEmpty ? "git add -A failed." : err)
        }

        let commitResult = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", worktreePath, "commit", "-m", trimmedMessage]
        )
        if !commitResult.succeeded {
            let err = commitResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = commitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.gitCommandFailed(
                message: !err.isEmpty ? err : (!out.isEmpty ? out : "git commit failed.")
            )
        }

        let shortHash = (try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "rev-parse", "--short", "HEAD"]
        ))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var pushedDest: String?
        if pushAfterCommit {
            pushedDest = try pushChanges(at: worktreePath)
        }

        return (shortHash, pushedDest)
    }

    /// Pushes local commits in `worktreePath` to its tracked upstream, or automatically sets `--set-upstream <remote> <branch>`
    /// when pushing a new branch for the first time.
    public static func pushChanges(at worktreePath: String) throws -> String {
        let branchRes = try ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "symbolic-ref", "--short", "HEAD"]
        )
        let branch = branchRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branchRes.succeeded, !branch.isEmpty else {
            throw GitWorktreeError.detachedHeadCannotPush
        }

        let live = inspectStatusAndUpstream(at: worktreePath)
        if let upstream = live.upstreamRef, !upstream.isEmpty {
            let pushRes = try ShellRunner.run(
                executable: "git",
                arguments: ["-C", worktreePath, "push"]
            )
            if !pushRes.succeeded {
                let err = pushRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitWorktreeError.gitCommandFailed(message: err.isEmpty ? "git push failed." : err)
            }
            return upstream
        }

        // Branch has no upstream yet — pick `origin` (or the first configured remote) and push with `-u`
        let remotesRes = try ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "remote"]
        )
        let remotes = remotesRes.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw GitWorktreeError.noRemoteConfigured
        }

        let pushRes = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", worktreePath, "push", "--set-upstream", remote, branch]
        )
        if !pushRes.succeeded {
            let err = pushRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.gitCommandFailed(message: err.isEmpty ? "git push --set-upstream failed." : err)
        }
        return "\(remote)/\(branch)"
    }

    /// Fetches from `origin` (or the first configured remote) with `--prune` so remote-tracking refs
    /// and deleted PR branches (`[gone]`) are brought up to date.
    public static func fetchFromRemote(at repoPath: String) throws -> String {
        let remotesRes = try ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", repoPath, "remote"]
        )
        let remotes = remotesRes.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw GitWorktreeError.noRemoteConfigured
        }

        let fetchRes = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", repoPath, "fetch", "--prune", remote]
        )
        if !fetchRes.succeeded {
            let err = fetchRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.gitCommandFailed(message: err.isEmpty ? "git fetch --prune \(remote) failed." : err)
        }
        return remote
    }

    /// Deletes a local Git branch (`-d` for safe ancestor-merged, `-D` only when explicitly force-confirmed).
    public static func deleteLocalBranchNamed(_ branch: String, in repoPath: String, force: Bool) throws {
        let preferred = resolvePreferredBase(in: repoPath)
        let target = preferred.remoteBase ?? preferred.localBase
        let protectedName = target?.replacingOccurrences(of: "refs/heads/", with: "")
        guard branch != "main", branch != "master", branch != protectedName,
              target != "origin/" + branch else {
            throw GitWorktreeError.gitCommandFailed(message: "The integration branch is protected.")
        }
        guard !listWorktrees(for: repoPath).contains(where: { $0.branch == branch }) else {
            throw GitWorktreeError.gitCommandFailed(message: "This branch is checked out in a worktree.")
        }
        let resolved = try ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "rev-parse", "--verify", "refs/heads/" + branch])
        guard resolved.succeeded else { throw GitWorktreeError.gitCommandFailed(message: "Branch no longer exists.") }
        let head = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var contained = false
        if let target {
            contained = try ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "merge-base", "--is-ancestor", head, target]).succeeded
        }
        if !contained {
            guard force else { throw GitWorktreeError.branchRequiresForceDelete(branch: branch, gitStderr: "Commits are not contained in the integration target.") }
            let saved = try ShellRunner.run(executable: "git", arguments: ["-C", repoPath, "update-ref", "refs/grove/rescued/" + UUID().uuidString.lowercased(), head])
            guard saved.succeeded else { throw GitWorktreeError.gitCommandFailed(message: "Cannot preserve branch commits; deletion blocked.") }
        }
        let flag = force ? "-D" : "-d"
        let res = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", repoPath, "branch", flag, branch]
        )
        if !res.succeeded {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !force && (msg.localizedCaseInsensitiveContains("not fully merged") || msg.localizedCaseInsensitiveContains("not deleting branch")) {
                throw GitWorktreeError.branchRequiresForceDelete(branch: branch, gitStderr: msg)
            }
            throw GitWorktreeError.gitCommandFailed(
                message: msg.isEmpty ? "git branch \(flag) \(branch) failed." : msg
            )
        }
    }

    // MARK: - Safe Removals

    /// Safely removes a linked Git worktree and prunes Git metadata. Returns any non-fatal warnings.
    public static func removeLinkedWorktree(
        _ worktree: WorktreeItem,
        in project: ProjectGroup,
        options: WorktreeRemovalOptions
    ) throws -> [String] {
        guard worktree.kind == .linked || worktree.kind == .prunable else {
            throw GitWorktreeError.cannotUseWorktreeRemoveOnMainCheckout
        }

        let mainRepoPath = project.primaryPath
        var warnings: [String] = []

        let liveEntries = listWorktrees(for: mainRepoPath)
        guard let entry = liveEntries.first(where: { $0.path == PathNormalizer.canonicalPath(worktree.path) }),
              entry.path != PathNormalizer.canonicalPath(project.primaryPath), !entry.isBare else {
            throw GitWorktreeError.gitCommandFailed(message: "Worktree registration changed. Refresh before removing it.")
        }
        if entry.isLocked && !options.forceIfDirtyOrLocked {
            throw GitWorktreeError.lockedWorktreeRequiresConfirmation(path: entry.path, reason: entry.lockReason)
        }
        let missing = !FileManager.default.fileExists(atPath: entry.path)
        let liveStatus = inspectStatusAndUpstream(at: entry.path).status
        if !missing {
            if let error = liveStatus.inspectionError {
                throw GitWorktreeError.gitCommandFailed(message: error)
            }
            if !liveStatus.isClean && !options.forceIfDirtyOrLocked && options.mode == .gitWorktreeRemove {
                throw GitWorktreeError.dirtyWorktreeRequiresConfirmation(path: entry.path, count: liveStatus.totalChangedCount)
            }
            if liveStatus.ignoredCount > 0 && options.mode == .gitWorktreeRemove {
                throw GitWorktreeError.gitCommandFailed(message: "Ignored files are present. Move the folder to Trash to preserve local data.")
            }
        }
        guard let head = entry.head else {
            throw GitWorktreeError.gitCommandFailed(message: "Cannot verify worktree HEAD. Removal blocked.")
        }
        let preferred = resolvePreferredBase(in: mainRepoPath, gitCommonDir: project.gitCommonDir)
        let base = preferred.remoteBase ?? preferred.localBase
        let contained: Bool
        if let base {
            let check = try ShellRunner.run(executable: "git", arguments: ["-C", mainRepoPath, "merge-base", "--is-ancestor", head, base])
            contained = check.succeeded
        } else {
            contained = false
        }
        if !contained {
            guard options.preserveCommits else {
                throw GitWorktreeError.gitCommandFailed(message: "HEAD is not verified in the integration target. Choose Preserve commits before removing this worktree.")
            }
            let rescue = "refs/grove/rescued/" + UUID().uuidString.lowercased()
            let saved = try ShellRunner.run(executable: "git", arguments: ["-C", mainRepoPath, "update-ref", rescue, head])
            guard saved.succeeded else {
                throw GitWorktreeError.gitCommandFailed(message: "Could not preserve commits. Nothing was removed.")
            }
            warnings.append("Commits preserved at \(rescue). Recover with git branch recovered \(rescue).")
        }
        if missing {
            try pruneWorktrees(in: mainRepoPath, unlockPathIfNeeded: entry.isLocked ? entry.path : nil)
            return warnings
        }

        let currentHead = try ShellRunner.run(executable: "git", arguments: ["-C", entry.path, "rev-parse", "HEAD"])
        guard currentHead.succeeded, currentHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            throw GitWorktreeError.gitCommandFailed(message: "HEAD changed during cleanup. Refresh and review again.")
        }
        if entry.isLocked {
            _ = try? ShellRunner.run(
                executable: "git",
                arguments: ["-C", mainRepoPath, "worktree", "unlock", worktree.path]
            )
        }

        switch options.mode {
        case .gitWorktreeRemove:
            var args = ["-C", mainRepoPath, "worktree", "remove"]
            if options.forceIfDirtyOrLocked || !liveStatus.isClean {
                args.append("--force")
            }
            args.append(worktree.path)

            let result = try ShellRunner.run(executable: "git", arguments: args)
            if !result.succeeded {
                let errText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitWorktreeError.gitCommandFailed(
                    message: errText.isEmpty ? "git worktree remove failed (exit \(result.exitCode))." : errText
                )
            }
            try pruneWorktrees(in: mainRepoPath)

        case .trashSourceAndPrune:
            try FileManager.default.trashItem(at: URL(fileURLWithPath: worktree.path), resultingItemURL: nil)
            try pruneWorktrees(in: mainRepoPath, unlockPathIfNeeded: nil)
        }

        if options.deleteLocalBranch, let branch = entry.branch {
            if let branchWarn = deleteBranch(branch, in: mainRepoPath, force: options.forceDeleteBranch) {
                warnings.append(branchWarn)
            }
        }

        return warnings
    }

    /// Prunes stale/missing linked worktree metadata in `mainRepoPath`.
    public static func pruneWorktrees(in mainRepoPath: String, unlockPathIfNeeded: String? = nil) throws {
        if let unlockPathIfNeeded {
            _ = try? ShellRunner.run(
                executable: "git",
                arguments: ["-C", mainRepoPath, "worktree", "unlock", unlockPathIfNeeded]
            )
        }
        for entry in listWorktrees(for: mainRepoPath) where entry.isPrunable {
            guard let head = entry.head else {
                throw GitWorktreeError.gitCommandFailed(message: "Cannot preserve missing worktree HEAD; pruning blocked.")
            }
            let rescue = "refs/grove/rescued/" + UUID().uuidString.lowercased()
            let saved = try ShellRunner.run(executable: "git", arguments: ["-C", mainRepoPath, "update-ref", rescue, head])
            guard saved.succeeded else {
                throw GitWorktreeError.gitCommandFailed(message: "Could not preserve missing worktree commits; pruning blocked.")
            }
        }
        let result = try ShellRunner.run(
            executable: "git",
            arguments: ["-C", mainRepoPath, "worktree", "prune"]
        )
        if !result.succeeded {
            let errText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorktreeError.gitCommandFailed(
                message: errText.isEmpty ? "git worktree prune failed." : errText
            )
        }
    }

    /// Safely removes an entire ProjectGroup:
    /// - Removes clean linked worktrees (or moves dirty/locked ones to Trash so uncommitted work is preserved)
    /// - Moves the primary project directory to macOS Trash
    public static func removeEntireProject(
        _ project: ProjectGroup,
        options: ProjectRemovalOptions
    ) throws -> [String] {
        let fm = FileManager.default
        var warnings: [String] = []

        if options.removeLinkedWorktrees {
            let primaryPrefix = PathNormalizer.canonicalPath(project.primaryPath) + "/"
            for wt in project.linkedWorktrees {
                let wtPath = PathNormalizer.canonicalPath(wt.path)
                guard !wtPath.hasPrefix(primaryPrefix), fm.fileExists(atPath: wtPath) else { continue }

                let liveStatus = inspectStatusAndUpstream(at: wtPath).status
                if liveStatus.isClean && !wt.isLocked {
                    let res = try? ShellRunner.run(
                        executable: "git",
                        arguments: ["-C", project.primaryPath, "worktree", "remove", wtPath]
                    )
                    if res?.succeeded != true {
                        do {
                            try fm.trashItem(at: URL(fileURLWithPath: wtPath), resultingItemURL: nil)
                        } catch {
                            warnings.append("Could not move linked worktree '\(wt.name)' to Trash: \(error.localizedDescription)")
                        }
                    }
                } else {
                    do {
                        try fm.trashItem(at: URL(fileURLWithPath: wtPath), resultingItemURL: nil)
                    } catch {
                        warnings.append("Could not move linked worktree '\(wt.name)' to Trash: \(error.localizedDescription)")
                    }
                }
            }
        }

        if fm.fileExists(atPath: project.primaryPath) {
            try fm.trashItem(at: URL(fileURLWithPath: project.primaryPath), resultingItemURL: nil)
        }

        return warnings
    }

    private static func deleteBranch(_ branch: String, in mainRepoPath: String, force: Bool) -> String? {
        do {
            try deleteLocalBranchNamed(branch, in: mainRepoPath, force: force)
            return nil
        } catch {
            return "Worktree removed, but branch '\(branch)' was kept: \(error.localizedDescription)"
        }
    }
}
