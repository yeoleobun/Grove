import AppKit
import GroveCore
import SwiftUI

// MARK: - GitHub Primer Design System Palette (Official Light & Dark Tokens)

struct PrimerTone {
    let fg: Color
    let bg: Color
    let border: Color
}

enum GrovePalette {
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    // Core semantic foreground colors (used by icons, indicators, and buttons)
    /// GitHub Done Purple (`#8250DF` / `#A371F7`) — Merged
    static let merged = dynamic(light: (0.510, 0.314, 0.875, 1.0), dark: (0.639, 0.443, 0.969, 1.0))
    /// GitHub Success Green (`#1A7F37` / `#3FB950`) — Clean / Safe / All Clear
    static let teal = dynamic(light: (0.102, 0.498, 0.216, 1.0), dark: (0.247, 0.725, 0.314, 1.0))
    /// GitHub Accent Blue (`#0969DA` / `#58A6FF`) — Unpushed / Branch Ref / Push
    static let cobalt = dynamic(light: (0.035, 0.412, 0.855, 1.0), dark: (0.345, 0.651, 1.000, 1.0))
    /// GitHub Attention Amber (`#9A6700` / `#D29922`) — Uncommitted / Commit
    static let attention = dynamic(light: (0.604, 0.404, 0.000, 1.0), dark: (0.824, 0.600, 0.133, 1.0))
    /// GitHub Danger Red (`#CF222E` / `#F85149`) — Conflict / Orphaned / Destructive hover
    static let rose = dynamic(light: (0.812, 0.133, 0.180, 1.0), dark: (0.973, 0.318, 0.286, 1.0))
    /// GitHub Muted Neutral (`#59636E` / `#8B949E`) — Passive metadata & secondary icons
    static let slate = dynamic(light: (0.349, 0.388, 0.431, 1.0), dark: (0.545, 0.580, 0.620, 1.0))

    // GitHub Primer Surfaces
    static let rowHover = dynamic(light: (0.965, 0.973, 0.980, 1.0), dark: (0.086, 0.106, 0.133, 1.0))
    static let controlHover = dynamic(light: (0.918, 0.933, 0.949, 1.0), dark: (0.188, 0.212, 0.239, 1.0))
    static let divider = dynamic(light: (0.820, 0.851, 0.878, 1.0), dark: (0.188, 0.212, 0.239, 1.0))

    // GitHub Primer Label Tones (Official Primer `Label` fg + bg + 1pt border)
    static let doneTone = PrimerTone(
        fg: merged,
        bg: dynamic(light: (0.984, 0.937, 1.000, 1.0), dark: (0.537, 0.341, 0.898, 0.15)),
        border: dynamic(light: (0.510, 0.314, 0.875, 0.35), dark: (0.639, 0.443, 0.969, 0.40))
    )

    static let successTone = PrimerTone(
        fg: teal,
        bg: dynamic(light: (0.855, 0.984, 0.882, 1.0), dark: (0.137, 0.525, 0.212, 0.15)),
        border: dynamic(light: (0.102, 0.498, 0.216, 0.35), dark: (0.247, 0.725, 0.314, 0.40))
    )

    static let attentionTone = PrimerTone(
        fg: attention,
        bg: dynamic(light: (1.000, 0.973, 0.773, 1.0), dark: (0.733, 0.502, 0.035, 0.15)),
        border: dynamic(light: (0.831, 0.655, 0.173, 0.45), dark: (0.824, 0.600, 0.133, 0.40))
    )

    static let accentTone = PrimerTone(
        fg: cobalt,
        bg: dynamic(light: (0.867, 0.957, 1.000, 1.0), dark: (0.220, 0.545, 0.992, 0.15)),
        border: dynamic(light: (0.035, 0.412, 0.855, 0.35), dark: (0.345, 0.651, 1.000, 0.40))
    )

    static let dangerTone = PrimerTone(
        fg: rose,
        bg: dynamic(light: (1.000, 0.922, 0.914, 1.0), dark: (0.973, 0.318, 0.286, 0.15)),
        border: dynamic(light: (0.812, 0.133, 0.180, 0.35), dark: (0.973, 0.318, 0.286, 0.40))
    )

    static let neutralTone = PrimerTone(
        fg: slate,
        bg: dynamic(light: (0.937, 0.949, 0.961, 1.0), dark: (0.431, 0.463, 0.506, 0.18)),
        border: dynamic(light: (0.820, 0.851, 0.878, 1.0), dark: (0.431, 0.463, 0.506, 0.40))
    )
}

// MARK: - GitHub Primer Labels & Branch Tokens

/// Official GitHub Primer Solid PR State Pill — solid semantic fill + crisp white Octicon + white semibold text.
struct DeterministicTagPill: View {
    let label: String
    let icon: OcticonKind
    let solidColor: Color

    var body: some View {
        HStack(spacing: 4.5) {
            OcticonGlyph(kind: icon, size: 11.5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8.5)
        .frame(height: 20)
        .background(solidColor, in: Capsule(style: .continuous))
    }
}

/// Official GitHub Branch Ref token — soft accent-blue rounded rect (`r = 6`, monospace `#0969DA` on `#DDF4FF`).
struct GroveBranchPill: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            OcticonGlyph(kind: .gitBranch, size: 10.5)
            Text(name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(GrovePalette.cobalt)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(GrovePalette.accentTone.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - GitHub Primer Invisible Icon Buttons (`26×26`, `r = 6`)

struct GroveIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    let tooltip: String
    let action: () -> Void
    @LocalState private var isHovering: Bool = false

    var body: some View {
        let fg: Color = if let tint {
            tint
        } else {
            isHovering ? .primary : GrovePalette.slate
        }

        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(fg)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? GrovePalette.controlHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }
}

struct RowDismissButton: View {
    let isSafe: Bool
    let action: () -> Void
    @LocalState private var isHovering: Bool = false

    static let groveEmerald = GrovePalette.teal

    var body: some View {
        let fg: Color = if isSafe {
            GrovePalette.merged
        } else {
            isHovering ? GrovePalette.rose : GrovePalette.slate
        }
        let hoverFill: Color = isSafe
            ? GrovePalette.doneTone.bg
            : GrovePalette.dangerTone.bg

        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fg)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? hoverFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
        viewModel.changedFilesByWorktreeID[worktree.id]
    }

    private var leadingIconName: String {
        switch worktree.kind {
        case .main:
            return "tree"
        case .prunable:
            return "exclamationmark.triangle"
        case .linked:
            return "leaf"
        }
    }

    private var leadingIconColor: Color {
        if worktree.kind == .prunable {
            return GrovePalette.slate
        }
        if worktree.isSafeToRemoveLinkedWorktree {
            return GrovePalette.teal
        }
        return .secondary
    }

    /// Smart display path: relative path if nested inside the main repo (e.g. `.claude/worktrees/...`),
    /// otherwise tilde-shortened path (e.g. `~/.codex/worktrees/...`).
    private var smartWorktreePath: String {
        let primary = project.primaryPath.hasSuffix("/") ? project.primaryPath : (project.primaryPath + "/")
        if worktree.path.hasPrefix(primary) {
            return String(worktree.path.dropFirst(primary.count))
        }
        return worktree.displayPath
    }

    private var comparisonSummaryText: String? {
        if worktree.kind == .prunable {
            return "Directory missing"
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
                return nil
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
        return nil
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
                Group {
                    if worktree.kind == .prunable {
                        OcticonGlyph(kind: .alert, size: 13.5)
                            .foregroundStyle(GrovePalette.attention)
                    } else if worktree.kind == .main {
                        OcticonGlyph(kind: .repo, size: 14)
                            .foregroundStyle(GrovePalette.slate)
                    } else {
                        OcticonGlyph(kind: .fileDirectory, size: 14)
                            .foregroundStyle(worktree.isSafeToRemoveLinkedWorktree ? GrovePalette.merged : GrovePalette.slate)
                    }
                }
                .frame(width: 16)

                VStack(alignment: .leading, spacing: 2.5) {
                    // Line 1: Worktree name + branch ref + strictly deterministic Git tags
                    HStack(spacing: 6) {
                        Text(worktree.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let branch = worktree.branchName, !branch.isEmpty {
                            GroveBranchPill(name: branch)
                        }

                        deterministicTagsRow
                    }

                    // Line 2: Always show worktree directory path + comparison vs base + latest commit subject
                    HStack(spacing: 6) {
                        Text(smartWorktreePath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let comp = comparisonSummaryText, !comp.isEmpty {
                            Text("·")
                                .foregroundStyle(.quaternary)

                            Text(comp)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !commitSubjectText.isEmpty {
                            Text("·")
                                .foregroundStyle(.quaternary)

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

                    Text(shortHashText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .trailing)

                    Text(ageText)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)

                    trailingDismissSlot
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                shape.fill(
                    isHighlighted
                        ? GrovePalette.accentTone.bg
                        : (isHovering ? GrovePalette.rowHover : Color.clear)
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
            DeterministicTagPill(label: "Primary", icon: .gitBranch, solidColor: GrovePalette.slate)
        }

        if worktree.kind == .prunable {
            DeterministicTagPill(label: "Missing Folder", icon: .alert, solidColor: GrovePalette.attention)
        }

        if worktree.isDetached {
            DeterministicTagPill(label: "Detached", icon: .gitCommit, solidColor: GrovePalette.slate)
        }

        if isOrphanedDetached {
            DeterministicTagPill(label: "Orphaned", icon: .alert, solidColor: GrovePalette.rose)
        }

        if isAncestorMerged {
            DeterministicTagPill(label: "Merged", icon: .gitMerge, solidColor: GrovePalette.merged)
        } else if isSquashMerged {
            DeterministicTagPill(label: "Squash-Merged", icon: .gitMerge, solidColor: GrovePalette.merged)
        }

        if worktree.kind != .prunable {
            if worktree.workingTreeStatus.conflictCount > 0 {
                DeterministicTagPill(label: "Conflict", icon: .alert, solidColor: GrovePalette.rose)
            } else if worktree.dirtyFilesCount > 0 {
                DeterministicTagPill(label: "\(worktree.dirtyFilesCount) Uncommitted", icon: .diffModified, solidColor: GrovePalette.attention)
            } else if case let .needsPush(count, _) = worktree.actionState,
                      count > 0,
                      !worktree.isDetached {
                DeterministicTagPill(label: "\(count) Unpushed", icon: .upload, solidColor: GrovePalette.cobalt)
            }
        }

        if isIdleCommit {
            DeterministicTagPill(label: "Idle \(commitIdleDays)d", icon: .clock, solidColor: GrovePalette.slate)
        }
    }

    @ViewBuilder
    private var worktreeFolderActions: some View {
        HStack(spacing: 4) {
            if worktree.hasUncommittedChanges && worktree.workingTreeStatus.conflictCount == 0 {
                GroveIconButton(
                    systemImage: "checkmark.circle",
                    tint: GrovePalette.attention,
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
                GroveIconButton(
                    systemImage: "arrow.up.circle",
                    tint: GrovePalette.cobalt,
                    tooltip: "Push \(count) commit\(count == 1 ? "" : "s") to remote"
                ) {
                    viewModel.pushCheckout(worktree, in: project)
                }
            }

            GroveIconButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                tooltip: "Open '\(worktree.name)' in \(viewModel.configuration.resolvedEditorLabel)"
            ) {
                viewModel.openInEditor(path: worktree.path)
            }

            GroveIconButton(
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
        } else {
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
                viewModel.loadChangedFilesIfNeeded(for: worktree)
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
        case .modified: return GrovePalette.cobalt
        case .added: return GrovePalette.teal
        case .deleted, .conflicted: return GrovePalette.rose
        case .renamed: return GrovePalette.slate
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
