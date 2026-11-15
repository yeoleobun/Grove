import AppKit
import GroveCore
import SwiftUI

// MARK: - Clean Project-Only Sidebar Row

struct SidebarProjectItemView: View {
    let project: ProjectGroup
    @Bindable var viewModel: AppViewModel
    @LocalState private var isHovering: Bool = false

    private var isSelected: Bool {
        viewModel.selectedProject?.id == project.id
    }

    private var mainWorktree: WorktreeItem? {
        project.mainWorktree
    }

    private var targetPath: String {
        mainWorktree?.path ?? project.primaryPath
    }

    private var isBusy: Bool {
        project.isInspecting
            || viewModel.isProjectBusy(project.id)
            || viewModel.isFetchingOrigin(project.id)
            || project.worktrees.contains(where: { viewModel.busyWorktreeIDs.contains($0.id) })
    }

    private var statusDotColor: Color? {
        if project.worktrees.contains(where: { $0.workingTreeStatus.conflictCount > 0 }) {
            return .red
        }
        if project.worktrees.contains(where: \.hasUncommittedChanges) {
            return .orange
        }
        if project.worktrees.contains(where: {
            if case .needsPush = $0.actionState { return true }
            return false
        }) {
            return .blue
        }
        return nil
    }

    private var shortAge: String? {
        guard let date = project.lastModified ?? mainWorktree?.lastModified else { return nil }
        return RelativeTimeFormatting.shortAgeString(from: date)
    }

    var body: some View {
        let editorName = viewModel.configuration.resolvedEditorLabel
        let shellName = viewModel.configuration.resolvedTerminalLabel
        let linkedCount = project.subWorktrees.count

        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 16, alignment: .leading)

            Text(project.name)
                .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                if let dotColor = statusDotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }

                if linkedCount > 0 {
                    HStack(spacing: 2.5) {
                        Image(systemName: "folder.on.folder")
                            .font(.system(size: 9, weight: .medium))
                        Text("\(linkedCount + 1)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
                    .help("\(linkedCount + 1) worktree folders (\(linkedCount) linked + 1 primary)")
                } else if let age = shortAge {
                    Text(age)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(SidebarSelectionPillBackground(isSelected: isSelected, isHovering: isHovering))
        .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            viewModel.selectProject(projectID: project.id)
        }
        .help(project.displayPath)
        .contextMenu {
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

            Button("Fetch & Prune Origin") {
                viewModel.fetchOrigin(for: project)
            }
            .disabled(viewModel.isFetchingOrigin(project.id))

            Button("Integration Target…") {
                viewModel.pendingIntegrationTargetProject = project
            }

            Divider()

            Button("Delete Entire Project…", role: .destructive) {
                viewModel.pendingProjectRemoval = project
            }
        }
    }
}

private struct SidebarSelectionPillBackground: View {
    let isSelected: Bool
    let isHovering: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8.5, style: .continuous)
        if isSelected {
            if colorScheme == .dark {
                shape
                    .fill(Color.white.opacity(0.11))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            } else {
                shape
                    .fill(Color.white.opacity(0.95))
                    .overlay(shape.strokeBorder(Color.black.opacity(0.045), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.035), radius: 2.5, x: 0, y: 1)
            }
        } else if isHovering {
            shape
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
        } else {
            Color.clear
        }
    }
}
