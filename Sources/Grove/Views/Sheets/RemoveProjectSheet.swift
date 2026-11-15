import GroveCore
import SwiftUI

struct RemoveProjectSheet: View {
    let project: ProjectGroup
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var removeLinkedWorktrees: Bool = true

    private var externalLinkedWorktrees: [WorktreeItem] {
        let primaryPrefix = PathNormalizer.canonicalPath(project.primaryPath) + "/"
        return project.linkedWorktrees.filter {
            !PathNormalizer.canonicalPath($0.path).hasPrefix(primaryPrefix)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository Summary") {
                    LabeledContent("Repository", value: project.name)
                    LabeledContent("Primary Folder") {
                        Text(project.displayPath)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    if let mainWT = project.mainWorktree {
                        LabeledContent("Primary Status", value: mainWT.actionState.label)
                    }
                }

                if !externalLinkedWorktrees.isEmpty {
                    Section("Linked Git Worktrees (\(externalLinkedWorktrees.count))") {
                        ForEach(externalLinkedWorktrees) { wt in
                            LabeledContent(wt.name) {
                                HStack(spacing: 6) {
                                    Text(wt.displayPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if wt.hasUncommittedChanges {
                                        Text("\(wt.dirtyFilesCount) dirty")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    if !externalLinkedWorktrees.isEmpty {
                        Toggle(
                            "Also clean up \(externalLinkedWorktrees.count) linked worktree(s)",
                            isOn: $removeLinkedWorktrees
                        )
                    }
                } header: {
                    Text("Cleanup Behavior")
                } footer: {
                    Text("Your primary repository folder (and any dirty linked worktrees) are moved safely to macOS Trash so nothing is permanently lost.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move Repository to Trash")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move to Trash", role: .destructive) {
                        let opts = ProjectRemovalOptions(removeLinkedWorktrees: removeLinkedWorktrees)
                        viewModel.confirmRemoveProject(project, options: opts)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 520, height: 380)
    }
}
