import AppKit
import GroveCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    private var enabledFolders: [ScanFolder] {
        viewModel.configuration.folders.filter(\.isEnabled)
    }

    private var hasActiveToolbarFilter: Bool {
        viewModel.activeFilter != .all || viewModel.selectedFolderID != nil
    }

    private var suggestedFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Developer", "Projects", "Code", "workspace", "Desktop", "Documents"]
        return candidates.compactMap { name in
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.configuration.folders.isEmpty || (viewModel.projects.isEmpty && !viewModel.isScanning) {
                    emptyWorkspaceView
                } else {
                    DashboardView(viewModel: viewModel)
                }
            }
            .navigationTitle("Grove")
            .navigationSubtitle(viewModel.windowSubtitle)
            .toolbar {
                dashboardToolbarContent
            }
            .searchable(text: $viewModel.searchText, prompt: "Filter projects, worktrees, or branches")
            .safeAreaBar(edge: .bottom) {
                toastOverlay
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFolderURLs(urls)
            return true
        }
        .sheet(item: $viewModel.pendingCommitCheckout) { pending in
            CommitChangesSheet(pending: pending, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingWorktreeRemoval) { pending in
            RemoveWorktreeSheet(pending: pending, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingProjectRemoval) { project in
            RemoveProjectSheet(project: project, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingBranchDeletion) { pending in
            DeleteBranchSheet(pending: pending, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingBatchBranchCleanup) { pending in
            BatchCleanBranchesSheet(pending: pending, viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingIntegrationTargetProject) { project in
            IntegrationTargetSheet(project: project, viewModel: viewModel)
        }
        .alert(
            "Operation Error",
            isPresented: Binding(
                get: { viewModel.activeErrorMessage != nil },
                set: { if !$0 { viewModel.activeErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.activeErrorMessage ?? "")
        }
        .onAppear {
            viewModel.refreshOnDashboardFocusIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshOnDashboardFocusIfNeeded()
        }
    }

    // MARK: - Unified Dashboard Toolbar

    @ToolbarContentBuilder
    private var dashboardToolbarContent: some ToolbarContent {
        if case let .updateAvailable(release) = viewModel.updateState {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.installAvailableUpdate(release)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11.5))
                        Text("Update v\(release.version)")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(RowDismissButton.groveEmerald)
                }
                .help("Install Grove v\(release.version) & relaunch")
            }
        } else if case .updating = viewModel.updateState {
            ToolbarItem(placement: .primaryAction) {
                ProgressView()
                    .controlSize(.small)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !viewModel.projects.isEmpty {
                filterMenuButton
            }

            Button {
                viewModel.startScan()
            } label: {
                if viewModel.isScanning || viewModel.isLoadingSnapshots {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isScanning || viewModel.isLoadingSnapshots)
            .help("Rescan repositories (⌘R)")

            Button {
                viewModel.promptAddFolder()
            } label: {
                Label("Add Scan Folder", systemImage: "folder.badge.plus")
            }
            .help("Add Scan Folder… (⌘O)")
        }

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }

    private var filterMenuButton: some View {
        Menu {
            Picker("Filter", selection: $viewModel.activeFilter) {
                ForEach(DashboardFilter.allCases) { filter in
                    Text("\(filter.title) (\(viewModel.itemCount(for: filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)

            if enabledFolders.count > 1 {
                Divider()

                Menu("Scan Folder") {
                    Button {
                        viewModel.selectedFolderID = nil
                    } label: {
                        Label(
                            "All Folders",
                            systemImage: viewModel.selectedFolderID == nil ? "checkmark" : "folder"
                        )
                    }

                    Divider()

                    ForEach(enabledFolders) { folder in
                        Button {
                            viewModel.selectedFolderID = folder.id
                        } label: {
                            let c = viewModel.dashboardProjectCount(in: folder)
                            Label(
                                "\(folder.displayName) (\(c))",
                                systemImage: viewModel.selectedFolderID == folder.id ? "checkmark" : "folder"
                            )
                        }
                    }
                }
            }

            if hasActiveToolbarFilter {
                Divider()
                Button("Reset Filter to All") {
                    viewModel.activeFilter = .all
                    viewModel.selectedFolderID = nil
                }
            }
        } label: {
            Label(
                hasActiveToolbarFilter ? viewModel.activeFilter.title : "Filter",
                systemImage: hasActiveToolbarFilter
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease"
            )
        }
        .help(
            hasActiveToolbarFilter
                ? "Active filter: \(viewModel.activeFilter.title)"
                : "Filter worktrees and idle branches"
        )
    }

    // MARK: - Onboarding / Empty Workspace

    @ViewBuilder
    private var emptyWorkspaceView: some View {
        if viewModel.configuration.folders.isEmpty {
            ContentUnavailableView {
                Label("Choose a Folder to Scan", systemImage: "folder.badge.plus")
            } description: {
                Text("Grove surfaces your idle local branches and linked Git worktrees grouped by project so you can clean them up in one place.")
            } actions: {
                VStack(spacing: 12) {
                    Button {
                        viewModel.promptAddFolder()
                    } label: {
                        Label("Add Scan Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    if !suggestedFolders.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(suggestedFolders.prefix(5), id: \.path) { url in
                                Button("~/\(url.lastPathComponent)") {
                                    viewModel.addFolderURLs([url])
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Git Repositories Found", systemImage: "magnifyingglass")
            } description: {
                Text("No Git repositories (`.git`) were found 1 level deep in your enabled scan folders.")
            } actions: {
                SettingsLink {
                    Label("Manage Scan Folders…", systemImage: "gearshape")
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let report = viewModel.lastReport {
            GlassEffectContainer {
                ReportToastCapsule(report: report) {
                    withAnimation(.snappy) {
                        viewModel.lastReport = nil
                    }
                }
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.bottom, 12)
        }
    }
}

private struct ReportToastCapsule: View {
    let report: ActionReport
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.warnings.isEmpty ? GrovePalette.teal : GrovePalette.cobalt)

            Text(report.title)
                .font(.callout.weight(.medium))

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
