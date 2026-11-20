import AppKit
import GroveCore
import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: AppViewModel
    @LocalState private var collapsedProjectIDs: Set<String> = []
    @LocalState private var expandedDirtyWorktreeIDs: Set<String> = []

    var body: some View {
        let entries = viewModel.dashboardEntries

        Group {
            if entries.isEmpty {
                emptyDashboardState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            ProjectOutlineSection(
                                entry: entry,
                                isCollapsed: collapsedProjectIDs.contains(entry.id),
                                viewModel: viewModel,
                                expandedDirtyWorktreeIDs: $expandedDirtyWorktreeIDs,
                                onToggleCollapse: {
                                    withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                                        if collapsedProjectIDs.contains(entry.id) {
                                            collapsedProjectIDs.remove(entry.id)
                                        } else {
                                            collapsedProjectIDs.insert(entry.id)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyDashboardState: some View {
        if viewModel.isScanning || viewModel.isLoadingSnapshots {
            ContentUnavailableView {
                GroveAppIconLoader(size: 72)
            } description: {
                Text(viewModel.statusMessage)
            }
        } else if viewModel.allDashboardEntries.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("All Clear")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(GrovePalette.teal)
                }
            } description: {
                Text("No idle branches or linked worktrees across \(viewModel.projects.count) scanned repositor\(viewModel.projects.count == 1 ? "y" : "ies").")
            } actions: {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        } else {
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease")
            } description: {
                if !viewModel.searchText.isEmpty {
                    Text("No idle branches or worktrees match “\(viewModel.searchText)”.")
                } else {
                    Text("No items in “\(viewModel.activeFilter.title)”.")
                }
            } actions: {
                Button("Reset Filters") {
                    viewModel.activeFilter = .all
                    viewModel.selectedFolderID = nil
                    viewModel.searchText = ""
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - Foldable Indented Project Section (Level 0 = Main Worktree + Main Branch, Level 1 = Worktrees & Idle Branches)

private struct ProjectOutlineSection: View {
    let entry: DashboardProjectEntry
    let isCollapsed: Bool
    @Bindable var viewModel: AppViewModel
    @Binding var expandedDirtyWorktreeIDs: Set<String>
    let onToggleCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProjectMainRowView(
                entry: entry,
                isCollapsed: isCollapsed,
                viewModel: viewModel,
                onToggleCollapse: onToggleCollapse
            )

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    // Idle branches live inside the main repo, so they immediately follow the main worktree
                    ForEach(entry.idleBranches) { branch in
                        LocalBranchRowView(
                            branch: branch,
                            project: entry.project,
                            viewModel: viewModel
                        )
                    }

                    // Linked worktrees sit below with their directory paths
                    ForEach(entry.worktrees) { wt in
                        ProjectWorktreeRowView(
                            worktree: wt,
                            project: entry.project,
                            snapshot: entry.snapshot,
                            isHighlighted: false,
                            isExpandedChanges: expandedDirtyWorktreeIDs.contains(wt.id),
                            viewModel: viewModel,
                            onToggleChanges: {
                                toggleExpandedChanges(for: wt)
                            }
                        )
                    }
                }
                .padding(.leading, 28)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .padding(.leading, 17)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func toggleExpandedChanges(for worktree: WorktreeItem) {
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            if expandedDirtyWorktreeIDs.contains(worktree.id) {
                expandedDirtyWorktreeIDs.remove(worktree.id)
            } else {
                expandedDirtyWorktreeIDs.insert(worktree.id)
                viewModel.loadChangedFilesIfNeeded(for: worktree)
            }
        }
    }
}

// MARK: - Level 0: Project Row (Represents Main Worktree + Main Branch)

private struct ProjectMainRowView: View {
    let entry: DashboardProjectEntry
    let isCollapsed: Bool
    @Bindable var viewModel: AppViewModel
    let onToggleCollapse: () -> Void
    @LocalState private var isHovering: Bool = false

    private static let groveEmerald = RowDismissButton.groveEmerald

    private var project: ProjectGroup { entry.project }
    private var mainWorktree: WorktreeItem? { project.mainWorktree }
    private var targetPath: String { mainWorktree?.path ?? project.primaryPath }

    private var headCommit: GitCommitSummary? {
        guard let wt = mainWorktree else { return nil }
        return WorktreeHygieneEvaluator.headCommit(for: wt, snapshot: entry.snapshot)
    }

    private var mainBranchLabel: String? {
        if let branch = mainWorktree?.branchName, !branch.isEmpty {
            return branch
        }
        return entry.snapshot?.localBranches.first(where: { $0.relationship == .baseTrunk })?.name
    }

    private var shortHashText: String {
        headCommit?.shortHash ?? mainWorktree?.headCommitShort ?? ""
    }

    private var ageText: String {
        if let committedAt = headCommit?.committedAt {
            return RelativeTimeFormatting.shortAgeString(from: committedAt)
        }
        if let rel = headCommit?.relativeTime, !rel.isEmpty {
            return rel
        }
        if let mod = mainWorktree?.lastModified {
            return RelativeTimeFormatting.shortAgeString(from: mod)
        }
        return ""
    }

    private var upstreamSummaryText: String? {
        guard let comp = mainWorktree?.gitComparison, let upstream = comp.upstreamRef else {
            return nil
        }
        if comp.unpushedCount == 0 && comp.behindUpstreamCount == 0 {
            return "Up to date with \(upstream)"
        }
        var parts: [String] = []
        if comp.unpushedCount > 0 { parts.append("↑\(comp.unpushedCount)") }
        if comp.behindUpstreamCount > 0 { parts.append("↓\(comp.behindUpstreamCount)") }
        return "\(parts.joined(separator: " ")) vs \(upstream)"
    }

    private var itemSummaryText: String {
        var parts: [String] = []
        if !entry.worktrees.isEmpty {
            parts.append("\(entry.worktrees.count) worktree\(entry.worktrees.count == 1 ? "" : "s")")
        }
        if !entry.idleBranches.isEmpty {
            parts.append("\(entry.idleBranches.count) branch\(entry.idleBranches.count == 1 ? "" : "es")")
        }
        return parts.joined(separator: " · ")
    }

    private var isFetching: Bool {
        viewModel.isFetchingOrigin(project.id)
    }

    private var isMainGitBusy: Bool {
        guard let wt = mainWorktree else { return false }
        return viewModel.busyWorktreeIDs.contains(wt.id)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let editorName = viewModel.configuration.resolvedEditorLabel
        let shellName = viewModel.configuration.resolvedTerminalLabel
        let isCleaningBranches = entry.removableBranches.contains {
            viewModel.deletingBranchKeys.contains(viewModel.branchBusyKey($0.name, in: project.id))
        }

        HStack(spacing: 8) {
            // Fold / Unfold disclosure chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 14, height: 18)

            OcticonGlyph(kind: .repo, size: 14)
                .foregroundStyle(GrovePalette.slate)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2.5) {
                // Line 1: Project Name + Main Branch pill + Main Worktree status pills + child count
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let branch = mainBranchLabel {
                        GroveBranchPill(name: branch)
                    }

                    mainWorktreeStatusPills

                    Text(itemSummaryText)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // Line 2: Always show project path + upstream status + latest commit subject
                HStack(spacing: 6) {
                    Text(project.displayPath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let upstream = upstreamSummaryText {
                        Text("·")
                            .foregroundStyle(.quaternary)

                        Text(upstream)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let subject = headCommit?.subject, !subject.isEmpty {
                        Text("·")
                            .foregroundStyle(.quaternary)

                        Text(subject)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 8)

            // Trailing quick actions, hash, age, and 26x26 menu slot (pixel-aligned with worktree & branch rows)
            HStack(spacing: 8) {
                if isMainGitBusy || isFetching {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    HStack(spacing: 4) {
                        if !entry.prunableWorktrees.isEmpty {
                            GroveIconButton(
                                systemImage: "scissors",
                                tint: GrovePalette.slate,
                                tooltip: "Prune \(entry.prunableWorktrees.count) missing worktree record\(entry.prunableWorktrees.count == 1 ? "" : "s")"
                            ) {
                                viewModel.pruneGhostWorktrees(in: project)
                            }
                        }

                        mainQuickActions
                    }
                }

                Text(shortHashText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .trailing)

                Text(ageText)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)

                Menu {
                    if !entry.removableBranches.isEmpty {
                        Button("Clean \(entry.removableBranches.count) Merged Branch\(entry.removableBranches.count == 1 ? "" : "es")") {
                            viewModel.cleanMergedBranches(in: project)
                        }
                        .disabled(isCleaningBranches || viewModel.isProjectBusy(project.id))

                        Divider()
                    }

                    Button("Open in \(editorName)") {
                        viewModel.openInEditor(path: targetPath)
                    }
                    Button("Open in \(shellName)") {
                        viewModel.openInTerminal(path: targetPath)
                    }
                    Button("Reveal in Finder") {
                        viewModel.revealInFinder(path: targetPath)
                    }
                    Button("Copy Path") {
                        viewModel.copyPathToPasteboard(targetPath)
                    }

                    Divider()

                    if entry.hasRemote {
                        Button("Fetch & Prune Origin") {
                            viewModel.fetchOrigin(for: project)
                        }
                        .disabled(isFetching)
                    }

                    Button("Integration Target…") {
                        viewModel.pendingIntegrationTargetProject = project
                    }

                    Divider()

                    Button("Delete Entire Project…", role: .destructive) {
                        viewModel.pendingProjectRemoval = project
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(isHovering ? .primary : GrovePalette.slate)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isHovering ? GrovePalette.controlHover : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .help("Project actions for '\(project.name)'")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(isHovering ? GrovePalette.rowHover : Color.clear))
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .onTapGesture {
            onToggleCollapse()
        }
        .contextMenu {
            Button(isCollapsed ? "Expand Project" : "Collapse Project") {
                onToggleCollapse()
            }
            Divider()
            Button("Open in \(editorName)") {
                viewModel.openInEditor(path: targetPath)
            }
            Button("Open in \(shellName)") {
                viewModel.openInTerminal(path: targetPath)
            }
            Button("Reveal in Finder") {
                viewModel.revealInFinder(path: targetPath)
            }
            Button("Copy Path") {
                viewModel.copyPathToPasteboard(targetPath)
            }
            Divider()
            if entry.hasRemote {
                Button("Fetch & Prune Origin") {
                    viewModel.fetchOrigin(for: project)
                }
                .disabled(isFetching)
            }
            Button("Integration Target…") {
                viewModel.pendingIntegrationTargetProject = project
            }
            Divider()
            Button("Delete Entire Project…", role: .destructive) {
                viewModel.pendingProjectRemoval = project
            }
        }
    }

    @ViewBuilder
    private var mainWorktreeStatusPills: some View {
        if let wt = mainWorktree {
            if wt.isDetached {
                DeterministicTagPill(label: "Detached", icon: .gitCommit, solidColor: GrovePalette.slate)
            }
            if wt.workingTreeStatus.conflictCount > 0 {
                DeterministicTagPill(label: "Conflict", icon: .alert, solidColor: GrovePalette.rose)
            } else if wt.dirtyFilesCount > 0 {
                DeterministicTagPill(label: "\(wt.dirtyFilesCount) Uncommitted", icon: .diffModified, solidColor: GrovePalette.attention)
            } else if case let .needsPush(count, _) = wt.actionState, count > 0, !wt.isDetached {
                DeterministicTagPill(label: "\(count) Unpushed", icon: .upload, solidColor: GrovePalette.cobalt)
            }
        }
    }

    @ViewBuilder
    private var mainQuickActions: some View {
        HStack(spacing: 4) {
            if let wt = mainWorktree {
                if wt.hasUncommittedChanges && wt.workingTreeStatus.conflictCount == 0 {
                    GroveIconButton(
                        systemImage: "checkmark.circle",
                        tint: GrovePalette.attention,
                        tooltip: "Commit \(wt.dirtyFilesCount) changed file\(wt.dirtyFilesCount == 1 ? "" : "s") in '\(project.name)'…"
                    ) {
                        viewModel.pendingCommitCheckout = PendingCommitCheckout(
                            project: project,
                            worktree: wt
                        )
                    }
                } else if case let .needsPush(count, _) = wt.actionState,
                          count > 0,
                          !wt.isDetached,
                          wt.gitComparison?.hasRemote == true {
                    GroveIconButton(
                        systemImage: "arrow.up.circle",
                        tint: GrovePalette.cobalt,
                        tooltip: "Push \(count) commit\(count == 1 ? "" : "s") to remote"
                    ) {
                        viewModel.pushCheckout(wt, in: project)
                    }
                }
            }

            if entry.hasRemote {
                GroveIconButton(
                    systemImage: "arrow.down.to.line",
                    tooltip: "Fetch & prune 'origin'"
                ) {
                    viewModel.fetchOrigin(for: project)
                }
            }

            GroveIconButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                tooltip: "Open '\(project.name)' in \(viewModel.configuration.resolvedEditorLabel)"
            ) {
                viewModel.openInEditor(path: targetPath)
            }

            GroveIconButton(
                systemImage: "terminal",
                tooltip: "Open '\(project.name)' in \(viewModel.configuration.resolvedTerminalLabel)"
            ) {
                viewModel.openInTerminal(path: targetPath)
            }
        }
    }
}

// MARK: - Level 1: Idle Local Branch Row

private struct LocalBranchRowView: View {
    let branch: LocalBranchInfo
    let project: ProjectGroup
    @Bindable var viewModel: AppViewModel
    @LocalState private var isHovering: Bool = false

    private static let groveEmerald = RowDismissButton.groveEmerald

    private var isDeleting: Bool {
        viewModel.deletingBranchKeys.contains(viewModel.branchBusyKey(branch.name, in: project.id))
    }

    private var isIdleUnmerged: Bool {
        branch.idleDays >= 14 && !branch.relationship.isMergedIntoBase && branch.relationship != .baseTrunk
    }

    private var comparisonSummaryText: String? {
        let baseName = branch.baseRef ?? "main"
        switch branch.relationship {
        case .baseTrunk:
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
            OcticonGlyph(kind: .gitBranch, size: 13.5)
                .foregroundStyle(branch.isSafeToRemove ? GrovePalette.merged : GrovePalette.slate)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(branch.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    deterministicTagsRow
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
                    .frame(width: 60, alignment: .trailing)

                Text(branch.relativeTime)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)

                if isDeleting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 26, height: 26)
                } else {
                    RowDismissButton(isSafe: branch.isSafeToRemove) {
                        viewModel.requestDeleteBranch(branch, in: project)
                    }
                    .help(
                        branch.isSafeToRemove
                            ? "Delete merged branch '\(branch.name)'"
                            : "Delete branch '\(branch.name)' (prompts with risk details)…"
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            shape.fill(isHovering ? GrovePalette.rowHover : Color.clear)
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
            Divider()
            Button(
                branch.isSafeToRemove ? "Delete Branch" : "Delete Branch…",
                role: .destructive
            ) {
                viewModel.requestDeleteBranch(branch, in: project)
            }
        }
    }

    @ViewBuilder
    private var deterministicTagsRow: some View {
        switch branch.relationship {
        case .baseTrunk:
            EmptyView()

        case let .mergedIntoBase(viaSquash, _):
            if viaSquash {
                DeterministicTagPill(label: "Squash-Merged", icon: .gitMerge, solidColor: GrovePalette.merged)
            } else {
                DeterministicTagPill(label: "Merged", icon: .gitMerge, solidColor: GrovePalette.merged)
            }

        case .activePROrTracked, .upstreamGoneUnmerged, .localExperiment:
            EmptyView()
        }

        if branch.isUpstreamGone {
            DeterministicTagPill(label: "Origin Gone", icon: .alert, solidColor: GrovePalette.attention)
        } else if branch.aheadOfUpstream > 0 && branch.relationship != .baseTrunk {
            DeterministicTagPill(label: "\(branch.aheadOfUpstream) Unpushed", icon: .upload, solidColor: GrovePalette.cobalt)
        }

        if isIdleUnmerged {
            DeterministicTagPill(label: "Idle \(branch.idleDays)d", icon: .clock, solidColor: GrovePalette.slate)
        }
    }
}
