import AppKit
import GroveCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @LocalState private var columnVisibility: NavigationSplitViewVisibility = .all
    @LocalState private var isSearchFieldVisible: Bool = false
    @Environment(\.appearsActive) private var appearsActive

    private var enabledFolders: [ScanFolder] {
        viewModel.configuration.folders.filter(\.isEnabled)
    }

    private var hasActiveSidebarFilter: Bool {
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
        Group {
            if viewModel.configuration.folders.isEmpty || viewModel.projects.isEmpty {
                NavigationStack {
                    emptyWorkspaceView
                        .navigationTitle("Grove")
                        .navigationSubtitle(viewModel.windowSubtitle)
                        .toolbar {
                            onboardingToolbarContent
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarPane
                        .navigationSplitViewColumnWidth(min: 248, ideal: 288, max: 390)
                } detail: {
                    CheckoutInspectorView(viewModel: viewModel)
                        .safeAreaBar(edge: .bottom) {
                            toastOverlay
                        }
                }
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

    // MARK: - Minimal `Projects` Sidebar (Matching Uploaded Reference + Liquid Glass)

    private var sidebarPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(viewModel.filteredProjects) { project in
                    SidebarProjectItemView(project: project, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .top, spacing: 0) {
            sidebarTopHeader
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            sidebarSettingsFooter
        }
        .overlay {
            if viewModel.filteredProjects.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "line.3.horizontal.decrease")
                } description: {
                    if !viewModel.searchText.isEmpty {
                        Text("No repositories match “\(viewModel.searchText)”.")
                    } else {
                        Text("Nothing in \(viewModel.activeFilter.title).")
                    }
                } actions: {
                    Button("Show All Projects") {
                        viewModel.activeFilter = .all
                        viewModel.selectedFolderID = nil
                        viewModel.searchText = ""
                        isSearchFieldVisible = false
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Clean `Projects` header with `line.3.horizontal.decrease` filter button & `folder.badge.plus` add-folder button.
    private var sidebarTopHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Projects")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    if hasActiveSidebarFilter {
                        Text("· \(viewModel.activeFilter.title)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if viewModel.isScanning {
                    SwayingTreeIndicator(size: 13)
                        .help(viewModel.statusMessage)
                }

                sidebarFilterMenuButton

                Button {
                    viewModel.promptAddFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add Scan Folder…")
            }

            if isSearchFieldVisible || !viewModel.searchText.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search projects or branches…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))

                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            viewModel.searchText = ""
                            isSearchFieldVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close search")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .opacity(appearsActive ? 1.0 : 0.58)
    }

    private var sidebarFilterMenuButton: some View {
        Menu {
            Picker("Filter", selection: $viewModel.activeFilter) {
                ForEach(ProjectFilter.allCases) { filter in
                    Text("\(filter.title) (\(viewModel.count(for: filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isSearchFieldVisible.toggle()
                    if !isSearchFieldVisible {
                        viewModel.searchText = ""
                    }
                }
            } label: {
                Label(
                    isSearchFieldVisible ? "Hide Search" : "Search Projects…",
                    systemImage: "magnifyingglass"
                )
            }

            Menu("Sort By") {
                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(ProjectSortOrder.allCases) { order in
                        Label(order.title, systemImage: order.systemImage)
                            .tag(order)
                    }
                }
                .pickerStyle(.inline)
            }

            if !enabledFolders.isEmpty {
                Menu("Scan Folder") {
                    Button {
                        viewModel.selectedFolderID = nil
                    } label: {
                        Label(
                            "All Folders (\(viewModel.projects.count))",
                            systemImage: viewModel.selectedFolderID == nil ? "checkmark" : "folder"
                        )
                    }

                    Divider()

                    ForEach(enabledFolders) { folder in
                        Button {
                            viewModel.selectedFolderID = folder.id
                        } label: {
                            let c = viewModel.projectCount(in: folder)
                            Label(
                                "\(folder.displayName) (\(c))",
                                systemImage: viewModel.selectedFolderID == folder.id ? "checkmark" : "folder"
                            )
                        }
                    }
                }
            }

            if hasActiveSidebarFilter {
                Divider()
                Button("Reset Filter to All") {
                    viewModel.activeFilter = .all
                    viewModel.selectedFolderID = nil
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13.5, weight: hasActiveSidebarFilter ? .semibold : .regular))
                .foregroundStyle(hasActiveSidebarFilter ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            hasActiveSidebarFilter
                ? "Filter: \(viewModel.activeFilter.title)"
                : "Filter, Sort & Rescan (Default: All)"
        )
    }

    private var sidebarSettingsFooter: some View {
        HStack {
            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)

                    Text("Settings")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

            Spacer(minLength: 4)

            if case let .updateAvailable(release) = viewModel.updateState {
                Button {
                    viewModel.installAvailableUpdate(release)
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11))
                        Text("v\(release.version)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(RowDismissButton.groveEmerald)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RowDismissButton.groveEmerald.opacity(0.12),
                        in: Capsule(style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .help("Install Grove v\(release.version) & relaunch")
            } else if case .updating = viewModel.updateState {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(appearsActive ? 1.0 : 0.55)
    }

    // MARK: - Onboarding / Empty Workspace Toolbar

    @ToolbarContentBuilder
    private var onboardingToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.isScanning {
                SwayingTreeIndicator(size: 17)
                    .help(viewModel.statusMessage)
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var emptyWorkspaceView: some View {
        if viewModel.configuration.folders.isEmpty {
            ContentUnavailableView {
                Label("Choose a Folder to Scan", systemImage: "folder.badge.plus")
            } description: {
                Text("Grove groups your Git projects with their worktrees and branches so you can inspect history, fetch origin, or prune merged branches.")
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
        } else if viewModel.isScanning {
            ContentUnavailableView {
                SwayingTreeIndicator(size: 46)
            } description: {
                Text(viewModel.statusMessage)
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
                .foregroundStyle(report.warnings.isEmpty ? .green : .orange)

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
