import GroveCore
import SwiftUI

struct CommitChangesSheet: View {
    let pending: PendingCommitCheckout
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var commitMessage: String = ""
    @LocalState private var pushAfterCommit: Bool

    init(pending: PendingCommitCheckout, viewModel: AppViewModel) {
        self.pending = pending
        self.viewModel = viewModel
        let canAutoPush = (pending.worktree.gitComparison?.hasRemote == true) && !pending.worktree.isDetached
        _pushAfterCommit = LocalState(initialValue: canAutoPush)
    }

    private var worktree: WorktreeItem { pending.worktree }
    private var project: ProjectGroup { pending.project }

    private var canPush: Bool {
        (worktree.gitComparison?.hasRemote == true) && !worktree.isDetached
    }

    private var trimmedMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Checkout") {
                    LabeledContent("Repository", value: project.name)
                    if worktree.kind != .main {
                        LabeledContent("Worktree", value: worktree.name)
                    }
                    if let branch = worktree.branchName {
                        LabeledContent("Branch", value: branch)
                    }
                    LabeledContent("Changes", value: worktree.workingTreeStatus.breakdownSummary)
                }

                Section("Commit Message") {
                    TextField("Describe your changes…", text: $commitMessage, axis: .vertical)
                        .lineLimit(2...4)

                    if canPush {
                        Toggle("Also push to remote after committing", isOn: $pushAfterCommit)
                    }
                }

                if !worktree.workingTreeStatus.sampleFiles.isEmpty {
                    Section("Files to Stage & Commit (\(worktree.dirtyFilesCount))") {
                        ForEach(worktree.workingTreeStatus.sampleFiles.prefix(12), id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if worktree.dirtyFilesCount > 12 {
                            Text("+ \(worktree.dirtyFilesCount - 12) more file(s)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Commit Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pushAfterCommit && canPush ? "Commit & Push" : "Commit") {
                        viewModel.commitCheckout(
                            worktree,
                            in: project,
                            message: trimmedMessage,
                            pushAfterCommit: pushAfterCommit && canPush
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedMessage.isEmpty)
                }
            }
        }
        .frame(width: 500, height: 420)
    }
}
