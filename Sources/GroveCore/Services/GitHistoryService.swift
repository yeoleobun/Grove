import Foundation

public enum WorkingTreeChangeKind: String, Hashable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case conflicted = "!"

    public var badgeLabel: String { rawValue }
}

public struct WorkingTreeFileChange: Identifiable, Hashable, Sendable {
    public var id: String { "\(status.rawValue):\(isStaged ? "S" : "U"):\(path)" }
    public var path: String
    public var status: WorkingTreeChangeKind
    public var isStaged: Bool
    public var additions: Int?
    public var deletions: Int?

    public init(
        path: String,
        status: WorkingTreeChangeKind,
        isStaged: Bool,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.path = path
        self.status = status
        self.isStaged = isStaged
        self.additions = additions
        self.deletions = deletions
    }
}

public struct CommitWorktreeMarker: Identifiable, Hashable, Sendable {
    public var id: String { worktreeID }
    public var worktreeID: String
    public var name: String
    public var refLabel: String
    public var isPrimary: Bool
    public var isDetached: Bool

    public init(
        worktreeID: String,
        name: String,
        refLabel: String,
        isPrimary: Bool,
        isDetached: Bool
    ) {
        self.worktreeID = worktreeID
        self.name = name
        self.refLabel = refLabel
        self.isPrimary = isPrimary
        self.isDetached = isDetached
    }
}

public struct CommitBranchMarker: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var relationship: LocalBranchRelationship
    public var checkedOutWorktreeID: String?
    public var checkedOutWorktreeName: String?
    public var aheadOfBase: Int
    public var behindBase: Int
    public var idleDays: Int

    public init(
        name: String,
        relationship: LocalBranchRelationship,
        checkedOutWorktreeID: String? = nil,
        checkedOutWorktreeName: String? = nil,
        aheadOfBase: Int = 0,
        behindBase: Int = 0,
        idleDays: Int = 0
    ) {
        self.name = name
        self.relationship = relationship
        self.checkedOutWorktreeID = checkedOutWorktreeID
        self.checkedOutWorktreeName = checkedOutWorktreeName
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.idleDays = idleDays
    }

    public var isIdleUnmerged: Bool {
        idleDays >= 14 && !relationship.isMergedIntoBase && relationship != .baseTrunk
    }
}

public enum GraphEdgeConnectionKind: Hashable, Sendable {
    /// Continues from top of row `y=0` to center `y=mid` (incoming from previous row).
    case topToCenter(fromLane: Int, toLane: Int, colorIndex: Int, isDashed: Bool)
    /// Continues from center `y=mid` to bottom of row `y=height` (outgoing to next row).
    case centerToBottom(fromLane: Int, toLane: Int, colorIndex: Int, isDashed: Bool)
    /// Passes straight through this row from `y=0` to `y=height` on `lane`.
    case passThrough(lane: Int, colorIndex: Int, isDashed: Bool)
}

public struct GitGraphCommitRow: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var shortHash: String
    public var parentHashes: [String]
    public var subject: String
    public var authorName: String
    public var committedAt: Date?
    public var relativeTime: String
    public var idleDays: Int
    public var lane: Int
    public var colorIndex: Int
    public var isOrphanedDetached: Bool
    public var isIdleTip: Bool
    public var isMergedBranchTip: Bool
    public var edges: [GraphEdgeConnectionKind]
    public var worktreeMarkers: [CommitWorktreeMarker]
    public var branchMarkers: [CommitBranchMarker]
    public var extraRefs: [String]

    public init(
        hash: String,
        shortHash: String,
        parentHashes: [String],
        subject: String,
        authorName: String,
        committedAt: Date?,
        relativeTime: String,
        idleDays: Int = 0,
        lane: Int,
        colorIndex: Int,
        isOrphanedDetached: Bool,
        isIdleTip: Bool = false,
        isMergedBranchTip: Bool = false,
        edges: [GraphEdgeConnectionKind],
        worktreeMarkers: [CommitWorktreeMarker],
        branchMarkers: [CommitBranchMarker] = [],
        extraRefs: [String]
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.parentHashes = parentHashes
        self.subject = subject
        self.authorName = authorName
        self.committedAt = committedAt
        self.relativeTime = relativeTime
        self.idleDays = idleDays
        self.lane = lane
        self.colorIndex = colorIndex
        self.isOrphanedDetached = isOrphanedDetached
        self.isIdleTip = isIdleTip
        self.isMergedBranchTip = isMergedBranchTip
        self.edges = edges
        self.worktreeMarkers = worktreeMarkers
        self.branchMarkers = branchMarkers
        self.extraRefs = extraRefs
    }

    /// Standalone local branches on this commit that are NOT already represented by a `worktreeMarker`.
    public var standaloneBranchMarkers: [CommitBranchMarker] {
        branchMarkers.filter { $0.checkedOutWorktreeID == nil }
    }
}

public enum GitTopologyDisplayItem: Identifiable, Hashable, Sendable {
    case commit(GitGraphCommitRow)
    case collapsedTrunk(
        id: String,
        hiddenCommits: [GitGraphCommitRow],
        passThroughEdges: [GraphEdgeConnectionKind],
        newestRelativeTime: String,
        oldestRelativeTime: String
    )

    public var id: String {
        switch self {
        case let .commit(row):
            return "commit:\(row.hash)"
        case let .collapsedTrunk(segID, _, _, _, _):
            return segID
        }
    }
}

public enum CheckoutPositionTone: String, Hashable, Sendable {
    case emerald
    case blue
    case amber
    case red
    case neutral
}

public struct CheckoutPositionSummary: Hashable, Sendable {
    public var headline: String
    public var detail: String
    public var tone: CheckoutPositionTone
    public var fullHeadHash: String?
    public var shortHeadHash: String?
    public var isOrphanedDetached: Bool

    public init(
        headline: String,
        detail: String,
        tone: CheckoutPositionTone,
        fullHeadHash: String? = nil,
        shortHeadHash: String? = nil,
        isOrphanedDetached: Bool = false
    ) {
        self.headline = headline
        self.detail = detail
        self.tone = tone
        self.fullHeadHash = fullHeadHash
        self.shortHeadHash = shortHeadHash
        self.isOrphanedDetached = isOrphanedDetached
    }
}

public enum LocalBranchRelationship: Hashable, Sendable {
    case baseTrunk
    case mergedIntoBase(viaSquashOrRebase: Bool, upstreamGone: Bool)
    case activePROrTracked
    case upstreamGoneUnmerged
    case localExperiment

    public var isMergedIntoBase: Bool {
        if case .mergedIntoBase = self { return true }
        return false
    }
}

public enum BranchDeleteRiskLevel: String, Hashable, Sendable {
    case low
    case medium
    case high
}

public enum BranchForceDeleteReason: Hashable, Sendable {
    /// Merged into `main`, yet `git branch -d` refuses because commits aren't pushed to its own upstream tracking ref (e.g. `origin/feat/...`).
    case mergedToMainButUnpushedToUpstream(base: String, upstream: String, aheadOfUpstream: Int)
    /// Merged into `main` via squash or rebase, so commit SHAs differ and Git requires `-D`.
    case squashOrRebaseMergedIntoMain(base: String)
    /// Merged into remote base (`origin/main`), though local checkout `HEAD` hasn't pulled yet or `git branch -d` reported not merged to HEAD/upstream.
    case mergedIntoBaseButGitRefusedSafeDelete(base: String)
    /// Not merged into `main`, though all commits are backed up on a live remote tracking branch.
    case unmergedButBackedUpOnRemote(base: String, aheadOfBase: Int, upstream: String)
    /// Not merged into `main` and has local commits not backed up on any live remote branch.
    case unmergedLocalCommits(base: String, aheadOfBase: Int, unpushedCount: Int)

    public var riskLevel: BranchDeleteRiskLevel {
        switch self {
        case .mergedToMainButUnpushedToUpstream,
             .squashOrRebaseMergedIntoMain,
             .mergedIntoBaseButGitRefusedSafeDelete:
            return .low
        case .unmergedButBackedUpOnRemote:
            return .medium
        case .unmergedLocalCommits:
            return .high
        }
    }

    public var badgeTitle: String {
        switch self {
        case let .mergedToMainButUnpushedToUpstream(base, _, _):
            return "Low Risk · Merged into \(base), Unpushed to Upstream"
        case let .squashOrRebaseMergedIntoMain(base):
            return "Low Risk · Squash-Merged into \(base)"
        case let .mergedIntoBaseButGitRefusedSafeDelete(base):
            return "Low Risk · Merged into \(base)"
        case .unmergedButBackedUpOnRemote:
            return "Medium Risk · Unmerged into Main (On Origin)"
        case .unmergedLocalCommits:
            return "High Risk · Unmerged Local Commits"
        }
    }

    public var explanation: String {
        switch self {
        case let .mergedToMainButUnpushedToUpstream(base, upstream, count):
            return "All commits on this branch are already merged into '\(base)', so code on '\(base)' is safe. Git's safe delete (`-d`) refuses because this branch is \(count) commit\(count == 1 ? "" : "s") ahead of its remote-tracking ref '\(upstream)'. Confirming runs `git branch -D`."
        case let .squashOrRebaseMergedIntoMain(base):
            return "A merge would leave the file tree unchanged in '\(base)' but original commits are not contained there, so '\(base)' is safe. Because commit hashes differ from '\(base)', Git requires `git branch -D`."
        case let .mergedIntoBaseButGitRefusedSafeDelete(base):
            return "Changes are already merged into '\(base)', though `git branch -d` checks against current `HEAD` and upstream tracking refs first. Confirming runs `git branch -D`."
        case let .unmergedButBackedUpOnRemote(base, ahead, upstream):
            return "Has \(ahead) commit\(ahead == 1 ? "" : "s") NOT merged into '\(base)', though those commits are pushed to '\(upstream)'. Confirming runs `git branch -D` to delete the local branch."
        case let .unmergedLocalCommits(base, ahead, unpushed):
            let suffix = unpushed > 0 ? " (\(unpushed) not pushed to remote)" : " with no live remote backup"
            return "Has \(ahead) commit\(ahead == 1 ? "" : "s") NOT merged into '\(base)'\(suffix). Force deleting (`git branch -D`) will detach these commits from any branch!"
        }
    }
}

public struct LocalBranchInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var fullHash: String
    public var shortHash: String
    public var subject: String
    public var committedAt: Date?
    public var relativeTime: String
    public var idleDays: Int
    public var upstreamRef: String?
    public var isUpstreamGone: Bool
    public var aheadOfUpstream: Int
    public var behindUpstream: Int
    public var baseRef: String?
    public var aheadOfBase: Int
    public var behindBase: Int
    public var checkedOutWorktreeID: String?
    public var checkedOutWorktreeName: String?
    public var relationship: LocalBranchRelationship

    public init(
        name: String,
        fullHash: String = "",
        shortHash: String,
        subject: String,
        committedAt: Date?,
        relativeTime: String,
        idleDays: Int = 0,
        upstreamRef: String?,
        isUpstreamGone: Bool,
        aheadOfUpstream: Int,
        behindUpstream: Int,
        baseRef: String?,
        aheadOfBase: Int,
        behindBase: Int,
        checkedOutWorktreeID: String?,
        checkedOutWorktreeName: String?,
        relationship: LocalBranchRelationship
    ) {
        self.name = name
        self.fullHash = fullHash
        self.shortHash = shortHash
        self.subject = subject
        self.committedAt = committedAt
        self.relativeTime = relativeTime
        self.idleDays = idleDays
        self.upstreamRef = upstreamRef
        self.isUpstreamGone = isUpstreamGone
        self.aheadOfUpstream = aheadOfUpstream
        self.behindUpstream = behindUpstream
        self.baseRef = baseRef
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.checkedOutWorktreeID = checkedOutWorktreeID
        self.checkedOutWorktreeName = checkedOutWorktreeName
        self.relationship = relationship
    }

    /// True when the branch's changes are already in `main` and no worktree currently has it checked out.
    public var isSafeToRemove: Bool {
        guard checkedOutWorktreeID == nil else { return false }
        if case .mergedIntoBase(viaSquashOrRebase: false, _) = relationship { return true }
        return false
    }

    /// Structured reason whenever `git branch -D` (force delete) and user confirmation are required.
    /// Returns `nil` only when standard `git branch -d` is expected to succeed cleanly.
    public var forceDeleteReason: BranchForceDeleteReason? {
        let base = baseRef ?? "main"
        switch relationship {
        case .baseTrunk:
            return nil
        case let .mergedIntoBase(viaSquashOrRebase, _):
            if viaSquashOrRebase {
                return .squashOrRebaseMergedIntoMain(base: base)
            }
            if let upstream = upstreamRef, !isUpstreamGone, aheadOfUpstream > 0 {
                return .mergedToMainButUnpushedToUpstream(
                    base: base,
                    upstream: upstream,
                    aheadOfUpstream: aheadOfUpstream
                )
            }
            if base.hasPrefix("origin/") {
                return .mergedIntoBaseButGitRefusedSafeDelete(base: base)
            }
            return nil
        case .activePROrTracked:
            if let upstream = upstreamRef, !isUpstreamGone, aheadOfUpstream == 0 {
                return .unmergedButBackedUpOnRemote(
                    base: base,
                    aheadOfBase: max(1, aheadOfBase),
                    upstream: upstream
                )
            }
            return .unmergedLocalCommits(
                base: base,
                aheadOfBase: max(1, aheadOfBase),
                unpushedCount: aheadOfUpstream
            )
        case .upstreamGoneUnmerged, .localExperiment:
            return .unmergedLocalCommits(
                base: base,
                aheadOfBase: max(1, aheadOfBase),
                unpushedCount: aheadOfUpstream
            )
        }
    }

    public var requiresForceFlagWhenDeleting: Bool {
        forceDeleteReason != nil
    }
}

public struct ProjectHistorySnapshot: Hashable, Sendable {
    public var projectID: String
    public var selectedWorktreeID: String?
    public var positionSummary: CheckoutPositionSummary
    public var commits: [GitGraphCommitRow]
    public var maxLaneCount: Int
    public var changedFiles: [WorkingTreeFileChange]
    public var localBranches: [LocalBranchInfo]
    public var hasRemote: Bool
    public var orphanedDetachedWorktreeIDs: Set<String>
    public var headCommitsByWorktreeID: [String: GitCommitSummary]

    public init(
        projectID: String,
        selectedWorktreeID: String?,
        positionSummary: CheckoutPositionSummary,
        commits: [GitGraphCommitRow],
        maxLaneCount: Int,
        changedFiles: [WorkingTreeFileChange],
        localBranches: [LocalBranchInfo] = [],
        hasRemote: Bool = false,
        orphanedDetachedWorktreeIDs: Set<String> = [],
        headCommitsByWorktreeID: [String: GitCommitSummary] = [:]
    ) {
        self.projectID = projectID
        self.selectedWorktreeID = selectedWorktreeID
        self.positionSummary = positionSummary
        self.commits = commits
        self.maxLaneCount = maxLaneCount
        self.changedFiles = changedFiles
        self.localBranches = localBranches
        self.hasRemote = hasRemote
        self.orphanedDetachedWorktreeIDs = orphanedDetachedWorktreeIDs
        self.headCommitsByWorktreeID = headCommitsByWorktreeID
    }

    public var removableBranches: [LocalBranchInfo] {
        localBranches.filter(\.isSafeToRemove)
    }
}

public enum GitHistoryService {
    private struct RawCommit {
        let hash: String
        let shortHash: String
        let parentHashes: [String]
        let authorName: String
        let committedAt: Date?
        let decorations: [String]
        let subject: String
    }

    /// Loads local branch hygiene, detached-HEAD reachability, HEAD commit timestamps, and optional commit topology.
    public static func loadSnapshot(
        for project: ProjectGroup,
        selectedWorktree: WorktreeItem?,
        maxCommits: Int = 180
    ) -> ProjectHistorySnapshot {
        let targetWT = selectedWorktree ?? project.mainWorktree ?? project.worktrees.first
        let repoAnchorPath = FileManager.default.fileExists(atPath: project.primaryPath)
            ? project.primaryPath
            : (project.worktrees.first(where: { $0.kind != .prunable && FileManager.default.fileExists(atPath: $0.path) })?.path ?? project.primaryPath)

        // 1. Resolve exact full 40-char HEAD SHAs for every worktree in this project
        let fullHeadsByPath = resolveWorktreeFullHeads(repoPath: repoAnchorPath, worktrees: project.worktrees)

        // 2. Inspect all local branches (merge readiness, tracking, vs. base relationship, full SHAs, commit idleDays)
        let (localBranches, hasRemote) = loadLocalBranches(repoPath: repoAnchorPath, project: project)

        // 3. Check detached worktree HEAD reachability & ensure every worktree (even detached / prunable) has HEAD commit metadata
        var orphanedDetachedWorktreeIDs: Set<String> = []
        var containingBranchesByWorktreeID: [String: [String]] = [:]
        var headCommitsByWorktreeID: [String: GitCommitSummary] = [:]

        for wt in project.worktrees {
            let headRef = fullHeadsByPath[PathNormalizer.canonicalPath(wt.path)] ?? wt.headCommitShort
            if let existing = wt.gitComparison?.lastCommit {
                headCommitsByWorktreeID[wt.id] = existing
            } else if let sha = headRef, !sha.isEmpty,
                      let resolved = resolveSingleCommitSummary(repoPath: repoAnchorPath, commitRef: sha) {
                headCommitsByWorktreeID[wt.id] = resolved
            }

            if wt.isDetached {
                let branches = branchesContainingHead(repoPath: repoAnchorPath, headSHA: headRef)
                containingBranchesByWorktreeID[wt.id] = branches
                if branches.isEmpty && (headRef?.isEmpty == false) {
                    orphanedDetachedWorktreeIDs.insert(wt.id)
                }
            }
        }

        // 4. Optional topological commit graph (skipped when maxCommits <= 0 for instantaneous single-page UI)
        let rows: [GitGraphCommitRow]
        let maxLanes: Int
        if maxCommits > 0 {
            let explicitHeads = Array(Set(fullHeadsByPath.values))
            let rawCommits = fetchRawCommits(
                repoPath: repoAnchorPath,
                explicitHeadHashes: explicitHeads,
                maxCommits: maxCommits
            )
            let baseHash = resolveBaseCommitHash(
                repoPath: repoAnchorPath,
                mainWorktree: project.mainWorktree,
                fullHeadsByPath: fullHeadsByPath,
                rawCommits: rawCommits
            )
            let built = buildGraphRows(
                rawCommits: rawCommits,
                project: project,
                localBranches: localBranches,
                fullHeadsByPath: fullHeadsByPath,
                baseCommitHash: baseHash,
                orphanedDetachedWorktreeIDs: orphanedDetachedWorktreeIDs
            )
            rows = built.0
            maxLanes = built.1
        } else {
            rows = []
            maxLanes = 1
        }

        // 5. Build clear position summary for the selected checkout
        let selectedFullSHA = targetWT.flatMap { fullHeadsByPath[PathNormalizer.canonicalPath($0.path)] }
        let position = buildPositionSummary(
            worktree: targetWT,
            project: project,
            fullHeadHash: selectedFullSHA,
            containingBranches: targetWT.flatMap { containingBranchesByWorktreeID[$0.id] } ?? [],
            isOrphanedDetached: targetWT.map { orphanedDetachedWorktreeIDs.contains($0.id) } ?? false
        )

        // 6. Fetch structured changed files + diff line stats for the selected checkout
        let changedFiles: [WorkingTreeFileChange]
        if let wt = targetWT, wt.kind != .prunable, FileManager.default.fileExists(atPath: wt.path) {
            changedFiles = fetchWorkingTreeChanges(at: wt.path)
        } else {
            changedFiles = []
        }

        return ProjectHistorySnapshot(
            projectID: project.id,
            selectedWorktreeID: targetWT?.id,
            positionSummary: position,
            commits: rows,
            maxLaneCount: max(1, maxLanes),
            changedFiles: changedFiles,
            localBranches: localBranches,
            hasRemote: hasRemote,
            orphanedDetachedWorktreeIDs: orphanedDetachedWorktreeIDs,
            headCommitsByWorktreeID: headCommitsByWorktreeID
        )
    }

    private static func resolveSingleCommitSummary(repoPath: String, commitRef: String) -> GitCommitSummary? {
        guard let res = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", repoPath, "log", "-1", "--format=%h\t%s\t%cr\t%ct", commitRef]
        ), res.succeeded else {
            return nil
        }
        let line = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        let ts: Date? = (parts.count >= 4 ? TimeInterval(parts[3]) : nil).map { Date(timeIntervalSince1970: $0) }
        return GitCommitSummary(
            shortHash: parts[0],
            subject: parts[1],
            relativeTime: ts.map { RelativeTimeFormatting.shortAgeString(from: $0) } ?? parts[2],
            committedAt: ts
        )
    }

    // MARK: - Collapsed Linear Trunk Builder (Option 1 Topology)

    /// Collapses runs of uninteresting linear `main` commits (2+ commits with no branch, no worktree,
    /// no tag/remote ref, and no fork/merge) into clickable `.collapsedTrunk` items while preserving 100% lane continuity.
    public static func buildDisplayItems(
        commits: [GitGraphCommitRow],
        expandedSegmentIDs: Set<String> = [],
        collapseLinearTrunk: Bool = true
    ) -> [GitTopologyDisplayItem] {
        guard collapseLinearTrunk, commits.count >= 4 else {
            return commits.map { .commit($0) }
        }

        var items: [GitTopologyDisplayItem] = []
        items.reserveCapacity(commits.count)

        var idx = 0
        while idx < commits.count {
            // Keep very first and very last visible commits anchored so graph top/bottom stay clear
            if idx == 0 || idx == commits.count - 1 || !isCollapsibleLinearTrunkRow(commits[idx]) {
                items.append(.commit(commits[idx]))
                idx += 1
                continue
            }

            let referencePassThrough = collapsedRowEdges(for: commits[idx])
            var runEnd = idx
            while runEnd + 1 < commits.count - 1,
                  isCollapsibleLinearTrunkRow(commits[runEnd + 1]),
                  collapsedRowEdges(for: commits[runEnd + 1]) == referencePassThrough {
                runEnd += 1
            }

            let run = Array(commits[idx...runEnd])
            if run.count >= 2, let first = run.first, let last = run.last {
                let segID = "trunk:\(first.hash):\(last.hash)"
                if expandedSegmentIDs.contains(segID) {
                    for row in run {
                        items.append(.commit(row))
                    }
                } else {
                    items.append(
                        .collapsedTrunk(
                            id: segID,
                            hiddenCommits: run,
                            passThroughEdges: referencePassThrough,
                            newestRelativeTime: first.relativeTime,
                            oldestRelativeTime: last.relativeTime
                        )
                    )
                }
            } else {
                for row in run {
                    items.append(.commit(row))
                }
            }

            idx = runEnd + 1
        }

        return items
    }

    private static func isCollapsibleLinearTrunkRow(_ row: GitGraphCommitRow) -> Bool {
        guard row.lane == 0,
              row.colorIndex == 0,
              row.worktreeMarkers.isEmpty,
              row.branchMarkers.isEmpty,
              row.extraRefs.isEmpty,
              !row.isOrphanedDetached,
              !row.isIdleTip,
              !row.isMergedBranchTip else {
            return false
        }
        var topZeroCount = 0
        var bottomZeroCount = 0
        for edge in row.edges {
            switch edge {
            case let .topToCenter(fromLane, toLane, _, _):
                guard fromLane == 0, toLane == 0 else { return false }
                topZeroCount += 1
            case let .centerToBottom(fromLane, toLane, _, _):
                guard fromLane == 0, toLane == 0 else { return false }
                bottomZeroCount += 1
            case let .passThrough(lane, _, _):
                guard lane > 0 else { return false }
            }
        }
        return topZeroCount == 1 && bottomZeroCount == 1
    }

    private static func collapsedRowEdges(for row: GitGraphCommitRow) -> [GraphEdgeConnectionKind] {
        var passThroughs: [GraphEdgeConnectionKind] = [
            .passThrough(lane: 0, colorIndex: 0, isDashed: false)
        ]
        for edge in row.edges {
            if case let .passThrough(lane, colorIdx, isDashed) = edge, lane > 0 {
                passThroughs.append(.passThrough(lane: lane, colorIndex: colorIdx, isDashed: isDashed))
            }
        }
        passThroughs.sort { lhs, rhs in
            let lLane: Int = { if case let .passThrough(l, _, _) = lhs { return l }; return 0 }()
            let rLane: Int = { if case let .passThrough(l, _, _) = rhs { return l }; return 0 }()
            return lLane < rLane
        }
        return passThroughs
    }

    // MARK: - Resolving Exact Worktree HEADs

    private static func resolveWorktreeFullHeads(repoPath: String, worktrees: [WorktreeItem]) -> [String: String] {
        var map: [String: String] = [:]

        if let res = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", repoPath, "worktree", "list", "--porcelain"]
        ), res.succeeded {
            var currentPath: String?
            for rawLine in res.stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = String(rawLine)
                if line.isEmpty {
                    currentPath = nil
                    continue
                }
                if line.hasPrefix("worktree ") {
                    currentPath = PathNormalizer.canonicalPath(String(line.dropFirst("worktree ".count)))
                } else if line.hasPrefix("HEAD "), let path = currentPath {
                    let sha = String(line.dropFirst("HEAD ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sha.isEmpty {
                        map[path] = sha
                    }
                }
            }
        }

        // Fallback per-worktree `rev-parse HEAD` if needed
        for wt in worktrees where wt.kind != .prunable {
            let canon = PathNormalizer.canonicalPath(wt.path)
            if map[canon] == nil, FileManager.default.fileExists(atPath: wt.path) {
                if let res = try? ShellRunner.run(
                    executable: "git",
                    arguments: ["--no-optional-locks", "-C", wt.path, "rev-parse", "HEAD"]
                ), res.succeeded {
                    let sha = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sha.isEmpty {
                        map[canon] = sha
                    }
                }
            }
        }

        return map
    }

    private static func resolveBaseCommitHash(
        repoPath: String,
        mainWorktree: WorktreeItem?,
        fullHeadsByPath: [String: String],
        rawCommits: [RawCommit]
    ) -> String? {
        if let mainWT = mainWorktree {
            let canon = PathNormalizer.canonicalPath(mainWT.path)
            if let sha = fullHeadsByPath[canon] {
                return sha
            }
        }
        for candidate in ["refs/remotes/origin/main", "refs/heads/main", "refs/remotes/origin/master", "refs/heads/master"] {
            if let res = try? ShellRunner.run(
                executable: "git",
                arguments: ["--no-optional-locks", "-C", repoPath, "rev-parse", "--verify", "--quiet", candidate]
            ), res.succeeded {
                let sha = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sha.isEmpty { return sha }
            }
        }
        return rawCommits.first?.hash
    }

    private static func branchesContainingHead(repoPath: String, headSHA: String?) -> [String] {
        guard let headSHA, !headSHA.isEmpty else { return [] }
        guard let res = try? ShellRunner.run(
            executable: "git",
            arguments: [
                "--no-optional-locks", "-C", repoPath,
                "branch", "--all", "--contains", headSHA,
                "--format=%(refname:short)"
            ]
        ), res.succeeded else {
            return []
        }

        return res.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") && !$0.hasPrefix("(") }
    }

    // MARK: - Fetching Raw Commits

    private static func fetchRawCommits(
        repoPath: String,
        explicitHeadHashes: [String],
        maxCommits: Int
    ) -> [RawCommit] {
        var args: [String] = [
            "--no-optional-locks", "-C", repoPath,
            "log",
            "--topo-order",
            "--max-count=\(maxCommits)",
            "--decorate=short",
            "--format=%H%x1f%h%x1f%P%x1f%an%x1f%ct%x1f%D%x1f%s%x1e",
            "--branches",
            "--remotes=origin"
        ]
        args.append(contentsOf: explicitHeadHashes.sorted())

        guard let res = try? ShellRunner.run(executable: "git", arguments: args), res.succeeded else {
            return []
        }

        let now = Date()
        var commits: [RawCommit] = []
        let records = res.stdout.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        commits.reserveCapacity(records.count)

        for record in records {
            let trimmedRecord = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRecord.isEmpty else { continue }

            let fields = trimmedRecord.components(separatedBy: "\u{1f}")
            guard fields.count >= 7 else { continue }

            let hash = fields[0]
            let shortHash = fields[1]
            let parents = fields[2].split(separator: " ").map(String.init)
            let author = fields[3]
            let ts = TimeInterval(fields[4]).map { Date(timeIntervalSince1970: $0) }
            let decorations = fields[5]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let subject = fields[6]

            commits.append(
                RawCommit(
                    hash: hash,
                    shortHash: shortHash,
                    parentHashes: parents,
                    authorName: author,
                    committedAt: ts,
                    decorations: decorations,
                    subject: subject
                )
            )
            _ = now
        }

        return commits
    }

    // MARK: - Multi-Lane Topological Graph Builder

    private static func buildGraphRows(
        rawCommits: [RawCommit],
        project: ProjectGroup,
        localBranches: [LocalBranchInfo],
        fullHeadsByPath: [String: String],
        baseCommitHash: String?,
        orphanedDetachedWorktreeIDs: Set<String>
    ) -> (rows: [GitGraphCommitRow], maxLaneCount: Int) {
        guard !rawCommits.isEmpty else { return ([], 1) }

        let now = Date()
        let commitByHash = Dictionary(uniqueKeysWithValues: rawCommits.map { ($0.hash, $0) })
        let knownHashes = Set(rawCommits.map(\.hash))

        // Walk base trunk first-parent / ancestors for Emerald coloring (colorIndex = 0)
        var baseTrunkHashes: Set<String> = []
        if let startBase = baseCommitHash {
            var cursor: String? = startBase
            while let current = cursor, !baseTrunkHashes.contains(current) {
                baseTrunkHashes.insert(current)
                cursor = commitByHash[current]?.parentHashes.first
            }
        }

        // Map commitHash -> [CommitWorktreeMarker] and [CommitBranchMarker]
        var markersByHash: [String: [CommitWorktreeMarker]] = [:]
        var branchMarkersByHash: [String: [CommitBranchMarker]] = [:]
        var claimedBranchNames: Set<String> = []
        var orphanTipHashes: Set<String> = []
        var idleTipHashes: Set<String> = []
        var activeRecentTipHashes: Set<String> = []

        for wt in project.worktrees where wt.kind != .prunable {
            let canon = PathNormalizer.canonicalPath(wt.path)
            let matchedHash: String? = {
                if let exact = fullHeadsByPath[canon], knownHashes.contains(exact) {
                    return exact
                }
                if let short = wt.headCommitShort {
                    return rawCommits.first(where: { $0.hash.hasPrefix(short) || $0.shortHash == short })?.hash
                }
                return nil
            }()

            if let b = wt.branchName {
                claimedBranchNames.insert(b)
            }

            if let sha = matchedHash {
                let refLabel: String
                if let branch = wt.branchName, !branch.isEmpty {
                    refLabel = branch
                } else if wt.isDetached {
                    refLabel = "detached"
                } else {
                    refLabel = wt.headCommitShort ?? String(sha.prefix(7))
                }
                markersByHash[sha, default: []].append(
                    CommitWorktreeMarker(
                        worktreeID: wt.id,
                        name: wt.name,
                        refLabel: refLabel,
                        isPrimary: wt.kind == .main,
                        isDetached: wt.isDetached
                    )
                )
                if orphanedDetachedWorktreeIDs.contains(wt.id) {
                    orphanTipHashes.insert(sha)
                }
                if wt.isDetached, !baseTrunkHashes.contains(sha) {
                    let wtIdleDays = commitByHash[sha]?.committedAt.map {
                        max(0, Int(now.timeIntervalSince($0) / 86_400))
                    } ?? 0
                    if wtIdleDays >= 14 {
                        idleTipHashes.insert(sha)
                    } else if !orphanedDetachedWorktreeIDs.contains(wt.id) {
                        activeRecentTipHashes.insert(sha)
                    }
                }
            }
        }

        for branch in localBranches {
            claimedBranchNames.insert(branch.name)
            let matchedHash: String? = {
                if !branch.fullHash.isEmpty, knownHashes.contains(branch.fullHash) {
                    return branch.fullHash
                }
                return rawCommits.first(where: {
                    $0.hash.hasPrefix(branch.shortHash) || $0.shortHash == branch.shortHash
                })?.hash
            }()
            guard let sha = matchedHash else { continue }

            let marker = CommitBranchMarker(
                name: branch.name,
                relationship: branch.relationship,
                checkedOutWorktreeID: branch.checkedOutWorktreeID,
                checkedOutWorktreeName: branch.checkedOutWorktreeName,
                aheadOfBase: branch.aheadOfBase,
                behindBase: branch.behindBase,
                idleDays: branch.idleDays
            )
            branchMarkersByHash[sha, default: []].append(marker)

            if !baseTrunkHashes.contains(sha) && !branch.relationship.isMergedIntoBase && branch.relationship != .baseTrunk {
                if branch.idleDays >= 14 {
                    idleTipHashes.insert(sha)
                } else {
                    activeRecentTipHashes.insert(sha)
                }
            }
        }

        // Sort markers on the same commit so primary (`main`) comes first
        for key in markersByHash.keys {
            markersByHash[key]?.sort { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        for key in branchMarkersByHash.keys {
            branchMarkersByHash[key]?.sort { lhs, rhs in
                let lTrunk = (lhs.relationship == .baseTrunk)
                let rTrunk = (rhs.relationship == .baseTrunk)
                if lTrunk != rTrunk { return lTrunk }
                let lWT = (lhs.checkedOutWorktreeID != nil)
                let rWT = (rhs.checkedOutWorktreeID != nil)
                if lWT != rWT { return lWT }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        // Walk active recent non-trunk chains so shared ancestors stay solid
        var activeRecentChainHashes: Set<String> = []
        var recentQueue = Array(activeRecentTipHashes)
        while let current = recentQueue.popLast() {
            guard !activeRecentChainHashes.contains(current), !baseTrunkHashes.contains(current) else { continue }
            activeRecentChainHashes.insert(current)
            for p in commitByHash[current]?.parentHashes ?? [] where knownHashes.contains(p) {
                recentQueue.append(p)
            }
        }

        // Walk orphaned detached & idle (>=14d) off-trunk commits stopping at baseTrunkHashes (colorIndex = 2 Amber + dashed)
        var orphanChainHashes: Set<String> = []
        var orphanQueue = Array(orphanTipHashes)
        while let current = orphanQueue.popLast() {
            guard !orphanChainHashes.contains(current), !baseTrunkHashes.contains(current) else { continue }
            orphanChainHashes.insert(current)
            for p in commitByHash[current]?.parentHashes ?? [] where knownHashes.contains(p) {
                orphanQueue.append(p)
            }
        }

        var idleChainHashes: Set<String> = []
        var idleQueue = Array(idleTipHashes)
        while let current = idleQueue.popLast() {
            guard !idleChainHashes.contains(current),
                  !baseTrunkHashes.contains(current),
                  !activeRecentChainHashes.contains(current) else {
                continue
            }
            idleChainHashes.insert(current)
            for p in commitByHash[current]?.parentHashes ?? [] where knownHashes.contains(p) {
                idleQueue.append(p)
            }
        }

        // Color palette indices:
        // 0 = Grove Emerald (base trunk / squash-merged tip)
        // 1 = Blue, 2 = Amber (orphaned detached / idle >=14d), 3 = Violet, 4 = Cyan, 5 = Pink
        let featureCycle = [1, 3, 4, 5]
        var nextFeatureCycleIdx = 0

        struct ActiveLane: Equatable {
            var expectedHash: String
            var colorIndex: Int
            var isDashed: Bool
        }

        let hasBaseSpine = !baseTrunkHashes.isEmpty
        var activeLanes: [ActiveLane?] = hasBaseSpine ? [nil] : []
        var maxUsedLanes = 1
        var rows: [GitGraphCommitRow] = []
        rows.reserveCapacity(rawCommits.count)

        func allocateLane(for expected: String, colorIndex: Int, isDashed: Bool, preferBaseSpine: Bool) -> Int {
            if preferBaseSpine {
                if activeLanes.isEmpty {
                    activeLanes.append(ActiveLane(expectedHash: expected, colorIndex: colorIndex, isDashed: isDashed))
                } else if activeLanes[0] == nil {
                    activeLanes[0] = ActiveLane(expectedHash: expected, colorIndex: colorIndex, isDashed: isDashed)
                    return 0
                }
            }
            let startIdx = (hasBaseSpine && !preferBaseSpine) ? 1 : 0
            if startIdx < activeLanes.count,
               let freeIdx = activeLanes[startIdx...].firstIndex(where: { $0 == nil }) {
                activeLanes[freeIdx] = ActiveLane(expectedHash: expected, colorIndex: colorIndex, isDashed: isDashed)
                maxUsedLanes = max(maxUsedLanes, freeIdx + 1)
                return freeIdx
            }
            while activeLanes.count < startIdx {
                activeLanes.append(nil)
            }
            let idx = activeLanes.count
            activeLanes.append(ActiveLane(expectedHash: expected, colorIndex: colorIndex, isDashed: isDashed))
            maxUsedLanes = max(maxUsedLanes, idx + 1)
            return idx
        }

        for raw in rawCommits {
            var edges: [GraphEdgeConnectionKind] = []

            // 1. Find incoming lanes expecting `raw.hash`
            var matchingCols: [Int] = []
            for (col, slot) in activeLanes.enumerated() where slot?.expectedHash == raw.hash {
                matchingCols.append(col)
            }

            let isBase = baseTrunkHashes.contains(raw.hash)
            let isOrphan = orphanChainHashes.contains(raw.hash)
            let isIdleSpur = idleChainHashes.contains(raw.hash)
            let isAmberDashed = isOrphan || isIdleSpur

            let rowBranches = branchMarkersByHash[raw.hash] ?? []
            let rowWorktrees = markersByHash[raw.hash] ?? []
            let isMergedOffTrunkTip: Bool = {
                guard !isBase, !rowBranches.isEmpty else { return false }
                let nonTrunk = rowBranches.filter { $0.relationship != .baseTrunk }
                return !nonTrunk.isEmpty && nonTrunk.allSatisfy(\.relationship.isMergedIntoBase)
            }()

            let nodeCol: Int
            let nodeColorIndex: Int
            let nodeDashed: Bool

            if !matchingCols.isEmpty {
                // If this commit is on the base trunk and lane 0 is free or among matchingCols, anchor it on lane 0!
                let chosenCol: Int
                if isBase && (matchingCols.contains(0) || (!activeLanes.isEmpty && activeLanes[0] == nil)) {
                    chosenCol = 0
                } else {
                    chosenCol = matchingCols[0]
                }
                let incomingColor = activeLanes[matchingCols[0]]?.colorIndex ?? 1
                nodeCol = chosenCol
                nodeColorIndex = isBase ? 0 : (isAmberDashed ? 2 : incomingColor)
                nodeDashed = !isBase && isAmberDashed

                // Record incoming edges from all matching lanes smoothly into `nodeCol`
                for col in matchingCols {
                    if let slot = activeLanes[col] {
                        edges.append(
                            .topToCenter(
                                fromLane: col,
                                toLane: nodeCol,
                                colorIndex: slot.colorIndex,
                                isDashed: slot.isDashed
                            )
                        )
                    }
                    if col != nodeCol {
                        activeLanes[col] = nil
                    }
                }
            } else {
                // New tip commit!
                let assignedColor: Int
                if isBase || isMergedOffTrunkTip {
                    assignedColor = 0
                } else if isAmberDashed {
                    assignedColor = 2
                } else {
                    assignedColor = featureCycle[nextFeatureCycleIdx % featureCycle.count]
                    nextFeatureCycleIdx += 1
                }
                nodeColorIndex = assignedColor
                nodeDashed = !isBase && isAmberDashed
                nodeCol = allocateLane(
                    for: raw.hash,
                    colorIndex: assignedColor,
                    isDashed: nodeDashed,
                    preferBaseSpine: isBase
                )
            }

            maxUsedLanes = max(maxUsedLanes, nodeCol + 1)

            // 2. Every other active lane passes straight through this row
            for (col, slotOpt) in activeLanes.enumerated() where col != nodeCol {
                if let slot = slotOpt {
                    edges.append(
                        .passThrough(
                            lane: col,
                            colorIndex: slot.colorIndex,
                            isDashed: slot.isDashed
                        )
                    )
                }
            }

            // 3. Connect `nodeCol` down to visible parents inside the fetched window
            let visibleParents = raw.parentHashes.filter { knownHashes.contains($0) }
            if let firstParent = visibleParents.first {
                let firstParentIsBase = baseTrunkHashes.contains(firstParent)
                let outgoingColor = (isBase && firstParentIsBase) ? 0 : nodeColorIndex

                // Keep `nodeCol` flowing straight down to `firstParent`'s row, where all converging branches curve into `firstParent`'s dot!
                activeLanes[nodeCol] = ActiveLane(
                    expectedHash: firstParent,
                    colorIndex: outgoingColor,
                    isDashed: nodeDashed
                )
                edges.append(
                    .centerToBottom(
                        fromLane: nodeCol,
                        toLane: nodeCol,
                        colorIndex: outgoingColor,
                        isDashed: nodeDashed
                    )
                )

                // Additional merge parents fork outward from `nodeCol`
                for mergeParent in visibleParents.dropFirst() {
                    let mergeIsBase = baseTrunkHashes.contains(mergeParent)
                    let mColor: Int
                    if mergeIsBase {
                        mColor = 0
                    } else {
                        mColor = featureCycle[nextFeatureCycleIdx % featureCycle.count]
                        nextFeatureCycleIdx += 1
                    }
                    if let existingCol = activeLanes.firstIndex(where: { $0?.expectedHash == mergeParent }) {
                        edges.append(
                            .centerToBottom(
                                fromLane: nodeCol,
                                toLane: existingCol,
                                colorIndex: activeLanes[existingCol]?.colorIndex ?? mColor,
                                isDashed: false
                            )
                        )
                    } else {
                        let newCol = allocateLane(
                            for: mergeParent,
                            colorIndex: mColor,
                            isDashed: false,
                            preferBaseSpine: mergeIsBase
                        )
                        edges.append(
                            .centerToBottom(
                                fromLane: nodeCol,
                                toLane: newCol,
                                colorIndex: mColor,
                                isDashed: false
                            )
                        )
                    }
                }
            } else {
                // Root commit or parent older than `maxCommits` window
                if nodeCol < activeLanes.count {
                    activeLanes[nodeCol] = nil
                }
            }

            // Trim trailing `nil` lanes (keeping index 0 if `hasBaseSpine` is active)
            let minKeep = hasBaseSpine ? 1 : 0
            while activeLanes.count > minKeep, let lastSlot = activeLanes.last, lastSlot == nil {
                activeLanes.removeLast()
            }

            // Filter decorations to clean, non-duplicate ref labels (e.g. `origin/main`, `tag: v1.0`)
            let extraRefs = cleanExtraDecorations(raw.decorations, claimedBranchNames: claimedBranchNames)
            let relTime = raw.committedAt.map { RelativeTimeFormatting.compactString(from: $0, now: now) } ?? ""
            let commitIdleDays = raw.committedAt.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) } ?? 0
            let isIdleTip = idleTipHashes.contains(raw.hash) && !activeRecentTipHashes.contains(raw.hash)

            rows.append(
                GitGraphCommitRow(
                    hash: raw.hash,
                    shortHash: raw.shortHash,
                    parentHashes: raw.parentHashes,
                    subject: raw.subject,
                    authorName: raw.authorName,
                    committedAt: raw.committedAt,
                    relativeTime: relTime,
                    idleDays: commitIdleDays,
                    lane: nodeCol,
                    colorIndex: nodeColorIndex,
                    isOrphanedDetached: isOrphan,
                    isIdleTip: isIdleTip,
                    isMergedBranchTip: isMergedOffTrunkTip && nodeCol > 0,
                    edges: edges,
                    worktreeMarkers: rowWorktrees,
                    branchMarkers: rowBranches,
                    extraRefs: extraRefs
                )
            )
        }

        return (rows, min(maxUsedLanes, 6))
    }

    private static func cleanExtraDecorations(
        _ rawDecorations: [String],
        claimedBranchNames: Set<String>
    ) -> [String] {
        var result: [String] = []
        for item in rawDecorations {
            var cleaned = item
            if cleaned.hasPrefix("HEAD -> ") {
                cleaned = String(cleaned.dropFirst("HEAD -> ".count))
            }
            if cleaned == "HEAD" || cleaned == "origin/HEAD" {
                continue
            }
            if claimedBranchNames.contains(cleaned) {
                continue
            }
            result.append(cleaned)
        }
        return result
    }

    // MARK: - Checkout Position Summary Builder

    private static func buildPositionSummary(
        worktree: WorktreeItem?,
        project: ProjectGroup,
        fullHeadHash: String?,
        containingBranches: [String],
        isOrphanedDetached: Bool
    ) -> CheckoutPositionSummary {
        guard let wt = worktree else {
            return CheckoutPositionSummary(
                headline: project.name,
                detail: "Select a repository or worktree to inspect its Git tree.",
                tone: .neutral
            )
        }

        let shortSHA = wt.headCommitShort ?? fullHeadHash.map { String($0.prefix(7)) }

        if wt.kind == .prunable {
            return CheckoutPositionSummary(
                headline: "Missing worktree directory",
                detail: "Folder was deleted from disk — prune this stale Git worktree record.",
                tone: .amber,
                fullHeadHash: fullHeadHash,
                shortHeadHash: shortSHA
            )
        }

        if wt.isDetached {
            if isOrphanedDetached {
                return CheckoutPositionSummary(
                    headline: "Orphaned detached HEAD",
                    detail: "Commit \(shortSHA ?? "") is not on any branch — pruning this worktree would lose work!",
                    tone: .amber,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA,
                    isOrphanedDetached: true
                )
            } else {
                let branchList = containingBranches.prefix(2).joined(separator: ", ")
                return CheckoutPositionSummary(
                    headline: "Detached HEAD on \(branchList.isEmpty ? "existing history" : branchList)",
                    detail: "Pinned to commit \(shortSHA ?? "") (reachable via \(branchList.isEmpty ? "branch history" : branchList)).",
                    tone: .blue,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA,
                    isOrphanedDetached: false
                )
            }
        }

        let cmp = wt.gitComparison
        let shortBase = (cmp?.baseRef ?? "main").replacingOccurrences(of: "origin/", with: "")

        if wt.kind == .main {
            let unpushed = cmp?.unpushedCount ?? 0
            let behind = cmp?.behindUpstreamCount ?? 0
            if let up = cmp?.upstreamRef {
                if unpushed == 0 && behind == 0 {
                    return CheckoutPositionSummary(
                        headline: "Primary trunk (\(wt.branchName ?? "main"))",
                        detail: "Synced with \(up)\(wt.hasUncommittedChanges ? " · \(wt.workingTreeStatus.breakdownSummary)" : "")",
                        tone: wt.hasUncommittedChanges ? .amber : .emerald,
                        fullHeadHash: fullHeadHash,
                        shortHeadHash: shortSHA
                    )
                }
                var parts: [String] = []
                if unpushed > 0 { parts.append("\(unpushed) ahead") }
                if behind > 0 { parts.append("\(behind) behind") }
                return CheckoutPositionSummary(
                    headline: "Primary trunk (\(wt.branchName ?? "main"))",
                    detail: "\(parts.joined(separator: " · ")) of \(up)",
                    tone: unpushed > 0 ? .blue : .neutral,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA
                )
            } else {
                return CheckoutPositionSummary(
                    headline: "Primary trunk (\(wt.branchName ?? "main"))",
                    detail: wt.hasUncommittedChanges ? wt.workingTreeStatus.breakdownSummary : "Local repository (no upstream tracking branch)",
                    tone: wt.hasUncommittedChanges ? .amber : .emerald,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA
                )
            }
        }

        // Linked branch worktree
        if let cmp {
            if cmp.isSquashMergedIntoBase {
                return CheckoutPositionSummary(
                    headline: "Squash-merged into \(shortBase)",
                    detail: wt.hasUncommittedChanges
                        ? "Branch changes are in \(shortBase), plus \(wt.workingTreeStatus.breakdownSummary)."
                        : "All branch changes are already integrated into \(shortBase) — safe to prune.",
                    tone: wt.hasUncommittedChanges ? .amber : .emerald,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA
                )
            }

            let ahead = cmp.aheadOfBaseCount
            let behind = cmp.behindBaseCount
            if ahead == 0 && behind == 0 {
                return CheckoutPositionSummary(
                    headline: "Aligned with \(shortBase)",
                    detail: wt.hasUncommittedChanges
                        ? "Branch sits at \(shortBase) · \(wt.workingTreeStatus.breakdownSummary)"
                        : "Sitting directly on \(shortBase) with 0 diverged commits — safe to prune.",
                    tone: wt.hasUncommittedChanges ? .amber : .emerald,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA
                )
            }
            if ahead == 0 && behind > 0 {
                return CheckoutPositionSummary(
                    headline: "Merged · \(behind) behind \(shortBase)",
                    detail: wt.hasUncommittedChanges
                        ? "\(wt.workingTreeStatus.breakdownSummary) on top of an ancestor of \(shortBase)."
                        : "No unmerged commits (\(behind) behind \(shortBase)) — safe to prune.",
                    tone: wt.hasUncommittedChanges ? .amber : .emerald,
                    fullHeadHash: fullHeadHash,
                    shortHeadHash: shortSHA
                )
            }

            var relParts = ["\(ahead) ahead"]
            if behind > 0 { relParts.append("\(behind) behind") }
            return CheckoutPositionSummary(
                headline: "\(relParts.joined(separator: " · ")) of \(shortBase)",
                detail: wt.hasUncommittedChanges
                    ? wt.workingTreeStatus.breakdownSummary
                    : (cmp.unpushedCount > 0 ? "\(cmp.unpushedCount) local commit\(cmp.unpushedCount == 1 ? "" : "s") not pushed yet" : "Clean working tree · awaiting merge into \(shortBase)"),
                tone: wt.hasUncommittedChanges ? .amber : .blue,
                fullHeadHash: fullHeadHash,
                shortHeadHash: shortSHA
            )
        }

        return CheckoutPositionSummary(
            headline: wt.branchName ?? wt.name,
            detail: wt.workingTreeStatus.breakdownSummary,
            tone: wt.hasUncommittedChanges ? .amber : .neutral,
            fullHeadHash: fullHeadHash,
            shortHeadHash: shortSHA
        )
    }

    // MARK: - Structured Working-Tree File Changes + Diff Stats

    private static func fetchWorkingTreeChanges(at worktreePath: String) -> [WorkingTreeFileChange] {
        guard let statusRes = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "status", "--porcelain=v1", "-uall"]
        ), statusRes.succeeded else {
            return []
        }

        // Optional fast diffstat against HEAD (`git diff HEAD --numstat`)
        var statsByPath: [String: (add: Int, del: Int)] = [:]
        if let diffRes = try? ShellRunner.run(
            executable: "git",
            arguments: ["--no-optional-locks", "-C", worktreePath, "diff", "HEAD", "--numstat"]
        ), diffRes.succeeded {
            for rawLine in diffRes.stdout.split(whereSeparator: \.isNewline) {
                let parts = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                if let a = Int(parts[0]), let d = Int(parts[1]) {
                    statsByPath[String(parts[2])] = (a, d)
                }
            }
        }

        let conflictPairs: Set<String> = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"]
        var items: [WorkingTreeFileChange] = []

        for rawLine in statusRes.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }
            let xy = String(line.prefix(2))
            let rawPath = String(line.dropFirst(3))
            let displayPath: String
            if let arrowRange = rawPath.range(of: " -> ") {
                displayPath = String(rawPath[arrowRange.upperBound...])
            } else {
                displayPath = rawPath
            }

            let x = xy.first ?? " "
            let y = xy.last ?? " "

            let kind: WorkingTreeChangeKind
            let isStaged: Bool

            if conflictPairs.contains(xy) {
                kind = .conflicted
                isStaged = false
            } else if xy == "??" {
                kind = .untracked
                isStaged = false
            } else if x == "R" || y == "R" {
                kind = .renamed
                isStaged = x != " "
            } else if x == "A" {
                kind = .added
                isStaged = y == " "
            } else if x == "D" || y == "D" {
                kind = .deleted
                isStaged = y == " "
            } else {
                kind = .modified
                isStaged = y == " " && x != " "
            }

            let stat = statsByPath[displayPath] ?? statsByPath[rawPath]
            items.append(
                WorkingTreeFileChange(
                    path: displayPath,
                    status: kind,
                    isStaged: isStaged,
                    additions: stat?.add,
                    deletions: stat?.del
                )
            )
        }

        return items
    }

    // MARK: - Local Branch Hygiene & Relationship Inspection

    private static func loadLocalBranches(
        repoPath: String,
        project: ProjectGroup
    ) -> (branches: [LocalBranchInfo], hasRemote: Bool) {
        guard FileManager.default.fileExists(atPath: repoPath) else {
            return ([], false)
        }

        let preferred = GitWorktreeService.resolvePreferredBase(
            in: repoPath,
            gitCommonDir: project.gitCommonDir
        )

        let baseBranchName: String? = {
            if let local = preferred.localBase {
                return local
            }
            if let remote = preferred.remoteBase, remote.hasPrefix("origin/") {
                return String(remote.dropFirst("origin/".count))
            }
            if let mainBranch = project.mainWorktree?.branchName, !mainBranch.isEmpty {
                return mainBranch
            }
            return nil
        }()

        // Worktrees and standalone branches share the same configured integration target.
        let effectiveBaseRef = preferred.remoteBase ?? preferred.localBase

        let displayBaseLabel: String? = {
            guard let ref = effectiveBaseRef else { return nil }
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }()

        let cachedBaseTreeOID: String? = {
            guard let base = effectiveBaseRef else { return nil }
            guard let res = try? ShellRunner.run(
                executable: "git",
                arguments: ["--no-optional-locks", "-C", repoPath, "rev-parse", "--verify", "\(base)^{tree}"]
            ), res.succeeded else {
                return nil
            }
            let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        var worktreeByBranch: [String: WorktreeItem] = [:]
        for wt in project.worktrees where wt.kind != .prunable {
            if let branch = wt.branchName, !branch.isEmpty {
                worktreeByBranch[branch] = wt
            }
        }

        let format = "%(refname:short)\t%(objectname)\t%(objectname:short)\t%(committerdate:unix)\t%(upstream:short)\t%(upstream:track)\t%(contents:subject)"
        guard let refsRes = try? ShellRunner.run(
            executable: "git",
            arguments: [
                "--no-optional-locks",
                "-C", repoPath,
                "for-each-ref",
                "--sort=-committerdate",
                "--format=\(format)",
                "refs/heads"
            ]
        ), refsRes.succeeded else {
            return ([], preferred.hasRemote)
        }

        var branches: [LocalBranchInfo] = []
        var sawRemoteUpstream = preferred.hasRemote
        let now = Date()

        for rawLine in refsRes.stdout.split(whereSeparator: \.isNewline) {
            let parts = String(rawLine).split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7 else { continue }

            let name = parts[0]
            let fullHash = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let shortHash = parts[2]
            let committedAt: Date? = TimeInterval(parts[3]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let relativeAge = committedAt.map { RelativeTimeFormatting.shortAgeString(from: $0, now: now) } ?? ""
            let idleDays = committedAt.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) } ?? 0
            let rawUpstream = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTrack = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = parts[6]

            if !rawUpstream.isEmpty {
                sawRemoteUpstream = true
            }

            let trackParsed = parseUpstreamTrackToken(rawTrack)
            let upstreamRef: String? = rawUpstream.isEmpty ? nil : rawUpstream
            let checkedWT = worktreeByBranch[name]

            if name == baseBranchName {
                branches.append(
                    LocalBranchInfo(
                        name: name,
                        fullHash: fullHash,
                        shortHash: shortHash,
                        subject: subject,
                        committedAt: committedAt,
                        relativeTime: relativeAge,
                        idleDays: idleDays,
                        upstreamRef: upstreamRef,
                        isUpstreamGone: trackParsed.isGone,
                        aheadOfUpstream: trackParsed.ahead,
                        behindUpstream: trackParsed.behind,
                        baseRef: nil,
                        aheadOfBase: 0,
                        behindBase: 0,
                        checkedOutWorktreeID: checkedWT?.id,
                        checkedOutWorktreeName: checkedWT?.name,
                        relationship: .baseTrunk
                    )
                )
                continue
            }

            var comparisonVerified = false
            var aheadOfBase = 0
            var behindBase = 0
            if let base = effectiveBaseRef,
               let countRes = try? ShellRunner.run(
                   executable: "git",
                   arguments: ["--no-optional-locks", "-C", repoPath, "rev-list", "--left-right", "--count", "\(base)...refs/heads/\(name)"]
               ), countRes.succeeded {
                let nums = countRes.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .compactMap { Int($0) }
                if nums.count >= 2 {
                    comparisonVerified = true
                    behindBase = nums[0]
                    aheadOfBase = nums[1]
                }
            }

            let relationship: LocalBranchRelationship
            if !comparisonVerified {
                relationship = upstreamRef != nil ? .activePROrTracked : .localExperiment
            } else if aheadOfBase == 0 {
                relationship = .mergedIntoBase(viaSquashOrRebase: false, upstreamGone: trackParsed.isGone)
            } else if let base = effectiveBaseRef,
                      GitWorktreeService.isBranchMergedViaTree(
                          at: repoPath,
                          baseRef: base,
                          branchRef: "refs/heads/\(name)",
                          cachedBaseTreeOID: cachedBaseTreeOID
                      ) {
                relationship = .mergedIntoBase(viaSquashOrRebase: true, upstreamGone: trackParsed.isGone)
            } else if trackParsed.isGone {
                relationship = .upstreamGoneUnmerged
            } else if upstreamRef != nil {
                relationship = .activePROrTracked
            } else {
                relationship = .localExperiment
            }

            branches.append(
                LocalBranchInfo(
                    name: name,
                    fullHash: fullHash,
                    shortHash: shortHash,
                    subject: subject,
                    committedAt: committedAt,
                    relativeTime: relativeAge,
                    idleDays: idleDays,
                    upstreamRef: upstreamRef,
                    isUpstreamGone: trackParsed.isGone,
                    aheadOfUpstream: trackParsed.ahead,
                    behindUpstream: trackParsed.behind,
                    baseRef: displayBaseLabel,
                    aheadOfBase: aheadOfBase,
                    behindBase: behindBase,
                    checkedOutWorktreeID: checkedOutWorktreeID(for: checkedWT),
                    checkedOutWorktreeName: checkedWT?.name,
                    relationship: relationship
                )
            )
        }

        return (branches, sawRemoteUpstream)
    }

    private static func checkedOutWorktreeID(for worktree: WorktreeItem?) -> String? {
        worktree?.id
    }

    private static func parseUpstreamTrackToken(_ raw: String) -> (isGone: Bool, ahead: Int, behind: Int) {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            return (false, 0, 0)
        }
        let inner = String(raw.dropFirst().dropLast())
        if inner == "gone" {
            return (true, 0, 0)
        }
        var ahead = 0
        var behind = 0
        for part in inner.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ahead "), let n = Int(trimmed.dropFirst("ahead ".count)) {
                ahead = n
            } else if trimmed.hasPrefix("behind "), let n = Int(trimmed.dropFirst("behind ".count)) {
                behind = n
            }
        }
        return (false, ahead, behind)
    }
}
