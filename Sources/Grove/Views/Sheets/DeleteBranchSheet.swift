import GroveCore
import SwiftUI

struct DeleteBranchSheet: View {
    let pending: PendingBranchDeletion
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var acknowledgeHighRiskUnmerged: Bool = false

    private var branch: LocalBranchInfo { pending.branch }
    private var project: ProjectGroup { pending.project }
    private var reason: BranchForceDeleteReason { pending.reason }

    private var requiresHighRiskToggle: Bool {
        reason.riskLevel == .high
    }

    private var riskAccentColor: Color {
        switch reason.riskLevel {
        case .low:
            return Color(red: 0.06, green: 0.66, blue: 0.45)
        case .medium:
            return .blue
        case .high:
            return .orange
        }
    }

    private var riskIconName: String {
        switch reason.riskLevel {
        case .low:
            return "checkmark.seal.fill"
        case .medium:
            return "info.circle.fill"
        case .high:
            return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Branch Summary") {
                    LabeledContent("Repository", value: project.name)
                    LabeledContent("Local Branch") {
                        Text(branch.name)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Tip Commit") {
                        Text("\(branch.shortHash) · \(branch.subject.isEmpty ? "No subject" : branch.subject)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let upstream = branch.upstreamRef {
                        LabeledContent("Remote Tracking") {
                            Text(branch.isUpstreamGone ? "\(upstream) (gone on remote)" : upstream)
                                .font(.caption.monospaced())
                                .foregroundStyle(branch.isUpstreamGone ? .orange : .secondary)
                        }
                    }
                }

                Section("Why Force Delete (-D) Is Needed & Risk Level") {
                    Label {
                        Text(reason.badgeTitle)
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: riskIconName)
                    }
                    .foregroundStyle(riskAccentColor)

                    Text(reason.explanation)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text("Git command:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("git branch -D \(branch.name)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .textSelection(.enabled)
                    }

                    if let stderr = pending.gitStderr, !stderr.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Git safe-delete (`-d`) check output:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(stderr)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    if requiresHighRiskToggle {
                        Toggle(
                            "I understand unmerged local commits on `\(branch.name)` will no longer have a branch pointer",
                            isOn: $acknowledgeHighRiskUnmerged
                        )
                        .tint(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Confirm Force Delete Branch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        "Force Delete (-D)",
                        role: reason.riskLevel == .low ? nil : .destructive
                    ) {
                        viewModel.confirmForceDeleteBranch(pending)
                        dismiss()
                    }
                    .disabled(requiresHighRiskToggle && !acknowledgeHighRiskUnmerged)
                }
            }
        }
        .frame(width: 530, height: pending.gitStderr != nil ? 470 : 410)
    }
}

struct BatchCleanBranchesSheet: View {
    let pending: PendingBatchBranchCleanup
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private static let groveEmerald = Color(red: 0.06, green: 0.66, blue: 0.45)

    var body: some View {
        let totalCount = pending.safeBranches.count + pending.forceRequiredBranches.count

        NavigationStack {
            Form {
                Section("Merged Branch Cleanup Summary") {
                    Label(
                        "All \(totalCount) branch\(totalCount == 1 ? " has" : "es have") changes already merged into \(pending.forceRequiredBranches.first?.baseRef ?? "main")",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(Self.groveEmerald)

                    Text(
                        "\(pending.forceRequiredBranches.count) of these merged branch\(pending.forceRequiredBranches.count == 1 ? " requires" : "es require") `git branch -D` because it was squash/rebase-merged or has commits not pushed to its stale remote tracking ref."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section("Requires `git branch -D` (\(pending.forceRequiredBranches.count))") {
                    ForEach(pending.forceRequiredBranches) { branch in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(branch.name)
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(branch.shortHash)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            if let reason = branch.forceDeleteReason {
                                Text(reason.badgeTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !pending.safeBranches.isEmpty {
                    Section("Standard `git branch -d` (\(pending.safeBranches.count))") {
                        ForEach(pending.safeBranches) { branch in
                            HStack {
                                Text(branch.name)
                                    .font(.system(size: 12.5, design: .monospaced))
                                Spacer()
                                Text(branch.shortHash)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Confirm Merged Branch Cleanup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete \(totalCount) Merged Branch\(totalCount == 1 ? "" : "es")") {
                        viewModel.confirmBatchBranchCleanup(pending)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
    }
}
