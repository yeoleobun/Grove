import AppKit
import Foundation
import Observation
import GroveCore
import SwiftUI
import UniformTypeIdentifiers

enum ProjectFilter: String, CaseIterable, Identifiable {
    case all
    case hasWorktrees
    case needsCommitOrPush
    case readyToRemove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .hasWorktrees: return "Has Worktrees"
        case .needsCommitOrPush: return "Needs Commit or Push"
        case .readyToRemove: return "Ready to Clean"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .hasWorktrees: return "arrow.triangle.branch"
        case .needsCommitOrPush: return "circle.dotted.circle"
        case .readyToRemove: return "checkmark.circle"
        }
    }
}

enum ProjectSortOrder: String, CaseIterable, Identifiable {
    case actionNeeded
    case lastUpdated
    case worktreeCount
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actionNeeded: return "Action Needed"
        case .lastUpdated: return "Last Updated"
        case .worktreeCount: return "Worktrees"
        case .name: return "Name"
        }
    }

    var systemImage: String {
        switch self {
        case .actionNeeded: return "bolt.circle"
        case .lastUpdated: return "clock"
        case .worktreeCount: return "point.3.connected.trianglepath.dotted"
        case .name: return "textformat.abc"
        }
    }
}

struct PendingWorktreeRemoval: Identifiable {
    let project: ProjectGroup
    let worktree: WorktreeItem
    var id: String { "\(project.id)::\(worktree.id)" }
}

struct PendingCommitCheckout: Identifiable {
    let project: ProjectGroup
    let worktree: WorktreeItem
    var id: String { "\(project.id)::\(worktree.id)" }
}

struct PendingBranchDeletion: Identifiable {
    let project: ProjectGroup
    let branch: LocalBranchInfo
    let reason: BranchForceDeleteReason
    let gitStderr: String?
    var id: String { "\(project.id)::\(branch.name)" }
}

struct PendingBatchBranchCleanup: Identifiable {
    let project: ProjectGroup
    let safeBranches: [LocalBranchInfo]
    let forceRequiredBranches: [LocalBranchInfo]
    var id: String { "\(project.id)::batch-branches" }
}

struct CheckoutSelection: Hashable {
    let projectID: String
    let worktreeID: String?
}

private final class ScanSequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}

@MainActor
@Observable
final class AppViewModel {
    var configuration: ScanConfiguration
    var projects: [ProjectGroup] = []
    var scanSummary = ScanSummary()

    // Project List state
    var selectedFolderID: UUID? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            ensureValidSelection(forceRefresh: false)
        }
    }
    var activeFilter: ProjectFilter = .all {
        didSet {
            guard activeFilter != oldValue else { return }
            ensureValidSelection(forceRefresh: false)
        }
    }
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            ensureValidSelection(forceRefresh: false)
        }
    }
    var sortOrder: ProjectSortOrder = .actionNeeded {
        didSet {
            guard sortOrder != oldValue else { return }
            withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                projects = sortProjects(projects, by: sortOrder)
            }
        }
    }
    var expandedProjectIDs: Set<String> = []

    // Unified Single-Page Right Detail State (Worktrees + Local Branches)
    var isInspectorVisible: Bool = true
    var selectedProjectID: String?
    var selectedWorktreeID: String?
    var historySnapshot: ProjectHistorySnapshot?
    var isLoadingHistory: Bool = false

    var isScanning: Bool = false
    /// Scoped per-item busy tracking so acting on one project/worktree NEVER grays out other rows!
    var busyProjectIDs: Set<String> = []
    var busyWorktreeIDs: Set<String> = []
    var deletingWorktreeIDs: Set<String> = []
    var fetchingProjectIDs: Set<String> = []
    var deletingBranchKeys: Set<String> = []

    var statusMessage: String = "Ready"
    var lastReport: ActionReport?
    var activeErrorMessage: String?
    var updateState: AppUpdateState = .idle

    // Modals for contextual actions
    var pendingCommitCheckout: PendingCommitCheckout?
    var pendingWorktreeRemoval: PendingWorktreeRemoval?
    var pendingProjectRemoval: ProjectGroup?
    var pendingBranchDeletion: PendingBranchDeletion?
    var pendingBatchBranchCleanup: PendingBatchBranchCleanup?
    var pendingIntegrationTargetProject: ProjectGroup?

    private let store: ConfigurationStore
    private var currentScanTask: Task<Void, Never>?
    private var currentHistoryTask: Task<Void, Never>?
    private var activeScanID = UUID()
    private var appliedPartialSeq: Int = 0
    private var lastScanFinishedAt: Date?
    private var lastUpdateCheckAt: Date?

    init(store: ConfigurationStore = ConfigurationStore()) {
        self.store = store
        self.configuration = store.load()
    }

    var isPerformingAction: Bool {
        !busyProjectIDs.isEmpty
            || !busyWorktreeIDs.isEmpty
            || !deletingWorktreeIDs.isEmpty
            || !fetchingProjectIDs.isEmpty
            || !deletingBranchKeys.isEmpty
    }

    func isProjectBusy(_ projectID: String) -> Bool {
        busyProjectIDs.contains(projectID)
    }

    func isWorktreeBusy(_ worktreeID: String, in projectID: String) -> Bool {
        busyProjectIDs.contains(projectID) || busyWorktreeIDs.contains(worktreeID) || deletingWorktreeIDs.contains(worktreeID)
    }

    // MARK: - Window Subtitle

    var windowSubtitle: String {
        if isScanning || isPerformingAction {
            return statusMessage
        }
        guard !configuration.enabledFolderPaths.isEmpty else {
            return "No scan folders configured"
        }
        let s = scanSummary
        var parts = [
            "\(s.projectCount) repo\(s.projectCount == 1 ? "" : "s")"
        ]
        if s.linkedWorktreeCount > 0 {
            parts.append("\(s.linkedWorktreeCount) worktree\(s.linkedWorktreeCount == 1 ? "" : "s")")
        }
        if s.needsCommitCount > 0 {
            parts.append("\(s.needsCommitCount) uncommitted")
        }
        if s.needsPushCount > 0 {
            parts.append("\(s.needsPushCount) unpushed")
        }
        if s.removableWorktreeCount > 0 {
            parts.append("\(s.removableWorktreeCount) ready to clean")
        }
        return parts.joined(separator: " · ")
    }

    var selectedFolder: ScanFolder? {
        guard let id = selectedFolderID else { return nil }
        return configuration.folders.first(where: { $0.id == id })
    }

    // MARK: - Filtering & Sorting

    private var folderScopedProjects: [ProjectGroup] {
        guard let folder = selectedFolder else { return projects }
        let rootCanonical = PathNormalizer.canonicalPath(folder.path)
        return projects.filter { group in
            Self.projectBelongsToOneLevelFolder(group, folderCanonicalPath: rootCanonical)
        }
    }

    func count(for filter: ProjectFilter) -> Int {
        let base = folderScopedProjects
        switch filter {
        case .all:
            return base.count
        case .hasWorktrees:
            return base.filter { !$0.subWorktrees.isEmpty }.count
        case .needsCommitOrPush:
            return base.reduce(0) { $0 + $1.needsCommitCount + $1.needsPushCount }
        case .readyToRemove:
            return base.reduce(0) { $0 + $1.removableWorktreeCount }
        }
    }

    var filteredProjects: [ProjectGroup] {
        var result = folderScopedProjects

        switch activeFilter {
        case .all:
            break
        case .hasWorktrees:
            result = result.filter { !$0.subWorktrees.isEmpty }
        case .needsCommitOrPush:
            result = result.filter { ($0.needsCommitCount + $0.needsPushCount) > 0 }
        case .readyToRemove:
            result = result.filter { $0.removableWorktreeCount > 0 }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { project in
                if project.name.lowercased().contains(query) || project.primaryPath.lowercased().contains(query) {
                    return true
                }
                return project.worktrees.contains { wt in
                    wt.name.lowercased().contains(query)
                        || wt.path.lowercased().contains(query)
                        || (wt.branchName?.lowercased().contains(query) ?? false)
                }
            }
        }

        // Preserve `projects` order during in-place item actions (e.g. deleting a worktree or committing)
        // so the card you are interacting with never teleports to another scroll position!
        return result
    }

    private func sortProjects(_ list: [ProjectGroup], by order: ProjectSortOrder) -> [ProjectGroup] {
        list.sorted { lhs, rhs in
            switch order {
            case .actionNeeded:
                if lhs.highestUrgencyRank != rhs.highestUrgencyRank {
                    return lhs.highestUrgencyRank < rhs.highestUrgencyRank
                }
                if lhs.actionableCheckoutCount != rhs.actionableCheckoutCount {
                    return lhs.actionableCheckoutCount > rhs.actionableCheckoutCount
                }
                if lhs.subWorktrees.count != rhs.subWorktrees.count {
                    return lhs.subWorktrees.count > rhs.subWorktrees.count
                }
                let lDate = lhs.lastModified ?? .distantPast
                let rDate = rhs.lastModified ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .lastUpdated:
                let lDate = lhs.lastModified ?? .distantPast
                let rDate = rhs.lastModified ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .worktreeCount:
                if lhs.subWorktrees.count != rhs.subWorktrees.count {
                    return lhs.subWorktrees.count > rhs.subWorktrees.count
                }
                if lhs.highestUrgencyRank != rhs.highestUrgencyRank {
                    return lhs.highestUrgencyRank < rhs.highestUrgencyRank
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func projectCount(in folder: ScanFolder) -> Int {
        let rootCanonical = PathNormalizer.canonicalPath(folder.path)
        return projects.filter { group in
            Self.projectBelongsToOneLevelFolder(group, folderCanonicalPath: rootCanonical)
        }.count
    }

    private static func projectBelongsToOneLevelFolder(_ group: ProjectGroup, folderCanonicalPath: String) -> Bool {
        group.worktrees.contains { wt in
            let p = PathNormalizer.canonicalPath(wt.path)
            return p == folderCanonicalPath || (p as NSString).deletingLastPathComponent == folderCanonicalPath
        }
    }

    // MARK: - Linked Worktree Disclosure State

    var expandableProjects: [ProjectGroup] {
        filteredProjects.filter { !$0.subWorktrees.isEmpty }
    }

    func toggleExpanded(_ projectID: String) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    func expandAll() {
        for p in expandableProjects {
            expandedProjectIDs.insert(p.id)
        }
    }

    func collapseAll() {
        expandedProjectIDs.removeAll()
    }

    // MARK: - Configuration Management

    func persistAndRescan() {
        try? store.save(configuration)
        startScan()
    }

    func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders Containing Git Repositories"
        panel.message = "Grove checks each selected folder 1 level deep for Git repositories and groups all linked Git worktrees."
        panel.prompt = "Add Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            addFolderURLs(panel.urls)
        }
    }

    func addFolderURLs(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let norm = ScanFolder.normalizePath(url.path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: norm, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if !configuration.folders.contains(where: { $0.path == norm }) {
                configuration.folders.append(ScanFolder(path: norm))
                changed = true
            }
        }
        if changed {
            persistAndRescan()
        }
    }

    func setFolderEnabled(_ folderID: UUID, isEnabled: Bool) {
        guard let idx = configuration.folders.firstIndex(where: { $0.id == folderID }),
              configuration.folders[idx].isEnabled != isEnabled else { return }
        configuration.folders[idx].isEnabled = isEnabled
        if !isEnabled && selectedFolderID == folderID {
            selectedFolderID = nil
        }
        persistAndRescan()
    }

    func removeFolder(_ folder: ScanFolder) {
        configuration.folders.removeAll { $0.id == folder.id }
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        persistAndRescan()
    }

    func updateIncludeExternalWorktrees(_ include: Bool) {
        guard configuration.includeExternalWorktrees != include else { return }
        configuration.includeExternalWorktrees = include
        persistAndRescan()
    }

    func updateDisplayCountInMenuBar(_ show: Bool) {
        guard configuration.displayCountInMenuBar != show else { return }
        configuration.displayCountInMenuBar = show
        try? store.save(configuration)
    }

    func updatePreferredEditor(_ editor: PreferredCodeEditor) {
        configuration.preferredEditor = editor
        try? store.save(configuration)
        if editor == .custom && (configuration.customEditorAppPath ?? "").isEmpty {
            chooseCustomEditorApp()
        }
    }

    func chooseCustomEditorApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Code Editor or IDE Application"
        panel.prompt = "Select Editor"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            configuration.preferredEditor = .custom
            configuration.customEditorAppPath = url.path
            try? store.save(configuration)
        }
    }

    func updatePreferredTerminal(_ terminal: PreferredTerminalApp) {
        configuration.preferredTerminal = terminal
        try? store.save(configuration)
        if terminal == .custom && (configuration.customTerminalAppPath ?? "").isEmpty {
            chooseCustomTerminalApp()
        }
    }

    func chooseCustomTerminalApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Shell / Terminal Application"
        panel.prompt = "Select Terminal"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            configuration.preferredTerminal = .custom
            configuration.customTerminalAppPath = url.path
            try? store.save(configuration)
        }
    }

    // MARK: - Manual Scanning

    func startScan() {
        currentScanTask?.cancel()

        let scanID = UUID()
        activeScanID = scanID
        appliedPartialSeq = 0

        guard !configuration.enabledFolderPaths.isEmpty else {
            projects = []
            scanSummary = ScanSummary()
            selectedProjectID = nil
            selectedWorktreeID = nil
            historySnapshot = nil
            isScanning = false
            statusMessage = "Add a folder to begin scanning"
            return
        }

        let hadProjects = !projects.isEmpty
        isScanning = true
        statusMessage = "Scanning Git repositories…"
        let snapshotConfig = configuration
        let seqBox = ScanSequenceBox()

        let onProgress: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self, self.activeScanID == scanID, self.isScanning else { return }
                self.statusMessage = msg
            }
        }
        let onPartial: @Sendable ([ProjectGroup]) -> Void = { [weak self] partial in
            let seq = seqBox.next()
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeScanID == scanID,
                      self.isScanning,
                      seq > self.appliedPartialSeq else {
                    return
                }
                self.appliedPartialSeq = seq
                let ordered = self.sortProjects(partial, by: self.sortOrder)
                self.projects = ordered
                self.scanSummary = ScanSummary(projects: ordered)
                if !hadProjects {
                    for p in ordered where !p.subWorktrees.isEmpty {
                        self.expandedProjectIDs.insert(p.id)
                    }
                }
                self.ensureValidSelection(forceRefresh: false)
            }
        }

        currentScanTask = Task(priority: .userInitiated) { [weak self] in
            let startTime = CFAbsoluteTimeGetCurrent()
            let discovered = await ProjectScanner.scan(
                configuration: snapshotConfig,
                progress: onProgress,
                onPartialResults: hadProjects ? nil : onPartial
            )

            guard !Task.isCancelled, let self, self.activeScanID == scanID else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let ordered = self.sortProjects(discovered, by: self.sortOrder)

            withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
                self.projects = ordered
                self.scanSummary = ScanSummary(projects: ordered, scanDurationSeconds: elapsed)
                if !hadProjects {
                    for p in ordered where !p.subWorktrees.isEmpty {
                        self.expandedProjectIDs.insert(p.id)
                    }
                }
            }

            self.ensureValidSelection(forceRefresh: true)
            self.isScanning = false
            self.lastScanFinishedAt = Date()
            self.statusMessage = String(
                format: "Scanned %d repo%@ in %.2fs",
                ordered.count,
                ordered.count == 1 ? "" : "s",
                elapsed
            )
        }
    }

    /// Automatically refreshes repository & worktree status when the Dashboard window opens or regains focus,
    /// avoiding any background polling timer or battery usage when closed/idle.
    func refreshOnDashboardFocusIfNeeded() {
        checkForUpdates(manual: false)
        guard !configuration.enabledFolderPaths.isEmpty else { return }
        guard !isScanning && !isPerformingAction else { return }
        if let last = lastScanFinishedAt, Date().timeIntervalSince(last) < 2.0 {
            return
        }
        startScan()
    }

    // MARK: - GitHub Release Version Check & Serverless Self-Update

    func checkForUpdates(manual: Bool = false) {
        if case .updating = updateState { return }
        if case .checking = updateState { return }
        if !manual, let last = lastUpdateCheckAt, Date().timeIntervalSince(last) < 3_600 {
            return
        }

        lastUpdateCheckAt = Date()
        if manual {
            updateState = .checking
        }

        Task {
            do {
                if let release = try await UpdateService.fetchLatestUpdate() {
                    self.updateState = .updateAvailable(release)
                } else if manual {
                    self.updateState = .upToDate(version: UpdateService.currentAppVersion)
                } else if case .updateAvailable = self.updateState {
                    self.updateState = .idle
                }
            } catch {
                if manual {
                    self.updateState = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    func installAvailableUpdate(_ release: ReleaseAssetInfo) {
        if case .updating = updateState { return }
        updateState = .updating(version: release.version)

        Task {
            do {
                try await UpdateService.stageAndLaunchReplacement(for: release)
                AppDelegate.quitCompletely()
            } catch {
                self.updateState = .failed(message: error.localizedDescription)
                self.activeErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Contextual Git Actions (Commit & Push, Scoped Per-Row Lock)

    func commitCheckout(
        _ worktree: WorktreeItem,
        in project: ProjectGroup,
        message: String,
        pushAfterCommit: Bool
    ) {
        pendingCommitCheckout = nil
        guard !busyWorktreeIDs.contains(worktree.id) else { return }

        busyWorktreeIDs.insert(worktree.id)
        let wtPath = worktree.path
        let wtName = worktree.name

        runScopedAction(
            label: pushAfterCommit ? "Committing & pushing \(wtName)…" : "Committing changes in \(wtName)…",
            onSuccess: { [weak self] in
                await self?.refreshProjectInPlace(project)
            },
            onCleanupBusy: { [weak self] in
                self?.busyWorktreeIDs.remove(worktree.id)
            }
        ) {
            let outcome = try GitWorktreeService.commitChanges(
                at: wtPath,
                message: message,
                pushAfterCommit: pushAfterCommit
            )
            let hashSuffix = outcome.commitHash.map { " (\($0))" } ?? ""
            let title: String
            if let pushedDest = outcome.pushedDestination {
                title = "Committed\(hashSuffix) & pushed to \(pushedDest)"
            } else {
                title = "Committed changes in '\(wtName)'\(hashSuffix)"
            }
            return ActionReport(title: title, affectedCount: 1)
        }
    }

    func pushCheckout(_ worktree: WorktreeItem, in project: ProjectGroup) {
        guard !busyWorktreeIDs.contains(worktree.id) else { return }

        busyWorktreeIDs.insert(worktree.id)
        let wtPath = worktree.path
        let wtName = worktree.name

        runScopedAction(
            label: "Pushing \(wtName) to remote…",
            onSuccess: { [weak self] in
                await self?.refreshProjectInPlace(project)
            },
            onCleanupBusy: { [weak self] in
                self?.busyWorktreeIDs.remove(worktree.id)
            }
        ) {
            let destination = try GitWorktreeService.pushChanges(at: wtPath)
            return ActionReport(
                title: "Pushed '\(wtName)' to \(destination)",
                affectedCount: 1
            )
        }
    }

    // MARK: - Worktree & Project Cut / Removal (Smooth In-Place Animated Removal!)

    func pruneGhostWorktrees(in project: ProjectGroup) {
        let ghosts = project.prunableWorktrees
        guard !ghosts.isEmpty else { return }
        for g in ghosts {
            deletingWorktreeIDs.insert(g.id)
        }

        runScopedAction(
            label: "Pruning missing Git worktrees in \(project.name)…",
            onSuccess: { [weak self] in
                self?.removeWorktreesInMemory(ids: Set(ghosts.map(\.id)), fromProjectID: project.id)
            },
            onCleanupBusy: { [weak self] in
                for g in ghosts {
                    self?.deletingWorktreeIDs.remove(g.id)
                }
            }
        ) {
            for ghost in ghosts {
                try GitWorktreeService.pruneWorktrees(
                    in: project.primaryPath,
                    unlockPathIfNeeded: ghost.isLocked ? ghost.path : nil
                )
            }
            return ActionReport(
                title: "Pruned \(ghosts.count) missing worktree\(ghosts.count == 1 ? "" : "s") in \(project.name)",
                affectedCount: ghosts.count
            )
        }
    }

    func confirmRemoveWorktree(_ worktree: WorktreeItem, in project: ProjectGroup, options: WorktreeRemovalOptions) {
        pendingWorktreeRemoval = nil
        guard !deletingWorktreeIDs.contains(worktree.id), !busyWorktreeIDs.contains(worktree.id) else { return }

        deletingWorktreeIDs.insert(worktree.id)

        runScopedAction(
            label: "Removing worktree \(worktree.name)…",
            onSuccess: { [weak self] in
                self?.removeWorktreesInMemory(ids: [worktree.id], fromProjectID: project.id)
            },
            onCleanupBusy: { [weak self] in
                self?.deletingWorktreeIDs.remove(worktree.id)
            }
        ) {
            let warnings = try GitWorktreeService.removeLinkedWorktree(
                worktree,
                in: project,
                options: options
            )
            return ActionReport(
                title: "Removed worktree '\(worktree.name)'",
                affectedCount: 1,
                warnings: warnings
            )
        }
    }

    func confirmRemoveProject(_ project: ProjectGroup, options: ProjectRemovalOptions) {
        pendingProjectRemoval = nil
        guard !busyProjectIDs.contains(project.id) else { return }

        busyProjectIDs.insert(project.id)

        runScopedAction(
            label: "Moving repository \(project.name) to Trash…",
            onSuccess: { [weak self] in
                self?.removeProjectInMemory(projectID: project.id)
            },
            onCleanupBusy: { [weak self] in
                self?.busyProjectIDs.remove(project.id)
            }
        ) {
            let warnings = try GitWorktreeService.removeEntireProject(project, options: options)
            return ActionReport(
                title: "Moved '\(project.name)' to Trash",
                affectedCount: project.worktrees.count,
                warnings: warnings
            )
        }
    }

    // MARK: - Remote Fetch & Local Branch Cleanup

    func isFetchingOrigin(_ projectID: String) -> Bool {
        fetchingProjectIDs.contains(projectID)
    }

    func branchBusyKey(_ branchName: String, in projectID: String) -> String {
        "\(projectID)::\(branchName)"
    }

    func fetchOrigin(for project: ProjectGroup) {
        guard !fetchingProjectIDs.contains(project.id) else { return }
        fetchingProjectIDs.insert(project.id)
        let repoPath = FileManager.default.fileExists(atPath: project.primaryPath)
            ? project.primaryPath
            : (project.worktrees.first(where: { $0.kind != .prunable })?.path ?? project.primaryPath)

        runScopedAction(
            label: "Fetching from origin for \(project.name)…",
            onSuccess: { [weak self] in
                await self?.refreshProjectInPlace(project)
            },
            onCleanupBusy: { [weak self] in
                self?.fetchingProjectIDs.remove(project.id)
            }
        ) {
            let remote = try GitWorktreeService.fetchFromRemote(at: repoPath)
            return ActionReport(
                title: "Fetched & pruned '\(remote)' for \(project.name)",
                affectedCount: 1
            )
        }
    }

    func requestDeleteBranch(_ branch: LocalBranchInfo, in project: ProjectGroup) {
        guard branch.checkedOutWorktreeID == nil else { return }
        if let reason = branch.forceDeleteReason {
            // Upfront detection: explain exact risk & why `git branch -D` is required before deleting!
            pendingBranchDeletion = PendingBranchDeletion(
                project: project,
                branch: branch,
                reason: reason,
                gitStderr: nil
            )
        } else {
            performDeleteBranch(branch, in: project, force: false)
        }
    }

    func confirmForceDeleteBranch(_ pending: PendingBranchDeletion) {
        pendingBranchDeletion = nil
        performDeleteBranch(pending.branch, in: pending.project, force: true)
    }

    private func performDeleteBranch(_ branch: LocalBranchInfo, in project: ProjectGroup, force: Bool) {
        let key = branchBusyKey(branch.name, in: project.id)
        guard !deletingBranchKeys.contains(key) else { return }
        deletingBranchKeys.insert(key)
        let repoPath = FileManager.default.fileExists(atPath: project.primaryPath)
            ? project.primaryPath
            : (project.worktrees.first(where: { $0.kind != .prunable })?.path ?? project.primaryPath)

        statusMessage = force
            ? "Force deleting branch '\(branch.name)' (-D)…"
            : "Deleting branch '\(branch.name)'…"

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GitWorktreeService.deleteLocalBranchNamed(branch.name, in: repoPath, force: force)
                }.value

                deletingBranchKeys.remove(key)
                withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                    if self.historySnapshot?.projectID == project.id {
                        self.historySnapshot?.localBranches.removeAll { $0.name == branch.name }
                    }
                    self.lastReport = ActionReport(
                        title: force
                            ? "Force deleted branch '\(branch.name)'"
                            : "Deleted branch '\(branch.name)'",
                        affectedCount: 1
                    )
                }
                self.statusMessage = "Deleted branch '\(branch.name)'"
                self.refreshInspectorSnapshot()
            } catch let GitWorktreeError.branchRequiresForceDelete(_, gitStderr) {
                // Never dump raw `git branch -d` refusal into Operation Error!
                // Present the structured Force-Delete risk prompt with Git's explanation instead.
                deletingBranchKeys.remove(key)
                let fallbackReason = branch.forceDeleteReason
                    ?? .mergedIntoBaseButGitRefusedSafeDelete(base: branch.baseRef ?? "main")
                self.pendingBranchDeletion = PendingBranchDeletion(
                    project: project,
                    branch: branch,
                    reason: fallbackReason,
                    gitStderr: gitStderr
                )
                self.statusMessage = "Confirmation required to force delete '\(branch.name)'"
            } catch {
                deletingBranchKeys.remove(key)
                self.activeErrorMessage = error.localizedDescription
                self.statusMessage = "Action failed"
            }
        }
    }

    func cleanMergedBranches(in project: ProjectGroup) {
        guard let snap = historySnapshot, snap.projectID == project.id else { return }
        let targets = snap.removableBranches
        guard !targets.isEmpty else { return }

        let safeBranches = targets.filter { $0.forceDeleteReason == nil }
        let forceRequired = targets.filter { $0.forceDeleteReason != nil }

        if !forceRequired.isEmpty {
            pendingBatchBranchCleanup = PendingBatchBranchCleanup(
                project: project,
                safeBranches: safeBranches,
                forceRequiredBranches: forceRequired
            )
            return
        }

        executeBatchBranchCleanup(
            project: project,
            safeBranches: safeBranches,
            forceApprovedBranches: []
        )
    }

    func confirmBatchBranchCleanup(_ pending: PendingBatchBranchCleanup) {
        pendingBatchBranchCleanup = nil
        executeBatchBranchCleanup(
            project: pending.project,
            safeBranches: pending.safeBranches,
            forceApprovedBranches: pending.forceRequiredBranches
        )
    }

    private func executeBatchBranchCleanup(
        project: ProjectGroup,
        safeBranches: [LocalBranchInfo],
        forceApprovedBranches: [LocalBranchInfo]
    ) {
        let allTargets = safeBranches + forceApprovedBranches
        guard !allTargets.isEmpty else { return }

        let keys = allTargets.map { branchBusyKey($0.name, in: project.id) }
        for k in keys {
            deletingBranchKeys.insert(k)
        }
        let repoPath = FileManager.default.fileExists(atPath: project.primaryPath)
            ? project.primaryPath
            : (project.worktrees.first(where: { $0.kind != .prunable })?.path ?? project.primaryPath)

        statusMessage = "Cleaning \(allTargets.count) merged branch\(allTargets.count == 1 ? "" : "es")…"

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var removedNames: [String] = []
                var refusedForForce: [LocalBranchInfo] = []
                var warnings: [String] = []

                for b in safeBranches {
                    do {
                        try GitWorktreeService.deleteLocalBranchNamed(b.name, in: repoPath, force: false)
                        removedNames.append(b.name)
                    } catch GitWorktreeError.branchRequiresForceDelete {
                        refusedForForce.append(b)
                    } catch {
                        warnings.append("'\(b.name)': \(error.localizedDescription)")
                    }
                }

                for b in forceApprovedBranches {
                    do {
                        try GitWorktreeService.deleteLocalBranchNamed(b.name, in: repoPath, force: true)
                        removedNames.append(b.name)
                    } catch {
                        warnings.append("'\(b.name)': \(error.localizedDescription)")
                    }
                }

                return (removedNames, refusedForForce, warnings)
            }.value

            for k in keys {
                deletingBranchKeys.remove(k)
            }

            let deletedSet = Set(result.0)
            if !deletedSet.isEmpty {
                withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                    if self.historySnapshot?.projectID == project.id {
                        self.historySnapshot?.localBranches.removeAll { deletedSet.contains($0.name) }
                    }
                    self.lastReport = ActionReport(
                        title: "Cleaned \(deletedSet.count) merged branch\(deletedSet.count == 1 ? "" : "es")",
                        affectedCount: deletedSet.count,
                        warnings: result.2
                    )
                }
                self.statusMessage = "Cleaned \(deletedSet.count) merged branch\(deletedSet.count == 1 ? "" : "es")"
                self.refreshInspectorSnapshot()
            } else if !result.2.isEmpty {
                self.activeErrorMessage = result.2.joined(separator: "\n")
                self.statusMessage = "Action failed"
            }

            if !result.1.isEmpty {
                self.pendingBatchBranchCleanup = PendingBatchBranchCleanup(
                    project: project,
                    safeBranches: [],
                    forceRequiredBranches: result.1
                )
            }
        }
    }

    // MARK: - Smooth In-Place Animated Updates (Zero Full-List Refresh!)

    private func removeWorktreesInMemory(ids: Set<String>, fromProjectID projectID: String) {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
            if let pIdx = projects.firstIndex(where: { $0.id == projectID }) {
                projects[pIdx].worktrees.removeAll { ids.contains($0.id) }
                if projects[pIdx].subWorktrees.isEmpty {
                    expandedProjectIDs.remove(projectID)
                }
            }
            scanSummary = ScanSummary(projects: projects)
        }
        ensureValidSelection(forceRefresh: selectedProjectID == projectID)
    }

    private func removeProjectInMemory(projectID: String) {
        withAnimation(.snappy(duration: 0.30, extraBounce: 0)) {
            projects.removeAll { $0.id == projectID }
            expandedProjectIDs.remove(projectID)
            scanSummary = ScanSummary(projects: projects)
        }
        ensureValidSelection(forceRefresh: selectedProjectID == projectID)
    }

    private func refreshProjectInPlace(_ project: ProjectGroup) async {
        let snapshotConfig = configuration
        let refreshed = await ProjectScanner.refreshSingleProject(project, configuration: snapshotConfig)
        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
            if let refreshed {
                if let pIdx = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[pIdx] = refreshed
                    if refreshed.subWorktrees.isEmpty {
                        expandedProjectIDs.remove(project.id)
                    }
                }
            } else {
                projects.removeAll { $0.id == project.id }
                expandedProjectIDs.remove(project.id)
            }
            scanSummary = ScanSummary(projects: projects)
        }
        ensureValidSelection(forceRefresh: selectedProjectID == project.id)
    }

    // MARK: - Right Detail Selection & Git Snapshot Loading

    var selectedProject: ProjectGroup? {
        if let pid = selectedProjectID,
           let match = projects.first(where: { $0.id == pid }) {
            return match
        }
        return filteredProjects.first
    }

    var selectedWorktree: WorktreeItem? {
        guard let project = selectedProject else { return nil }
        if let wid = selectedWorktreeID,
           let match = project.worktrees.first(where: { $0.id == wid }) {
            return match
        }
        return project.mainWorktree ?? project.worktrees.first
    }

    var currentSelection: CheckoutSelection? {
        get {
            guard let proj = selectedProject else { return nil }
            return CheckoutSelection(projectID: proj.id, worktreeID: selectedWorktree?.id)
        }
        set {
            guard let sel = newValue else { return }
            selectCheckout(projectID: sel.projectID, worktreeID: sel.worktreeID)
        }
    }

    func selectProject(projectID: String) {
        let proj = projects.first(where: { $0.id == projectID })
        let mainWID = proj?.mainWorktree?.id ?? proj?.worktrees.first?.id
        selectCheckout(projectID: projectID, worktreeID: mainWID)
    }

    func selectCheckout(projectID: String, worktreeID: String?) {
        let proj = projects.first(where: { $0.id == projectID })
        let resolvedWT = worktreeID ?? proj?.mainWorktree?.id ?? proj?.worktrees.first?.id

        let projectChanged = selectedProjectID != projectID
        let changed = projectChanged || (selectedWorktreeID != resolvedWT)
        selectedProjectID = projectID
        selectedWorktreeID = resolvedWT

        if changed || historySnapshot?.projectID != projectID || historySnapshot?.selectedWorktreeID != resolvedWT {
            refreshInspectorSnapshot()
        }
    }

    func ensureValidSelection(forceRefresh: Bool) {
        let visible = filteredProjects
        guard !visible.isEmpty else {
            if projects.isEmpty {
                selectedProjectID = nil
                selectedWorktreeID = nil
                historySnapshot = nil
            }
            return
        }

        let previousPID = selectedProjectID
        let previousWID = selectedWorktreeID

        if let pid = selectedProjectID,
           let activeProj = visible.first(where: { $0.id == pid }) {
            if let wid = selectedWorktreeID,
               activeProj.worktrees.contains(where: { $0.id == wid }) {
                // Current selection remains valid
            } else {
                selectedWorktreeID = activeProj.mainWorktree?.id ?? activeProj.worktrees.first?.id
            }
        } else if let first = visible.first {
            selectedProjectID = first.id
            selectedWorktreeID = first.mainWorktree?.id ?? first.worktrees.first?.id
        }

        let selectionChanged = (selectedProjectID != previousPID) || (selectedWorktreeID != previousWID)
        if selectionChanged || forceRefresh || historySnapshot == nil {
            refreshInspectorSnapshot()
        }
    }

    func refreshInspectorSnapshot() {
        currentHistoryTask?.cancel()
        guard let project = selectedProject else {
            historySnapshot = nil
            isLoadingHistory = false
            return
        }
        let worktree = selectedWorktree
        let targetPID = project.id
        let targetWID = worktree?.id

        if historySnapshot?.projectID != targetPID {
            isLoadingHistory = true
        }

        currentHistoryTask = Task(priority: .userInitiated) { [weak self] in
            let snap = await Task.detached(priority: .userInitiated) {
                GitHistoryService.loadSnapshot(for: project, selectedWorktree: worktree, maxCommits: 0)
            }.value

            guard !Task.isCancelled, let self else { return }
            guard self.selectedProject?.id == targetPID,
                  self.selectedWorktree?.id == targetWID else {
                return
            }
            self.historySnapshot = snap
            self.isLoadingHistory = false
        }
    }

    // MARK: - Code Editor, Shell & Finder Launchers

    func openInEditor(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let folderURL = URL(fileURLWithPath: path)
        let editor = configuration.preferredEditor

        // 1. Custom app path if `.custom`
        if editor == .custom {
            if let customPath = configuration.customEditorAppPath,
               FileManager.default.fileExists(atPath: customPath) {
                openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: customPath))
                return
            } else {
                chooseCustomEditorApp()
                if let customPath = configuration.customEditorAppPath,
                   FileManager.default.fileExists(atPath: customPath) {
                    openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: customPath))
                }
                return
            }
        }

        // 2. Locate installed `.app` bundle by bundle identifier
        for bundleID in editor.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                openFolder(folderURL, withApplicationAt: appURL)
                return
            }
        }

        // 3. Fallback standard `/Applications/...` paths
        for appPath in editor.fallbackAppPaths where FileManager.default.fileExists(atPath: appPath) {
            openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: appPath))
            return
        }

        // 4. Fallback CLI launcher (`code`, `cursor`, `zed`, etc.)
        if let cli = editor.cliCommand, ShellRunner.resolveExecutable(cli) != nil {
            _ = try? ShellRunner.run(executable: cli, arguments: [path])
            return
        }

        activeErrorMessage = "\(editor.displayName) was not found on this Mac. You can choose another editor in Settings."
    }

    func openInTerminal(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let folderURL = URL(fileURLWithPath: path)
        let terminal = configuration.preferredTerminal

        if terminal == .custom {
            if let customPath = configuration.customTerminalAppPath,
               FileManager.default.fileExists(atPath: customPath) {
                openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: customPath))
                return
            } else {
                chooseCustomTerminalApp()
                if let customPath = configuration.customTerminalAppPath,
                   FileManager.default.fileExists(atPath: customPath) {
                    openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: customPath))
                }
                return
            }
        }

        for bundleID in terminal.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                openFolder(folderURL, withApplicationAt: appURL)
                return
            }
        }

        for appPath in terminal.fallbackAppPaths where FileManager.default.fileExists(atPath: appPath) {
            openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: appPath))
            return
        }

        // Ultimate fallback to macOS built-in Terminal.app
        let builtInTerminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        openFolder(folderURL, withApplicationAt: builtInTerminal)
    }

    private func openFolder(_ folderURL: URL, withApplicationAt appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folderURL], withApplicationAt: appURL, configuration: config)
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parent.path)
            }
        }
    }

    func copyPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Concurrent-Safe Scoped Action Runner

    private func runScopedAction(
        label: String,
        onSuccess: @escaping @MainActor () async -> Void,
        onCleanupBusy: @escaping @MainActor () -> Void,
        work: @escaping @Sendable () throws -> ActionReport
    ) {
        statusMessage = label

        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try work()
                }.value

                await onSuccess()
                onCleanupBusy()
                withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                    self.lastReport = report
                }
                self.statusMessage = report.title
            } catch {
                onCleanupBusy()
                self.activeErrorMessage = error.localizedDescription
                self.statusMessage = "Action failed"
            }
        }
    }
}
