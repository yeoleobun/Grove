import GroveCore
import SwiftUI

struct RemoveWorktreeSheet: View {
    let pending: PendingWorktreeRemoval
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var removalMode: LinkedWorktreeRemovalMode
    @LocalState private var deleteBranch: Bool
    @LocalState private var forceDeleteBranch: Bool
    @LocalState private var preserveCommits: Bool = false
    @LocalState private var acknowledgeDirtyOrLocked: Bool = false

    init(pending: PendingWorktreeRemoval, viewModel: AppViewModel) {
        self.pending = pending
        self.viewModel = viewModel
        let defaultMode: LinkedWorktreeRemovalMode = (pending.worktree.hasUncommittedChanges || pending.worktree.workingTreeStatus.ignoredCount > 0)
            ? .trashSourceAndPrune
            : .gitWorktreeRemove
        _removalMode = LocalState(initialValue: defaultMode)
        _deleteBranch = LocalState(initialValue: pending.worktree.isSafeToRemoveLinkedWorktree)
        // Squash-merged branches are safe to delete, and require `git branch -D` since commit SHAs differ from main.
        _forceDeleteBranch = LocalState(initialValue: false)
    }

    private var worktree: WorktreeItem { pending.worktree }
    private var project: ProjectGroup { pending.project }

    private var requiresAcknowledgement: Bool {
        if worktree.isLocked { return true }
        if worktree.hasUncommittedChanges && removalMode == .gitWorktreeRemove {
            return true
        }
        return false
    }

    var body: some View {
        let state = worktree.actionState
        let isSafe = state.isRemovableWorktree

        NavigationStack {
            Form {
                Section("Worktree Summary") {
                    LabeledContent("Repository", value: project.name)
                    LabeledContent("Worktree", value: worktree.name)
                    if let branch = worktree.branchName {
                        LabeledContent("Branch", value: branch)
                    }
                    LabeledContent("Path") {
                        Text(worktree.displayPath)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Git Safety Check") {
                    Label(
                        worktree.statusTooltip.components(separatedBy: .newlines).first ?? state.label,
                        systemImage: isSafe ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(isSafe ? .green : .orange)

                    if !worktree.workingTreeStatus.sampleFiles.isEmpty {
                        ForEach(worktree.workingTreeStatus.sampleFiles.prefix(6), id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } else if let commits = worktree.gitComparison?.unmergedCommits, !commits.isEmpty, !isSafe {
                        ForEach(commits.prefix(5)) { commit in
                            Text("\(commit.shortHash)  \(commit.subject)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Removal Options") {
                    Toggle("Preserve commits in a recovery ref before removal", isOn: $preserveCommits)
                    Text("Required when original commits are not verified in the integration target. Recovery refs keep history available in this repository even for detached worktrees.")
                        .font(.caption).foregroundStyle(.secondary)
                    if worktree.workingTreeStatus.ignoredCount > 0 {
                        Text("Ignored files are present. Use Trash to preserve the folder’s local data.")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    Picker("Method", selection: $removalMode) {
                        Text("Git Remove (`git worktree remove`)").tag(LinkedWorktreeRemovalMode.gitWorktreeRemove)
                        Text("Move Folder to Trash & Prune Git").tag(LinkedWorktreeRemovalMode.trashSourceAndPrune)
                    }

                    if let branch = worktree.branchName, branch != "main", branch != "master" {
                        Toggle("Delete local branch `\(branch)`", isOn: $deleteBranch)
                        if deleteBranch {
                            Toggle("Force delete (`git branch -D`) if squash-merged or unmerged", isOn: $forceDeleteBranch)
                        }
                    }

                    if requiresAcknowledgement {
                        Toggle(
                            worktree.isLocked
                                ? "Unlock and remove this worktree anyway"
                                : "Permanently discard uncommitted files (`--force`)",
                            isOn: $acknowledgeDirtyOrLocked
                        )
                        .tint(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Remove Linked Worktree")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove Worktree", role: isSafe ? nil : .destructive) {
                        let opts = WorktreeRemovalOptions(
                            mode: removalMode,
                            forceIfDirtyOrLocked: acknowledgeDirtyOrLocked || removalMode == .trashSourceAndPrune,
                            deleteLocalBranch: deleteBranch,
                            forceDeleteBranch: forceDeleteBranch,
                            preserveCommits: preserveCommits
                        )
                        viewModel.confirmRemoveWorktree(worktree, in: project, options: opts)
                        dismiss()
                    }
                    .disabled((requiresAcknowledgement && !acknowledgeDirtyOrLocked)
                        || worktree.workingTreeStatus.inspectionError != nil
                        || (worktree.gitComparison?.baseRef == nil || worktree.gitComparison?.aheadOfBaseCount != 0) && !preserveCommits
                        || worktree.workingTreeStatus.ignoredCount > 0 && removalMode == .gitWorktreeRemove)
                }
            }
        }
        .frame(width: 580, height: 620)
    }
}
