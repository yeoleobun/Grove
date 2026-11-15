import Darwin
import Foundation

public struct InodeIdentifier: Hashable, Sendable {
    public let dev: dev_t
    public let ino: UInt64

    public init(dev: dev_t, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }
}

public enum WorktreeKind: String, Codable, Sendable, Hashable {
    case main
    case linked
    case prunable

    public var sortRank: Int {
        switch self {
        case .main: return 0
        case .linked: return 1
        case .prunable: return 2
        }
    }
}

public struct GitCommitSummary: Identifiable, Hashable, Sendable {
    public var id: String { shortHash }
    public var shortHash: String
    public var subject: String
    public var relativeTime: String
    public var committedAt: Date?

    public init(shortHash: String, subject: String, relativeTime: String, committedAt: Date? = nil) {
        self.shortHash = shortHash
        self.subject = subject
        self.relativeTime = relativeTime
        self.committedAt = committedAt
    }
}

public struct GitWorkingTreeStatus: Hashable, Sendable {
    public var inspectionError: String?
    public var ignoredCount: Int
    public var stagedCount: Int
    public var modifiedCount: Int
    public var untrackedCount: Int
    public var conflictCount: Int
    public var sampleFiles: [String]

    public init(
        inspectionError: String? = nil,
        ignoredCount: Int = 0,
        stagedCount: Int = 0,
        modifiedCount: Int = 0,
        untrackedCount: Int = 0,
        conflictCount: Int = 0,
        sampleFiles: [String] = []
    ) {
        self.inspectionError = inspectionError
        self.ignoredCount = ignoredCount
        self.stagedCount = stagedCount
        self.modifiedCount = modifiedCount
        self.untrackedCount = untrackedCount
        self.conflictCount = conflictCount
        self.sampleFiles = sampleFiles
    }

    public var totalChangedCount: Int {
        stagedCount + modifiedCount + untrackedCount + conflictCount
    }

    public var isClean: Bool {
        inspectionError == nil && totalChangedCount == 0
    }

    public var breakdownSummary: String {
        var parts: [String] = []
        if conflictCount > 0 { parts.append("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")") }
        if stagedCount > 0 { parts.append("\(stagedCount) staged") }
        if modifiedCount > 0 { parts.append("\(modifiedCount) modified") }
        if untrackedCount > 0 { parts.append("\(untrackedCount) untracked") }
        return parts.isEmpty ? "Clean working tree" : parts.joined(separator: " · ")
    }
}

public struct GitBranchComparison: Hashable, Sendable {
    /// Whether this repository has at least one configured Git remote (e.g. `origin`).
    public var hasRemote: Bool
    /// Tracking upstream branch, e.g. `"origin/main"` or `"origin/feat/auth"` (nil if branch has no upstream).
    public var upstreamRef: String?
    /// Commits on HEAD not yet pushed to `upstreamRef`.
    public var unpushedCount: Int
    /// Commits on `upstreamRef` not yet pulled into HEAD.
    public var behindUpstreamCount: Int

    /// Primary base branch compared against for worktree merge readiness, e.g. `"origin/main"` or `"main"`.
    public var baseRef: String?
    public var aheadOfBaseCount: Int
    public var behindBaseCount: Int
    /// True when `aheadOfBaseCount > 0` yet `git merge-tree --write-tree <baseRef> HEAD` matches `<baseRef>^{tree}`.
    public var isSquashMergedIntoBase: Bool
    public var unmergedCommits: [GitCommitSummary]
    public var lastCommit: GitCommitSummary?

    public init(
        hasRemote: Bool = false,
        upstreamRef: String? = nil,
        unpushedCount: Int = 0,
        behindUpstreamCount: Int = 0,
        baseRef: String? = nil,
        aheadOfBaseCount: Int = 0,
        behindBaseCount: Int = 0,
        isSquashMergedIntoBase: Bool = false,
        unmergedCommits: [GitCommitSummary] = [],
        lastCommit: GitCommitSummary? = nil
    ) {
        self.hasRemote = hasRemote
        self.upstreamRef = upstreamRef
        self.unpushedCount = unpushedCount
        self.behindUpstreamCount = behindUpstreamCount
        self.baseRef = baseRef
        self.aheadOfBaseCount = aheadOfBaseCount
        self.behindBaseCount = behindBaseCount
        self.isSquashMergedIntoBase = isSquashMergedIntoBase
        self.unmergedCommits = unmergedCommits
        self.lastCommit = lastCommit
    }

    /// Commits ahead of `baseRef` whose changes are NOT yet integrated into `baseRef`.
    public var effectiveUnmergedCommitCount: Int {
        isSquashMergedIntoBase ? 0 : aheadOfBaseCount
    }
}

public enum SafeWorktreeMergeReason: String, Codable, Hashable, Sendable {
    case mergedIntoBase
    case squashMergedIntoBase
    case syncedAtBase
}

/// Clear, actionable Git state answering: "Do I need to Commit, Push, or Clean Up this checkout?"
public enum CheckoutActionState: Hashable, Sendable {
    case needsReview(reason: String)
    /// Directory deleted from disk — stale Git worktree entry ready to `Prune`.
    case missingOnDisk
    /// Has modified, staged, untracked, or conflicted files — commit or stash before cleaning up.
    case needsCommit(dirtyCount: Int, hasConflicts: Bool, isLocked: Bool)
    /// Working tree is clean, but local commits have not been pushed to remote yet.
    case needsPush(count: Int, noUpstream: Bool)
    /// Linked worktree is clean and pushed to its feature branch, awaiting merge into `baseRef`.
    case awaitingMerge(count: Int, baseRef: String)
    /// Linked worktree is clean and its work is already in `baseRef` — safe to remove!
    case readyToRemove(reason: SafeWorktreeMergeReason, baseRef: String)
    /// Primary checkout (or checkout without base ref) is clean and has no unpushed commits.
    case cleanSynced(behindUpstream: Int)

    public var requiresUserAction: Bool {
        switch self {
        case .needsReview, .missingOnDisk, .needsCommit, .needsPush, .readyToRemove:
            return true
        case .awaitingMerge, .cleanSynced:
            return false
        }
    }

    public var isNeedsCommitOrPush: Bool {
        switch self {
        case .needsCommit, .needsPush:
            return true
        default:
            return false
        }
    }

    public var isRemovableWorktree: Bool {
        switch self {
        case .readyToRemove:
            return true
        default:
            return false
        }
    }

    public var urgencyRank: Int {
        switch self {
        case .needsReview: return 0
        case .needsCommit: return 0
        case .needsPush: return 1
        case .readyToRemove, .missingOnDisk: return 2
        case .awaitingMerge: return 3
        case .cleanSynced: return 4
        }
    }

    public var icon: String {
        switch self {
        case .needsReview: return "questionmark.diamond.fill"
        case .missingOnDisk:
            return "exclamationmark.triangle.fill"
        case let .needsCommit(_, hasConflicts, isLocked):
            if hasConflicts { return "xmark.octagon.fill" }
            if isLocked { return "lock.fill" }
            return "pencil.circle.fill"
        case .needsPush:
            return "arrow.up.circle.fill"
        case .awaitingMerge:
            return "arrow.triangle.pull"
        case .readyToRemove:
            return "checkmark.seal.fill"
        case let .cleanSynced(behind):
            return behind > 0 ? "arrow.down.circle" : "checkmark.circle.fill"
        }
    }

    public var label: String {
        switch self {
        case .needsReview: return "Needs review"
        case .missingOnDisk:
            return "Missing Folder"
        case let .needsCommit(count, hasConflicts, isLocked):
            if hasConflicts {
                return "\(count) Conflict\(count == 1 ? "" : "s")"
            } else if isLocked && count == 0 {
                return "Locked"
            } else {
                return "\(count) Uncommitted"
            }
        case let .needsPush(count, _):
            return "\(count) Unpushed"
        case let .awaitingMerge(count, baseRef):
            let shortBase = baseRef.replacingOccurrences(of: "origin/", with: "")
            return "\(count) not in \(shortBase)"
        case let .readyToRemove(reason, _):
            switch reason {
            case .mergedIntoBase, .squashMergedIntoBase:
                return "Clean · Merged"
            case .syncedAtBase:
                return "Clean · Empty"
            }
        case let .cleanSynced(behind):
            return behind > 0 ? "Clean · ↓\(behind)" : "Clean"
        }
    }
}

public struct WorktreeItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: WorktreeKind
    public var isExternalToScanRoots: Bool
    public var branchName: String?
    public var headCommitShort: String?
    public var isDetached: Bool
    public var isLocked: Bool
    public var lockReason: String?
    public var prunableReason: String?
    public var workingTreeStatus: GitWorkingTreeStatus
    public var gitComparison: GitBranchComparison?
    public var lastModified: Date?
    public var isInspecting: Bool

    public init(
        path: String,
        name: String,
        kind: WorktreeKind,
        isExternalToScanRoots: Bool = false,
        branchName: String? = nil,
        headCommitShort: String? = nil,
        isDetached: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        prunableReason: String? = nil,
        workingTreeStatus: GitWorkingTreeStatus = GitWorkingTreeStatus(),
        gitComparison: GitBranchComparison? = nil,
        lastModified: Date? = nil,
        isInspecting: Bool = false
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isExternalToScanRoots = isExternalToScanRoots
        self.branchName = branchName
        self.headCommitShort = headCommitShort
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.prunableReason = prunableReason
        self.workingTreeStatus = workingTreeStatus
        self.gitComparison = gitComparison
        self.lastModified = lastModified
        self.isInspecting = isInspecting
    }

    public var dirtyFilesCount: Int {
        workingTreeStatus.totalChangedCount
    }

    public var hasUncommittedChanges: Bool {
        !workingTreeStatus.isClean
    }

    /// Evaluates the exact developer action state for this checkout (`Commit`, `Push`, `Awaiting Merge`, `Clean · Merged`, or `Clean`).
    public var actionState: CheckoutActionState {
        if kind == .prunable {
            return .missingOnDisk
        }
        if isInspecting { return .needsReview(reason: "Inspection in progress.") }
        if let error = workingTreeStatus.inspectionError { return .needsReview(reason: error) }
        if workingTreeStatus.ignoredCount > 0 {
            return .needsReview(reason: "Ignored local files are present. Review or move the folder to Trash to preserve them.")
        }
        if hasUncommittedChanges || isLocked {
            return .needsCommit(
                dirtyCount: dirtyFilesCount,
                hasConflicts: workingTreeStatus.conflictCount > 0,
                isLocked: isLocked
            )
        }

        let cmp = gitComparison
        let unpushed = cmp?.unpushedCount ?? 0
        let hasUpstream = cmp?.upstreamRef != nil
        let hasRemote = cmp?.hasRemote ?? false
        let effectiveAheadOfBase = cmp?.effectiveUnmergedCommitCount ?? 0

        if kind == .main {
            if unpushed > 0 {
                return .needsPush(count: unpushed, noUpstream: false)
            }
            if !hasUpstream && hasRemote && effectiveAheadOfBase > 0 {
                return .needsPush(count: effectiveAheadOfBase, noUpstream: true)
            }
            return .cleanSynced(behindUpstream: cmp?.behindUpstreamCount ?? 0)
        }

        // Linked worktree:
        if let cmp, let baseRef = cmp.baseRef {
            // Ancestry, independent of feature-upstream push status, proves commit preservation.
            if cmp.aheadOfBaseCount == 0 {
                let reason: SafeWorktreeMergeReason
                if cmp.isSquashMergedIntoBase {
                    reason = .squashMergedIntoBase
                } else if cmp.behindBaseCount > 0 {
                    reason = .mergedIntoBase
                } else {
                    reason = .syncedAtBase
                }
                return .readyToRemove(reason: reason, baseRef: baseRef)
            }

            // Tree equivalence is evidence about content, not original commit ancestry.
            if cmp.isSquashMergedIntoBase {
                return .needsReview(reason: "Changes appear integrated into \(baseRef), but original commits are not contained in that target.")
            }

            if isDetached {
                return .needsReview(reason: "Detached HEAD has \(cmp.aheadOfBaseCount) commits not contained in \(baseRef). Preserve commits before removal.")
            }

            // 3. Unmerged work exists: check whether it needs `git push` or is already pushed / local-only awaiting merge
            if unpushed > 0 {
                return .needsPush(count: unpushed, noUpstream: false)
            }
            if !hasUpstream && hasRemote && effectiveAheadOfBase > 0 {
                return .needsPush(count: effectiveAheadOfBase, noUpstream: true)
            }
            if effectiveAheadOfBase > 0 {
                return .awaitingMerge(count: effectiveAheadOfBase, baseRef: baseRef)
            }
        } else if unpushed > 0 {
            return .needsPush(count: unpushed, noUpstream: false)
        }

        return .needsReview(reason: "No verified integration target. Commit preservation is unknown.")
    }

    public var isSafeToRemoveLinkedWorktree: Bool {
        guard kind == .linked else { return false }
        return actionState.isRemovableWorktree
    }

    public var statusTooltip: String {
        var lines: [String] = []
        switch actionState {
        case let .needsReview(reason):
            lines.append(reason)
        case .missingOnDisk:
            lines.append("Worktree directory was deleted from disk — click Remove to prune Git metadata.")
        case .needsCommit:
            if isLocked {
                lines.append("Locked worktree\(lockReason.map { ": \($0)" } ?? "")")
            }
            if hasUncommittedChanges {
                lines.append("Uncommitted changes: \(workingTreeStatus.breakdownSummary)")
                for file in workingTreeStatus.sampleFiles.prefix(8) {
                    lines.append("  \(file)")
                }
            }
        case let .needsPush(count, noUpstream):
            if noUpstream {
                lines.append("\(count) local commit\(count == 1 ? "" : "s") on a branch with no remote upstream yet.")
            } else if let up = gitComparison?.upstreamRef {
                lines.append("\(count) commit\(count == 1 ? "" : "s") ahead of \(up) — ready to `git push`.")
            }
            for c in (gitComparison?.unmergedCommits ?? []).prefix(5) {
                lines.append("  \(c.shortHash) \(c.subject)")
            }
        case let .awaitingMerge(count, baseRef):
            lines.append("Clean working directory, \(count) commit\(count == 1 ? "" : "s") not yet merged into \(baseRef).")
            for c in (gitComparison?.unmergedCommits ?? []).prefix(5) {
                lines.append("  \(c.shortHash) \(c.subject)")
            }
        case let .readyToRemove(reason, baseRef):
            switch reason {
            case .mergedIntoBase:
                lines.append("Safe to clean up — working tree is clean and all commits are merged into \(baseRef).")
            case .squashMergedIntoBase:
                lines.append("Safe to clean up — working tree is clean and changes were squash/rebase-merged into \(baseRef).")
            case .syncedAtBase:
                lines.append("Safe to clean up — working tree is clean and sits directly at \(baseRef).")
            }
        case let .cleanSynced(behind):
            if behind > 0, let up = gitComparison?.upstreamRef {
                lines.append("Clean working tree · \(behind) commit\(behind == 1 ? "" : "s") behind \(up) (`git pull`).")
            } else {
                lines.append("Clean working tree & up to date.")
            }
        }
        return lines.joined(separator: "\n")
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

public struct ProjectGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var primaryPath: String
    public var gitCommonDir: String
    public var worktrees: [WorktreeItem]

    public init(
        id: String,
        name: String,
        primaryPath: String,
        gitCommonDir: String,
        worktrees: [WorktreeItem]
    ) {
        self.id = id
        self.name = name
        self.primaryPath = primaryPath
        self.gitCommonDir = gitCommonDir
        self.worktrees = worktrees
    }

    public var isInspecting: Bool {
        worktrees.contains(where: \.isInspecting)
    }

    /// Primary repository checkout (`main`), displayed directly on the Project row.
    public var mainWorktree: WorktreeItem? {
        worktrees.first(where: { $0.kind == .main }) ?? worktrees.first
    }

    /// Non-main Git worktrees (`linked` and `prunable`) nested under the Project row.
    public var subWorktrees: [WorktreeItem] {
        worktrees.filter { $0.kind == .linked || $0.kind == .prunable }
    }

    public var linkedWorktrees: [WorktreeItem] {
        worktrees.filter { $0.kind == .linked }
    }

    public var prunableWorktrees: [WorktreeItem] {
        worktrees.filter { $0.kind == .prunable }
    }

    public var prunableWorktreeCount: Int {
        prunableWorktrees.count
    }

    public var needsCommitCount: Int {
        worktrees.filter {
            if case .needsCommit = $0.actionState { return true }
            return false
        }.count
    }

    public var needsPushCount: Int {
        worktrees.filter {
            if case .needsPush = $0.actionState { return true }
            return false
        }.count
    }

    public var removableWorktreeCount: Int {
        subWorktrees.filter { $0.actionState.isRemovableWorktree }.count
    }

    public var actionableCheckoutCount: Int {
        worktrees.filter { $0.actionState.requiresUserAction }.count
    }

    public var highestUrgencyRank: Int {
        worktrees.map(\.actionState.urgencyRank).min() ?? 4
    }

    public var lastModified: Date? {
        worktrees.compactMap(\.lastModified).max()
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if primaryPath == home {
            return "~"
        } else if primaryPath.hasPrefix(home + "/") {
            return "~" + primaryPath.dropFirst(home.count)
        }
        return primaryPath
    }
}

public struct ScanSummary: Equatable, Sendable {
    public var projectCount: Int
    public var linkedWorktreeCount: Int
    public var prunableWorktreeCount: Int
    public var needsCommitCount: Int
    public var needsPushCount: Int
    public var removableWorktreeCount: Int
    /// Total checkouts requiring attention (commit, push, or removable worktree cleanup).
    public var actionableCount: Int
    public var scanDurationSeconds: Double

    public init(projects: [ProjectGroup] = [], scanDurationSeconds: Double = 0) {
        self.projectCount = projects.count
        self.linkedWorktreeCount = projects.reduce(0) { $0 + $1.linkedWorktrees.count }
        self.prunableWorktreeCount = projects.reduce(0) { $0 + $1.prunableWorktreeCount }
        self.needsCommitCount = projects.reduce(0) { $0 + $1.needsCommitCount }
        self.needsPushCount = projects.reduce(0) { $0 + $1.needsPushCount }
        self.removableWorktreeCount = projects.reduce(0) { $0 + $1.removableWorktreeCount }
        self.actionableCount = projects.reduce(0) { $0 + $1.actionableCheckoutCount }
        self.scanDurationSeconds = scanDurationSeconds
    }
}

public struct ActionReport: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var affectedCount: Int
    public var warnings: [String]
    public var timestamp: Date

    public init(
        title: String,
        affectedCount: Int,
        warnings: [String] = [],
        timestamp: Date = Date()
    ) {
        self.title = title
        self.affectedCount = affectedCount
        self.warnings = warnings
        self.timestamp = timestamp
    }
}

public enum RelativeTimeFormatting {
    public static func compactString(from date: Date, now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 60 {
            return "just now"
        } else if delta < 3600 {
            return "\(Int(delta / 60))m ago"
        } else if delta < 86_400 {
            return "\(Int(delta / 3600))h ago"
        } else if delta < 86_400 * 30 {
            return "\(Int(delta / 86_400))d ago"
        } else if delta < 86_400 * 365 {
            return "\(max(1, Int(delta / (86_400 * 30))))mo ago"
        } else {
            return "\(max(1, Int(delta / (86_400 * 365))))y ago"
        }
    }

    public static func shortAgeString(from date: Date, now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 60 {
            return "now"
        } else if delta < 3600 {
            return "\(max(1, Int(delta / 60)))m"
        } else if delta < 86_400 {
            return "\(max(1, Int(delta / 3600)))h"
        } else if delta < 86_400 * 30 {
            return "\(max(1, Int(delta / 86_400)))d"
        } else if delta < 86_400 * 365 {
            return "\(max(1, Int(delta / (86_400 * 30))))mo"
        } else {
            return "\(max(1, Int(delta / (86_400 * 365))))y"
        }
    }
}
