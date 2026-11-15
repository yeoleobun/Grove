import AppKit
import GroveCore
import SwiftUI

struct CheckoutInspectorView: View {
    @Bindable var viewModel: AppViewModel
    @LocalState private var highlightedWorktreeID: String?
    @LocalState private var expandedDirtyWorktreeIDs: Set<String> = []

    private static let groveEmerald = RowDismissButton.groveEmerald

    var body: some View {
        if let project = viewModel.selectedProject {
            let snapshot = (viewModel.historySnapshot?.projectID == project.id) ? viewModel.historySnapshot : nil

            projectDetailPage(project: project, snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .navigationTitle(project.name)
                .navigationSubtitle(projectSubtitle(project: project, snapshot: snapshot))
                .toolbar {
                    let hasRemote = snapshot?.hasRemote ?? (project.mainWorktree?.gitComparison?.hasRemote == true)
                    if hasRemote {
                        ToolbarItem(placement: .primaryAction) {
                            fetchToolbarButton(project: project)
                        }
                    }
                }
                .onChange(of: project.id) { _, _ in
                    highlightedWorktreeID = nil
                    expandedDirtyWorktreeIDs.removeAll()
                }
        } else {
            ContentUnavailableView {
                Label("Select a Repository", systemImage: "folder")
            } description: {
                Text("Choose a project in the sidebar to inspect its worktrees and local branches.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Grove")
        }
    }

    // MARK: - Window Subtitle & Fetch Origin Button

    private func projectSubtitle(project: ProjectGroup, snapshot: ProjectHistorySnapshot?) -> String {
        let activeWTs = project.worktrees.filter { $0.kind != .prunable }.count
        var parts = ["\(activeWTs) worktree\(activeWTs == 1 ? "" : "s")"]
        if let snapshot {
            parts.append("\(snapshot.localBranches.count) branch\(snapshot.localBranches.count == 1 ? "" : "es")")
            if let base = snapshot.localBranches.first(where: { $0.relationship == .baseTrunk })?.name {
                parts.append("target: \(base)")
            }
        } else {
            parts.append(project.displayPath)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func fetchToolbarButton(project: ProjectGroup) -> some View {
        let isFetching = viewModel.isFetchingOrigin(project.id)

        Button {
            viewModel.fetchOrigin(for: project)
        } label: {
            if isFetching {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Fetch", systemImage: "arrow.down.to.line")
            }
        }
        .disabled(isFetching || viewModel.isProjectBusy(project.id))
        .help("Fetch & prune 'origin'")
    }

    // MARK: - Deterministic Ordering (`main` First for Both Worktree & Branch)

    private func sortedLinkedWorktrees(for project: ProjectGroup, snapshot: ProjectHistorySnapshot?) -> [WorktreeItem] {
        project.subWorktrees.sorted { lhs, rhs in
            let lMerged = WorktreeHygieneEvaluator.isMergedOrPrunable(lhs)
            let rMerged = WorktreeHygieneEvaluator.isMergedOrPrunable(rhs)
            if lMerged != rMerged {
                return lMerged
            }
            let lIdle = WorktreeHygieneEvaluator.hasIdleCommit(lhs, snapshot: snapshot)
            let rIdle = WorktreeHygieneEvaluator.hasIdleCommit(rhs, snapshot: snapshot)
            if lIdle != rIdle {
                return lIdle
            }
            let lDays = WorktreeHygieneEvaluator.commitIdleDays(for: lhs, snapshot: snapshot)
            let rDays = WorktreeHygieneEvaluator.commitIdleDays(for: rhs, snapshot: snapshot)
            if lIdle && rIdle && lDays != rDays {
                return lDays > rDays
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// `main` (`.baseTrunk`) FIRST, followed by merged -> idle -> active branches.
    private func branchPriorityRank(_ branch: LocalBranchInfo) -> Int {
        if branch.relationship == .baseTrunk {
            return 0
        }
        if branch.relationship.isMergedIntoBase && branch.checkedOutWorktreeID == nil {
            return 1
        }
        if branch.idleDays >= 14 && !branch.relationship.isMergedIntoBase && branch.checkedOutWorktreeID == nil {
            return 2
        }
        if branch.checkedOutWorktreeID == nil {
            return 3
        }
        return 4
    }

    private func sortedBranches(_ branches: [LocalBranchInfo]) -> [LocalBranchInfo] {
        branches.sorted { lhs, rhs in
            let lRank = branchPriorityRank(lhs)
            let rRank = branchPriorityRank(rhs)
            if lRank != rRank {
                return lRank < rRank
            }
            if lRank == 2 && lhs.idleDays != rhs.idleDays {
                return lhs.idleDays > rhs.idleDays
            }
            let lDate = lhs.committedAt ?? .distantPast
            let rDate = rhs.committedAt ?? .distantPast
            if lDate != rDate {
                return lDate > rDate
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Single Unified Page: (1) Main Worktree + Branches, (2) Linked Worktrees

    @ViewBuilder
    private func projectDetailPage(project: ProjectGroup, snapshot: ProjectHistorySnapshot?) -> some View {
        let mainWorktree = project.mainWorktree ?? project.worktrees.first
        let linkedWorktrees = sortedLinkedWorktrees(for: project, snapshot: snapshot)
        let orderedBranches = sortedBranches(snapshot?.localBranches ?? [])
        let removableBranches = snapshot?.removableBranches ?? []

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Part 1: Main Worktree + Local Branches
                    VStack(alignment: .leading, spacing: 14) {
                        if let mainWT = mainWorktree {
                            ProjectWorktreeRowView(
                                worktree: mainWT,
                                project: project,
                                snapshot: snapshot,
                                isHighlighted: highlightedWorktreeID == mainWT.id,
                                isExpandedChanges: expandedDirtyWorktreeIDs.contains(mainWT.id),
                                viewModel: viewModel,
                                onToggleChanges: {
                                    toggleExpandedChanges(for: mainWT, in: project)
                                }
                            )
                            .id("wt:\(mainWT.id)")
                        }

                        if snapshot != nil {
                            if !orderedBranches.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    branchesSectionHeader(
                                        project: project,
                                        totalCount: orderedBranches.count,
                                        removableBranches: removableBranches
                                    )

                                    VStack(spacing: 2) {
                                        ForEach(orderedBranches) { branch in
                                            LocalBranchRowView(
                                                branch: branch,
                                                project: project,
                                                mainWorktreeID: mainWorktree?.id,
                                                viewModel: viewModel,
                                                onFocusWorktree: { wtID in
                                                    focusWorktreeRow(wtID, proxy: proxy)
                                                }
                                            )
                                            .id("branch:\(branch.name)")
                                        }
                                    }
                                }
                            }
                        } else if viewModel.isLoadingHistory {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading local branches…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }

                    // Part 2: Other Worktrees (Linked & Prunable Worktree Folders)
                    if !linkedWorktrees.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            linkedWorktreesSectionHeader(
                                project: project,
                                count: linkedWorktrees.count
                            )

                            VStack(spacing: 2) {
                                ForEach(linkedWorktrees) { wt in
                                    ProjectWorktreeRowView(
                                        worktree: wt,
                                        project: project,
                                        snapshot: snapshot,
                                        isHighlighted: highlightedWorktreeID == wt.id,
                                        isExpandedChanges: expandedDirtyWorktreeIDs.contains(wt.id),
                                        viewModel: viewModel,
                                        onToggleChanges: {
                                            toggleExpandedChanges(for: wt, in: project)
                                        }
                                    )
                                    .id("wt:\(wt.id)")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func toggleExpandedChanges(for worktree: WorktreeItem, in project: ProjectGroup) {
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            if expandedDirtyWorktreeIDs.contains(worktree.id) {
                expandedDirtyWorktreeIDs.remove(worktree.id)
            } else {
                expandedDirtyWorktreeIDs.insert(worktree.id)
                viewModel.selectCheckout(projectID: project.id, worktreeID: worktree.id)
            }
        }
    }

    private func focusWorktreeRow(_ worktreeID: String, proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            highlightedWorktreeID = worktreeID
            proxy.scrollTo("wt:\(worktreeID)", anchor: .center)
        }
    }

    @ViewBuilder
    private func branchesSectionHeader(
        project: ProjectGroup,
        totalCount: Int,
        removableBranches: [LocalBranchInfo]
    ) -> some View {
        let isCleaning = removableBranches.contains {
            viewModel.deletingBranchKeys.contains(viewModel.branchBusyKey($0.name, in: project.id))
        }

        HStack(spacing: 6) {
            Text("Branches")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("\(totalCount)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            if !removableBranches.isEmpty {
                Button {
                    viewModel.cleanMergedBranches(in: project)
                } label: {
                    if isCleaning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Clean \(removableBranches.count) Merged")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Self.groveEmerald)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Self.groveEmerald.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .disabled(isCleaning || viewModel.isProjectBusy(project.id))
                .help("Delete \(removableBranches.count) safe merged local branch\(removableBranches.count == 1 ? "" : "es")")
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func linkedWorktreesSectionHeader(
        project: ProjectGroup,
        count: Int
    ) -> some View {
        HStack(spacing: 6) {
            Text("Worktrees")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            if !project.prunableWorktrees.isEmpty {
                Button {
                    viewModel.pruneGhostWorktrees(in: project)
                } label: {
                    Text("Prune \(project.prunableWorktrees.count) Missing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Local Branch Row (Strictly Deterministic Git Tags ONLY, `main` First)

private struct LocalBranchRowView: View {
    let branch: LocalBranchInfo
    let project: ProjectGroup
    let mainWorktreeID: String?
    @Bindable var viewModel: AppViewModel
    let onFocusWorktree: (String) -> Void
    @LocalState private var isHovering: Bool = false

    private static let groveEmerald = RowDismissButton.groveEmerald

    private var isDeleting: Bool {
        viewModel.deletingBranchKeys.contains(viewModel.branchBusyKey(branch.name, in: project.id))
    }

    private var isIdleUnmerged: Bool {
        branch.idleDays >= 14 && !branch.relationship.isMergedIntoBase && branch.relationship != .baseTrunk
    }

    private var shouldShowCheckedOutWorktreePill: Bool {
        guard let wtID = branch.checkedOutWorktreeID else { return false }
        if branch.relationship == .baseTrunk && wtID == mainWorktreeID {
            return false
        }
        return true
    }

    private var comparisonSummaryText: String? {
        let baseName = branch.baseRef ?? "main"
        switch branch.relationship {
        case .baseTrunk:
            if let upstream = branch.upstreamRef {
                if branch.aheadOfUpstream == 0 && branch.behindUpstream == 0 {
                    return "Up to date with \(upstream)"
                }
                var parts: [String] = []
                if branch.aheadOfUpstream > 0 { parts.append("↑\(branch.aheadOfUpstream)") }
                if branch.behindUpstream > 0 { parts.append("↓\(branch.behindUpstream)") }
                return "\(parts.joined(separator: " ")) vs \(upstream)"
            }
            return nil

        case .mergedIntoBase:
            var parts: [String] = []
            if branch.behindBase > 0 {
                parts.append("\(branch.behindBase) behind \(baseName)")
            } else {
                parts.append("Same commit as \(baseName)")
            }
            if branch.aheadOfUpstream > 0, let upstream = branch.upstreamRef, !branch.isUpstreamGone {
                parts.append("\(branch.aheadOfUpstream) unpushed to \(upstream) · needs -D")
            }
            return parts.joined(separator: " · ")

        case .activePROrTracked, .upstreamGoneUnmerged, .localExperiment:
            var parts: [String] = []
            if branch.aheadOfBase > 0 {
                parts.append("↑\(branch.aheadOfBase) ahead")
            }
            if branch.behindBase > 0 {
                parts.append("↓\(branch.behindBase) behind")
            }
            return parts.isEmpty ? "Even with \(baseName)" : "\(parts.joined(separator: " · ")) \(baseName)"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(branch.isSafeToRemove ? Self.groveEmerald : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(branch.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    deterministicTagsRow

                    if shouldShowCheckedOutWorktreePill,
                       let wtID = branch.checkedOutWorktreeID,
                       let wtName = branch.checkedOutWorktreeName {
                        Button {
                            onFocusWorktree(wtID)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text(wtName)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Checked out in worktree '\(wtName)' — click to highlight worktree")
                    }
                }

                HStack(spacing: 6) {
                    if let comp = comparisonSummaryText {
                        Text(comp)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !branch.subject.isEmpty {
                            Text("·")
                                .foregroundStyle(.quaternary)
                        }
                    }

                    if !branch.subject.isEmpty {
                        Text(branch.subject)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Text(branch.shortHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if !branch.relativeTime.isEmpty {
                    Text(branch.relativeTime)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }

                if case .baseTrunk = branch.relationship {
                    Color.clear.frame(width: 26, height: 26)
                } else if branch.checkedOutWorktreeID != nil {
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                        .frame(width: 26, height: 26)
                        .help("Checked out in '\(branch.checkedOutWorktreeName ?? "worktree")' — remove that worktree to delete this branch")
                } else if isDeleting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 26, height: 26)
                } else if isIdleUnmerged || branch.isSafeToRemove || branch.relationship.isMergedIntoBase || isHovering {
                    RowDismissButton(isSafe: branch.isSafeToRemove) {
                        viewModel.requestDeleteBranch(branch, in: project)
                    }
                    .help(
                        branch.isSafeToRemove
                            ? "Delete merged branch '\(branch.name)'"
                            : "Delete branch '\(branch.name)' (prompts with risk details)…"
                    )
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            shape.fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Branch Name (\(branch.name))") {
                viewModel.copyPathToPasteboard(branch.name)
            }
            Button("Copy Commit Hash (\(branch.shortHash))") {
                viewModel.copyPathToPasteboard(branch.shortHash)
            }
            if let wtID = branch.checkedOutWorktreeID,
               let wtName = branch.checkedOutWorktreeName {
                Divider()
                Button("Highlight Worktree '\(wtName)'") {
                    onFocusWorktree(wtID)
                }
            } else if branch.relationship != .baseTrunk {
                Divider()
                Button(
                    branch.isSafeToRemove ? "Delete Branch" : "Delete Branch…",
                    role: .destructive
                ) {
                    viewModel.requestDeleteBranch(branch, in: project)
                }
            }
        }
    }

    @ViewBuilder
    private var deterministicTagsRow: some View {
        switch branch.relationship {
        case .baseTrunk:
            DeterministicTagPill(label: "Base", color: .secondary)

        case let .mergedIntoBase(viaSquash, _):
            if viaSquash {
                DeterministicTagPill(label: "Squash-merged", color: .orange)
            } else {
                DeterministicTagPill(label: "Merged", color: Self.groveEmerald)
            }

        case .activePROrTracked, .upstreamGoneUnmerged, .localExperiment:
            EmptyView()
        }

        if branch.isUpstreamGone {
            DeterministicTagPill(label: "origin gone", color: .orange)
        } else if branch.aheadOfUpstream > 0 && branch.relationship != .baseTrunk {
            DeterministicTagPill(label: "↑\(branch.aheadOfUpstream) unpushed", color: .blue)
        }

        if isIdleUnmerged {
            DeterministicTagPill(label: "idle \(branch.idleDays)d", systemImage: "zzz", color: .orange)
        }
    }
}
