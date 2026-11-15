import GroveCore
import SwiftUI

// MARK: - Shared Deterministic Tag Pill & Dismiss Button (Used by Both Worktrees & Branches)

struct DeterministicTagPill: View {
    let label: String
    var systemImage: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 2.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
    }
}

struct RowDismissButton: View {
    let isSafe: Bool
    let action: () -> Void
    @LocalState private var isHovering: Bool = false

    static let groveEmerald = Color(red: 0.06, green: 0.66, blue: 0.45)

    var body: some View {
        let color: Color = isSafe ? Self.groveEmerald : .orange
        let shape = RoundedRectangle(cornerRadius: 6.5, style: .continuous)

        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isHovering ? color : color.opacity(0.82))
                .frame(width: 26, height: 26)
                .background(shape.fill(color.opacity(isHovering ? 0.16 : 0.08)))
                .overlay(shape.strokeBorder(isHovering ? color.opacity(0.45) : Color.clear, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RowQuickIconButton: View {
    let systemImage: String
    var tint: Color = .secondary
    let tooltip: String
    let action: () -> Void
    @LocalState private var isHovering: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? (tint == .secondary ? Color.primary : tint) : tint)
                .frame(width: 24, height: 24)
                .background(shape.fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }
}

// MARK: - Deterministic Worktree Hygiene Helpers (Commit-Timestamp Idle + Pure Git Truth)

enum WorktreeHygieneEvaluator {
    static func headCommit(for worktree: WorktreeItem, snapshot: ProjectHistorySnapshot?) -> GitCommitSummary? {
        snapshot?.headCommitsByWorktreeID[worktree.id] ?? worktree.gitComparison?.lastCommit
    }

    /// Computes idle days strictly from the HEAD commit timestamp (whether on a branch or detached HEAD),
    /// falling back to `worktree.lastModified` only if commit metadata is unavailable.
    static func commitIdleDays(for worktree: WorktreeItem, snapshot: ProjectHistorySnapshot?) -> Int {
        let anchorDate = headCommit(for: worktree, snapshot: snapshot)?.committedAt ?? worktree.lastModified
        guard let anchorDate else { return 0 }
        return max(0, Int(Date().timeIntervalSince(anchorDate) / 86_400))
    }

    static func isOrphanedDetached(_ worktree: WorktreeItem, snapshot: ProjectHistorySnapshot?) -> Bool {
        guard worktree.isDetached else { return false }
        return snapshot?.orphanedDetachedWorktreeIDs.contains(worktree.id) == true
    }

    static func isAncestorMergedIntoBase(_ worktree: WorktreeItem) -> Bool {
        guard worktree.kind != .main, worktree.kind != .prunable else { return false }
        guard let comp = worktree.gitComparison, comp.baseRef != nil else { return false }
        return comp.aheadOfBaseCount == 0
    }

    static func isSquashMergedIntoBase(_ worktree: WorktreeItem) -> Bool {
        guard worktree.kind != .main, worktree.kind != .prunable else { return false }
        guard let comp = worktree.gitComparison, comp.baseRef != nil else { return false }
        return comp.aheadOfBaseCount > 0 && comp.isSquashMergedIntoBase
    }

    static func isMergedOrPrunable(_ worktree: WorktreeItem) -> Bool {
        guard worktree.kind != .main else { return false }
        if worktree.kind == .prunable { return true }
        return isAncestorMergedIntoBase(worktree) || isSquashMergedIntoBase(worktree)
    }

    /// True when the worktree's HEAD commit (branch OR detached HEAD) is >= 14 days old and not already merged.
    static func hasIdleCommit(_ worktree: WorktreeItem, snapshot: ProjectHistorySnapshot?) -> Bool {
        let days = commitIdleDays(for: worktree, snapshot: snapshot)
        guard days >= 14 else { return false }
        if worktree.kind == .main {
            return worktree.isDetached && isOrphanedDetached(worktree, snapshot: snapshot)
        }
        if worktree.kind == .prunable {
            return false
        }
        return !isAncestorMergedIntoBase(worktree) && !isSquashMergedIntoBase(worktree)
    }
}

// MARK: - Unified Worktree Row (Matches `LocalBranchRowView` Style 1:1)

struct ProjectWorktreeRowView: View {
    let worktree: WorktreeItem
    let project: ProjectGroup
    let snapshot: ProjectHistorySnapshot?
    let isHighlighted: Bool
    let isExpandedChanges: Bool
    @Bindable var viewModel: AppViewModel
    let onToggleChanges: () -> Void

    @LocalState private var isHovering: Bool = false

    private static let groveEmerald = RowDismissButton.groveEmerald

    private var headCommit: GitCommitSummary? {
        WorktreeHygieneEvaluator.headCommit(for: worktree, snapshot: snapshot)
    }

    private var commitIdleDays: Int {
        WorktreeHygieneEvaluator.commitIdleDays(for: worktree, snapshot: snapshot)
    }

    private var isIdleCommit: Bool {
        WorktreeHygieneEvaluator.hasIdleCommit(worktree, snapshot: snapshot)
    }

    private var isOrphanedDetached: Bool {
        WorktreeHygieneEvaluator.isOrphanedDetached(worktree, snapshot: snapshot)
    }

    private var isAncestorMerged: Bool {
        WorktreeHygieneEvaluator.isAncestorMergedIntoBase(worktree)
    }

    private var isSquashMerged: Bool {
        WorktreeHygieneEvaluator.isSquashMergedIntoBase(worktree)
    }

    private var isDeleting: Bool {
        viewModel.deletingWorktreeIDs.contains(worktree.id)
    }

    private var isGitBusy: Bool {
        viewModel.busyWorktreeIDs.contains(worktree.id)
    }

    private var canExpandDirtyFiles: Bool {
        worktree.kind != .prunable && worktree.dirtyFilesCount > 0
    }

    private var changedFilesForThisWorktree: [WorkingTreeFileChange]? {
        guard let snapshot, snapshot.selectedWorktreeID == worktree.id else { return nil }
        return snapshot.changedFiles
    }

    private var leadingIconName: String {
        switch worktree.kind {
        case .main:
            return "house"
        case .prunable:
            return "exclamationmark.triangle"
        case .linked:
            return "folder"
        }
    }

    private var leadingIconColor: Color {
        if worktree.kind == .prunable {
            return .orange
        }
        if worktree.isSafeToRemoveLinkedWorktree {
            return Self.groveEmerald
        }
        return .secondary
    }

    private var comparisonSummaryText: String? {
        if worktree.kind == .prunable {
            return "Directory missing at \(worktree.displayPath)"
        }
        if let comp = worktree.gitComparison {
            if worktree.kind == .main {
                if let upstream = comp.upstreamRef {
                    if comp.unpushedCount == 0 && comp.behindUpstreamCount == 0 {
                        return "Up to date with \(upstream)"
                    }
                    var parts: [String] = []
                    if comp.unpushedCount > 0 { parts.append("↑\(comp.unpushedCount)") }
                    if comp.behindUpstreamCount > 0 { parts.append("↓\(comp.behindUpstreamCount)") }
                    return "\(parts.joined(separator: " ")) vs \(upstream)"
                }
                return worktree.displayPath
            }

            if let base = comp.baseRef {
                if comp.aheadOfBaseCount == 0 {
                    return comp.behindBaseCount > 0
                        ? "\(comp.behindBaseCount) behind \(base)"
                        : "Same commit as \(base)"
                }
                var parts: [String] = ["↑\(comp.aheadOfBaseCount) ahead"]
                if comp.behindBaseCount > 0 {
                    parts.append("↓\(comp.behindBaseCount) behind")
                }
                return "\(parts.joined(separator: " · ")) \(base)"
            }
        }
        return worktree.displayPath
    }

    private var commitSubjectText: String {
        headCommit?.subject ?? ""
    }

    private var shortHashText: String {
        headCommit?.shortHash ?? worktree.headCommitShort ?? ""
    }

    private var ageText: String {
        if let committedAt = headCommit?.committedAt {
            return RelativeTimeFormatting.shortAgeString(from: committedAt)
        }
        if let rel = headCommit?.relativeTime, !rel.isEmpty {
            return rel
        }
        if let mod = worktree.lastModified {
            return RelativeTimeFormatting.shortAgeString(from: mod)
        }
        return ""
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: leadingIconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(leadingIconColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2.5) {
                    // Line 1: Worktree name + branch ref + strictly deterministic Git tags
                    HStack(spacing: 6) {
                        Text(worktree.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let branch = worktree.branchName, !branch.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(branch)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                        }

                        deterministicTagsRow
                    }

                    // Line 2: Deterministic comparison vs base + latest commit subject
                    HStack(spacing: 6) {
                        if let comp = comparisonSummaryText, !comp.isEmpty {
                            Text(comp)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if !commitSubjectText.isEmpty {
                                Text("·")
                                    .foregroundStyle(.quaternary)
                            }
                        }

                        if !commitSubjectText.isEmpty {
                            Text(commitSubjectText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer(minLength: 8)

                // Trailing folder actions (`Editor` & `Terminal` belong to each worktree folder!) + metadata + 26×26 dismiss slot
                HStack(spacing: 8) {
                    if canExpandDirtyFiles {
                        Image(systemName: isExpandedChanges ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    if isGitBusy && !isDeleting {
                        ProgressView()
                            .controlSize(.mini)
                    } else if worktree.kind != .prunable {
                        worktreeFolderActions
                    }

                    if !shortHashText.isEmpty {
                        Text(shortHashText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if !ageText.isEmpty {
                        Text(ageText)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .trailing)
                    }

                    trailingDismissSlot
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                shape.fill(
                    isHighlighted
                        ? Color.accentColor.opacity(0.11)
                        : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
                )
            )
            .overlay(
                shape.strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .onTapGesture {
                if canExpandDirtyFiles {
                    onToggleChanges()
                }
            }
            .contextMenu {
                worktreeContextMenu
            }

            if isExpandedChanges && canExpandDirtyFiles {
                inlineWorkingTreeChanges
                    .padding(.leading, 26)
                    .padding(.trailing, 10)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Strictly Deterministic Git Tags ONLY

    @ViewBuilder
    private var deterministicTagsRow: some View {
        if worktree.kind == .main {
            DeterministicTagPill(label: "Primary", color: .secondary)
        }

        if worktree.kind == .prunable {
            DeterministicTagPill(label: "Missing folder", color: .orange)
        }

        if worktree.isDetached {
            DeterministicTagPill(label: "Detached", color: .orange)
        }

        if isOrphanedDetached {
            DeterministicTagPill(label: "Orphaned", color: .red)
        }

        if isAncestorMerged {
            DeterministicTagPill(label: "Merged", color: Self.groveEmerald)
        } else if isSquashMerged {
            DeterministicTagPill(label: "Squash-merged", color: .orange)
        }

        if worktree.kind != .prunable {
            if worktree.workingTreeStatus.conflictCount > 0 {
                DeterministicTagPill(label: "Conflict", color: .red)
            } else if worktree.dirtyFilesCount > 0 {
                DeterministicTagPill(label: "\(worktree.dirtyFilesCount) uncommitted", color: .orange)
            } else if case let .needsPush(count, _) = worktree.actionState,
                      count > 0,
                      !worktree.isDetached {
                DeterministicTagPill(label: "↑\(count) unpushed", color: .blue)
            }
        }

        if isIdleCommit {
            DeterministicTagPill(label: "idle \(commitIdleDays)d", systemImage: "zzz", color: .orange)
        }
    }

    @ViewBuilder
    private var worktreeFolderActions: some View {
        HStack(spacing: 4) {
            if worktree.hasUncommittedChanges && worktree.workingTreeStatus.conflictCount == 0 {
                RowQuickIconButton(
                    systemImage: "checkmark.circle",
                    tint: .orange,
                    tooltip: "Commit \(worktree.dirtyFilesCount) changed file\(worktree.dirtyFilesCount == 1 ? "" : "s")…"
                ) {
                    viewModel.pendingCommitCheckout = PendingCommitCheckout(
                        project: project,
                        worktree: worktree
                    )
                }
            } else if case let .needsPush(count, _) = worktree.actionState,
                      count > 0,
                      !worktree.isDetached,
                      worktree.gitComparison?.hasRemote == true {
                RowQuickIconButton(
                    systemImage: "arrow.up.circle",
                    tint: .blue,
                    tooltip: "Push \(count) commit\(count == 1 ? "" : "s") to remote"
                ) {
                    viewModel.pushCheckout(worktree, in: project)
                }
            }

            RowQuickIconButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                tooltip: "Open '\(worktree.name)' in \(viewModel.configuration.resolvedEditorLabel)"
            ) {
                viewModel.openInEditor(path: worktree.path)
            }

            RowQuickIconButton(
                systemImage: "terminal",
                tooltip: "Open '\(worktree.name)' in \(viewModel.configuration.resolvedTerminalLabel)"
            ) {
                viewModel.openInTerminal(path: worktree.path)
            }
        }
    }

    @ViewBuilder
    private var trailingDismissSlot: some View {
        if worktree.kind == .main {
            Color.clear.frame(width: 26, height: 26)
        } else if isDeleting {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 26, height: 26)
        } else if worktree.isSafeToRemoveLinkedWorktree || isIdleCommit || worktree.kind == .prunable || isHovering || isHighlighted {
            RowDismissButton(isSafe: worktree.isSafeToRemoveLinkedWorktree) {
                if worktree.kind == .prunable {
                    viewModel.pruneGhostWorktrees(in: project)
                } else {
                    viewModel.pendingWorktreeRemoval = PendingWorktreeRemoval(
                        project: project,
                        worktree: worktree
                    )
                }
            }
            .help(
                worktree.kind == .prunable
                    ? "Prune missing Git worktree record '\(worktree.name)'"
                    : (worktree.isSafeToRemoveLinkedWorktree
                        ? "Remove merged worktree '\(worktree.name)'…"
                        : "Remove worktree '\(worktree.name)' (prompts with safety check)…")
            )
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }

    @ViewBuilder
    private var inlineWorkingTreeChanges: some View {
        if let files = changedFilesForThisWorktree {
            if !files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { idx, change in
                        DetailWorkingTreeFileRow(
                            change: change,
                            worktreePath: worktree.path,
                            viewModel: viewModel
                        )
                        if idx < files.count - 1 {
                            Divider().padding(.leading, 26)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                )
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading \(worktree.dirtyFilesCount) uncommitted file\(worktree.dirtyFilesCount == 1 ? "" : "s")…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .onAppear {
                if viewModel.selectedWorktreeID != worktree.id {
                    viewModel.selectCheckout(projectID: project.id, worktreeID: worktree.id)
                }
            }
        }
    }

    @ViewBuilder
    private var worktreeContextMenu: some View {
        if worktree.kind != .prunable {
            Button("Open in \(viewModel.configuration.resolvedEditorLabel)") {
                viewModel.openInEditor(path: worktree.path)
            }
            Button("Open in \(viewModel.configuration.resolvedTerminalLabel)") {
                viewModel.openInTerminal(path: worktree.path)
            }
            Button("Reveal in Finder") {
                viewModel.revealInFinder(path: worktree.path)
            }
        }
        Button("Copy Worktree Path") {
            viewModel.copyPathToPasteboard(worktree.path)
        }
        if !shortHashText.isEmpty {
            Button("Copy Commit Hash (\(shortHashText))") {
                viewModel.copyPathToPasteboard(shortHashText)
            }
        }
        if worktree.kind != .prunable {
            if worktree.hasUncommittedChanges && worktree.workingTreeStatus.conflictCount == 0 {
                Divider()
                Button("Commit \(worktree.dirtyFilesCount) Changed File\(worktree.dirtyFilesCount == 1 ? "" : "s")…") {
                    viewModel.pendingCommitCheckout = PendingCommitCheckout(
                        project: project,
                        worktree: worktree
                    )
                }
            } else if case let .needsPush(count, _) = worktree.actionState,
                      count > 0,
                      !worktree.isDetached,
                      worktree.gitComparison?.hasRemote == true {
                Divider()
                Button("Push \(count) Commit\(count == 1 ? "" : "s") to Remote") {
                    viewModel.pushCheckout(worktree, in: project)
                }
            }
            if canExpandDirtyFiles {
                Button(isExpandedChanges ? "Hide Uncommitted Files" : "Show Uncommitted Files (\(worktree.dirtyFilesCount))") {
                    onToggleChanges()
                }
            }
        }
        if worktree.kind != .main {
            Divider()
            if worktree.kind == .prunable {
                Button("Prune Missing Worktree") {
                    viewModel.pruneGhostWorktrees(in: project)
                }
            } else {
                Button("Remove Worktree…", role: .destructive) {
                    viewModel.pendingWorktreeRemoval = PendingWorktreeRemoval(
                        project: project,
                        worktree: worktree
                    )
                }
            }
        }
    }
}

// MARK: - Inline Working-Tree File Row

private struct DetailWorkingTreeFileRow: View {
    let change: WorkingTreeFileChange
    let worktreePath: String
    @Bindable var viewModel: AppViewModel
    @LocalState private var isHovering: Bool = false

    private var fullFilePath: String {
        (worktreePath as NSString).appendingPathComponent(change.path)
    }

    private var statusColor: Color {
        switch change.status {
        case .modified: return .orange
        case .added: return RowDismissButton.groveEmerald
        case .deleted, .conflicted: return .red
        case .renamed: return .blue
        case .untracked: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(change.status.badgeLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 18, alignment: .center)

            Text(change.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if change.isStaged {
                Text("staged")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Spacer(minLength: 6)

            if change.additions != nil || change.deletions != nil {
                HStack(spacing: 5) {
                    if let add = change.additions, add > 0 {
                        Text("+\(add)")
                            .foregroundStyle(RowDismissButton.groveEmerald)
                    }
                    if let del = change.deletions, del > 0 {
                        Text("−\(del)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            viewModel.openInEditor(path: worktreePath)
        }
        .help("\(change.path) — double-click to open checkout in \(viewModel.configuration.resolvedEditorLabel)")
        .contextMenu {
            Button("Open Checkout in \(viewModel.configuration.resolvedEditorLabel)") {
                viewModel.openInEditor(path: worktreePath)
            }
            Button("Reveal File in Finder") {
                viewModel.revealInFinder(path: fullFilePath)
            }
            Button("Copy File Path") {
                viewModel.copyPathToPasteboard(fullFilePath)
            }
        }
    }
}

// MARK: - Integration Target Configuration Sheet

struct IntegrationTargetSheet: View {
    let project: ProjectGroup
    @Bindable var viewModel: AppViewModel
    @LocalState private var targetName: String = ""
    @LocalState private var targetError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Integration Target")
                .font(.title3.bold())

            Text("Grove compares every worktree and local branch in '\(project.name)' against this Git ref to detect merged items and ahead/behind commits.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("origin/main or main", text: $targetName)
                .textFieldStyle(.roundedBorder)

            if let targetError {
                Text(targetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    viewModel.pendingIntegrationTargetProject = nil
                }
                .buttonStyle(.glass)

                Spacer()

                Button("Save Target") {
                    do {
                        try GitWorktreeService.setIntegrationTarget(targetName, in: project.primaryPath)
                        viewModel.pendingIntegrationTargetProject = nil
                        viewModel.startScan()
                    } catch {
                        targetError = error.localizedDescription
                    }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear {
            targetName = project.worktrees.compactMap { $0.gitComparison?.baseRef }.first ?? "main"
        }
    }
}
