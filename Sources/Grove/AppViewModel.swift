import AppKit
import Foundation
import Observation
import GroveCore
import SwiftUI
import UniformTypeIdentifiers

enum DashboardFilter: String, CaseIterable, Identifiable {
    case all
    case readyToClean
    case worktreesOnly
    case branchesOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .readyToClean: return "Ready to Clean"
        case .worktreesOnly: return "Worktrees"
        case .branchesOnly: return "Idle Branches"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .readyToClean: return "checkmark.circle"
        case .worktreesOnly: return "folder.on.folder"
        case .branchesOnly: return "arrow.triangle.branch"
        }
    }
}

struct DashboardProjectEntry: Identifiable {
    let project: ProjectGroup
    let snapshot: ProjectHistorySnapshot?
    let worktrees: [WorktreeItem]
    let idleBranches: [LocalBranchInfo]

    var id: String { project.id }
    var totalItemCount: Int { worktrees.count + idleBranches.count }

    var removableBranches: [LocalBranchInfo] {
        idleBranches.filter(\.isSafeToRemove)
    }

    var prunableWorktrees: [WorktreeItem] {
        worktrees.filter { $0.kind == .prunable }
    }

    var hasRemote: Bool {
        snapshot?.hasRemote ?? (project.mainWorktree?.gitComparison?.hasRemote == true)
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
    var snapshotsByProjectID: [String: ProjectHistorySnapshot] = [:]
    var changedFilesByWorktreeID: [String: [WorkingTreeFileChange]] = [:]
    var loadingChangedFilesWorktreeIDs: Set<String> = []
    var scanSummary = ScanSummary()

    // Dashboard Filter & Search State
    var selectedFolderID: UUID?
    var activeFilter: DashboardFilter = .all
    var searchText: String = ""

    var isScanning: Bool = false
    var isLoadingSnapshots: Bool = false

    /// Scoped per-item busy tracking so acting on one project/worktree NEVER grays out other rows.
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
        if isScanning || isLoadingSnapshots || isPerformingAction {
            return statusMessage
        }
        guard !configuration.enabledFolderPaths.isEmpty else {
            return "No scan folders configured"
        }
        guard !projects.isEmpty else {
            return "No Git repositories found"
        }

        let entries = allDashboardEntries
        if entries.isEmpty {
            return "All clear across \(projects.count) repo\(projects.count == 1 ? "" : "s")"
        }

        let totalWorktrees = entries.reduce(0) { $0 + $1.worktrees.count }
        let totalBranches = entries.reduce(0) { $0 + $1.idleBranches.count }
        var parts = [
            "\(entries.count) project\(entries.count == 1 ? "" : "s")"
        ]
        if totalWorktrees > 0 {
            parts.append("\(totalWorktrees) worktree\(totalWorktrees == 1 ? "" : "s")")
        }
        if totalBranches > 0 {
            parts.append("\(totalBranches) idle branch\(totalBranches == 1 ? "" : "es")")
        }
        return parts.joined(separator: " · ")
    }

    var selectedFolder: ScanFolder? {
        guard let id = selectedFolderID else { return nil }
        return configuration.folders.first(where: { $0.id == id })
    }

    var hasActiveFilter: Bool {
        activeFilter != .all || selectedFolderID != nil || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Dashboard Grouping & Filtering (Only Projects With Worktrees or Idle Branches)

    private var folderScopedProjects: [ProjectGroup] {
        guard let folder = selectedFolder else { return projects }
        let rootCanonical = PathNormalizer.canonicalPath(folder.path)
        return projects.filter { group in
            Self.projectBelongsToOneLevelFolder(group, folderCanonicalPath: rootCanonical)
        }
    }

    /// All projects in the active folder scope that have at least one linked/prunable worktree or idle branch.
    var allDashboardEntries: [DashboardProjectEntry] {
        folderScopedProjects.compactMap { project in
            let snapshot = snapshotsByProjectID[project.id]
            let worktrees = Self.sortedLinkedWorktrees(for: project, snapshot: snapshot)
            let idleBranches = Self.sortedIdleBranches(from: snapshot)
            guard !worktrees.isEmpty || !idleBranches.isEmpty else { return nil }
            return DashboardProjectEntry(
                project: project,
                snapshot: snapshot,
                worktrees: worktrees,
                idleBranches: idleBranches
            )
        }
    }

    /// Filtered dashboard entries honoring `activeFilter` and `searchText`.
    /// Projects with 0 matching items are omitted automatically.
    var dashboardEntries: [DashboardProjectEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return allDashboardEntries.compactMap { entry in
            var worktrees = entry.worktrees
            var branches = entry.idleBranches

            switch activeFilter {
            case .all:
                break
            case .readyToClean:
                worktrees = worktrees.filter { WorktreeHygieneEvaluator.isMergedOrPrunable($0) }
                branches = branches.filter { $0.relationship.isMergedIntoBase }
            case .worktreesOnly:
                branches = []
            case .branchesOnly:
                worktrees = []
            }

            if !query.isEmpty {
                let projectMatches = entry.project.name.lowercased().contains(query)
                    || entry.project.primaryPath.lowercased().contains(query)
                if !projectMatches {
                    worktrees = worktrees.filter { wt in
                        wt.name.lowercased().contains(query)
                            || wt.path.lowercased().contains(query)
                            || (wt.branchName?.lowercased().contains(query) ?? false)
                    }
                    branches = branches.filter { branch in
                        branch.name.lowercased().contains(query)
                            || branch.subject.lowercased().contains(query)
                    }
                }
            }

            guard !worktrees.isEmpty || !branches.isEmpty else { return nil }
            return DashboardProjectEntry(
                project: entry.project,
                snapshot: entry.snapshot,
                worktrees: worktrees,
                idleBranches: branches
            )
        }
    }

    func itemCount(for filter: DashboardFilter) -> Int {
        switch filter {
        case .all:
            return allDashboardEntries.reduce(0) { $0 + $1.totalItemCount }
        case .readyToClean:
            return allDashboardEntries.reduce(0) { sum, entry in
                let wtCount = entry.worktrees.filter { WorktreeHygieneEvaluator.isMergedOrPrunable($0) }.count
                let brCount = entry.idleBranches.filter { $0.relationship.isMergedIntoBase }.count
                return sum + wtCount + brCount
            }
        case .worktreesOnly:
            return allDashboardEntries.reduce(0) { $0 + $1.worktrees.count }
        case .branchesOnly:
            return allDashboardEntries.reduce(0) { $0 + $1.idleBranches.count }
        }
    }

    /// Clean & merged (or missing/prunable) linked worktrees that are safe to remove right now.
    var readyToCleanWorktreeCount: Int {
        allDashboardEntries.reduce(0) { sum, entry in
            sum + entry.worktrees.filter { $0.isSafeToRemoveLinkedWorktree || $0.kind == .prunable }.count
        }
    }

    /// Idle local branches already merged into the base branch.
    var readyToCleanBranchCount: Int {
        allDashboardEntries.reduce(0) { sum, entry in
            sum + entry.removableBranches.count
        }
    }

    var readyToCleanTotalCount: Int {
        readyToCleanWorktreeCount + readyToCleanBranchCount
    }

    func dashboardProjectCount(in folder: ScanFolder) -> Int {
        let rootCanonical = PathNormalizer.canonicalPath(folder.path)
        return projects.filter { group in
            guard Self.projectBelongsToOneLevelFolder(group, folderCanonicalPath: rootCanonical) else { return false }
            if !group.subWorktrees.isEmpty { return true }
            return !Self.sortedIdleBranches(from: snapshotsByProjectID[group.id]).isEmpty
        }.count
    }

    private static func projectBelongsToOneLevelFolder(_ group: ProjectGroup, folderCanonicalPath: String) -> Bool {
        group.worktrees.contains { wt in
            let p = PathNormalizer.canonicalPath(wt.path)
            return p == folderCanonicalPath || (p as NSString).deletingLastPathComponent == folderCanonicalPath
        }
    }

    static func sortedLinkedWorktrees(for project: ProjectGroup, snapshot: ProjectHistorySnapshot?) -> [WorktreeItem] {
        project.subWorktrees.sorted { lhs, rhs in
            let lMerged = WorktreeHygieneEvaluator.isMergedOrPrunable(lhs)
            let rMerged = WorktreeHygieneEvaluator.isMergedOrPrunable(rhs)
            if lMerged != rMerged {
                return lMerged
            }
            let lIdle = WorktreeHygieneEvaluator.hasIdleCommit(lhs, snapshot: snapshot)
            let rIdle = WorktreeHygieneEvaluator.hasIdleCommit(rhs, snapshot: snapshot)
            if lIdle != rIdle {
                return lIdle
            }
            let lDays = WorktreeHygieneEvaluator.commitIdleDays(for: lhs, snapshot: snapshot)
            let rDays = WorktreeHygieneEvaluator.commitIdleDays(for: rhs, snapshot: snapshot)
            if lIdle && rIdle && lDays != rDays {
                return lDays > rDays
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Standalone local branches that are not the base trunk and not currently checked out in any worktree.
    static func sortedIdleBranches(from snapshot: ProjectHistorySnapshot?) -> [LocalBranchInfo] {
        guard let snapshot else { return [] }
        let idle = snapshot.localBranches.filter { branch in
            branch.relationship != .baseTrunk && branch.checkedOutWorktreeID == nil
        }
        return idle.sorted { lhs, rhs in
            let lRank = branchPriorityRank(lhs)
            let rRank = branchPriorityRank(rhs)
            if lRank != rRank {
                return lRank < rRank
            }
            if lRank == 1 && lhs.idleDays != rhs.idleDays {
                return lhs.idleDays > rhs.idleDays
            }
            let lDate = lhs.committedAt ?? .distantPast
            let rDate = rhs.committedAt ?? .distantPast
            if lDate != rDate {
                return lDate > rDate
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func branchPriorityRank(_ branch: LocalBranchInfo) -> Int {
        if branch.relationship.isMergedIntoBase {
            return 0
        }
        if branch.idleDays >= 14 {
            return 1
        }
        return 2
    }

    private func sortProjectsForDashboard(_ list: [ProjectGroup], snapshots: [String: ProjectHistorySnapshot]) -> [ProjectGroup] {
        list.sorted { lhs, rhs in
            let lCount = lhs.subWorktrees.count + Self.sortedIdleBranches(from: snapshots[lhs.id]).count
            let rCount = rhs.subWorktrees.count + Self.sortedIdleBranches(from: snapshots[rhs.id]).count
            if lCount != rCount {
                return lCount > rCount
            }
            if lhs.subWorktrees.count != rhs.subWorktrees.count {
                return lhs.subWorktrees.count > rhs.subWorktrees.count
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - On-Demand Working-Tree Diff Loading

    func loadChangedFilesIfNeeded(for worktree: WorktreeItem) {
        guard worktree.kind != .prunable, worktree.dirtyFilesCount > 0 else { return }
        guard changedFilesByWorktreeID[worktree.id] == nil,
              !loadingChangedFilesWorktreeIDs.contains(worktree.id) else {
            return
        }
        loadingChangedFilesWorktreeIDs.insert(worktree.id)
        let wtID = worktree.id
        let wtPath = worktree.path

        Task {
            let files = await Task.detached(priority: .userInitiated) {
                GitHistoryService.fetchWorkingTreeChanges(at: wtPath)
            }.value
            self.loadingChangedFilesWorktreeIDs.remove(wtID)
            self.changedFilesByWorktreeID[wtID] = files
        }
    }

    // MARK: - Configuration Management

    func persistAndRescan() {
        try? store.save(configuration)
        startScan()
    }

    func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders Containing Git Repositories"
        panel.message = "Grove checks each selected folder 1 level deep for Git repositories and groups all linked Git worktrees and idle branches."
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

    // MARK: - Full Repository + Branch Hygiene Scan

    func startScan() {
        currentScanTask?.cancel()

        let scanID = UUID()
        activeScanID = scanID
        appliedPartialSeq = 0

        guard !configuration.enabledFolderPaths.isEmpty else {
            projects = []
            snapshotsByProjectID = [:]
            changedFilesByWorktreeID = [:]
            scanSummary = ScanSummary()
            isScanning = false
            isLoadingSnapshots = false
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
                self.projects = self.sortProjectsForDashboard(partial, snapshots: self.snapshotsByProjectID)
                self.scanSummary = ScanSummary(projects: self.projects)
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

            self.isLoadingSnapshots = true
            self.statusMessage = "Inspecting branches across \(discovered.count) repo\(discovered.count == 1 ? "" : "s")…"

            // Load lightweight hygiene snapshots (branches, HEAD commits, detached reachability) in parallel
            let loadedSnapshots = await Self.loadSnapshotsInParallel(for: discovered)
            guard !Task.isCancelled, self.activeScanID == scanID else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let ordered = self.sortProjectsForDashboard(discovered, snapshots: loadedSnapshots)

            withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                self.snapshotsByProjectID = loadedSnapshots
                self.projects = ordered
                self.changedFilesByWorktreeID = [:]
                self.scanSummary = ScanSummary(projects: ordered, scanDurationSeconds: elapsed)
            }

            self.isScanning = false
            self.isLoadingSnapshots = false
            self.lastScanFinishedAt = Date()
            self.statusMessage = String(
                format: "Scanned %d repo%@ in %.2fs",
                ordered.count,
                ordered.count == 1 ? "" : "s",
                elapsed
            )
        }
    }

    private static func loadSnapshotsInParallel(for projects: [ProjectGroup]) async -> [String: ProjectHistorySnapshot] {
        guard !projects.isEmpty else { return [:] }
        let maxConcurrent = min(6, max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        return await withTaskGroup(of: (String, ProjectHistorySnapshot)?.self, returning: [String: ProjectHistorySnapshot].self) { group in
            var nextIndex = 0
            let initialBatch = min(maxConcurrent, projects.count)

            for _ in 0..<initialBatch {
                let project = projects[nextIndex]
                nextIndex += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    let snap = GitHistoryService.loadSnapshot(
                        for: project,
                        selectedWorktree: nil,
                        maxCommits: 0,
                        includeWorkingTreeChanges: false
                    )
                    return (project.id, snap)
                }
            }

            var results: [String: ProjectHistorySnapshot] = [:]
            results.reserveCapacity(projects.count)

            while let completed = await group.next() {
                if nextIndex < projects.count, !Task.isCancelled {
                    let project = projects[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        if Task.isCancelled { return nil }
                        let snap = GitHistoryService.loadSnapshot(
                            for: project,
                            selectedWorktree: nil,
                            maxCommits: 0,
                            includeWorkingTreeChanges: false
                        )
                        return (project.id, snap)
                    }
                }
                if let (id, snap) = completed {
                    results[id] = snap
                }
            }
            return results
        }
    }

    /// Automatically refreshes repository & worktree status when the Dashboard window opens or regains focus.
    func refreshOnDashboardFocusIfNeeded() {
        checkForUpdates(manual: false)
        guard !configuration.enabledFolderPaths.isEmpty else { return }
        guard !isScanning && !isLoadingSnapshots && !isPerformingAction else { return }
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
                self?.changedFilesByWorktreeID.removeValue(forKey: worktree.id)
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

    // MARK: - Worktree & Project Cut / Removal (Smooth In-Place Animated Removal)

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
                await self?.refreshSnapshotOnly(forProjectID: project.id)
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
                self?.changedFilesByWorktreeID.removeValue(forKey: worktree.id)
                self?.removeWorktreesInMemory(ids: [worktree.id], fromProjectID: project.id)
                await self?.refreshSnapshotOnly(forProjectID: project.id)
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
                    self.snapshotsByProjectID[project.id]?.localBranches.removeAll { $0.name == branch.name }
                    self.lastReport = ActionReport(
                        title: force
                            ? "Force deleted branch '\(branch.name)'"
                            : "Deleted branch '\(branch.name)'",
                        affectedCount: 1
                    )
                }
                self.statusMessage = "Deleted branch '\(branch.name)'"
                await self.refreshSnapshotOnly(forProjectID: project.id)
            } catch let GitWorktreeError.branchRequiresForceDelete(_, gitStderr) {
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
        guard let snap = snapshotsByProjectID[project.id] else { return }
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
                    self.snapshotsByProjectID[project.id]?.localBranches.removeAll { deletedSet.contains($0.name) }
                    self.lastReport = ActionReport(
                        title: "Cleaned \(deletedSet.count) merged branch\(deletedSet.count == 1 ? "" : "es")",
                        affectedCount: deletedSet.count,
                        warnings: result.2
                    )
                }
                self.statusMessage = "Cleaned \(deletedSet.count) merged branch\(deletedSet.count == 1 ? "" : "es")"
                await self.refreshSnapshotOnly(forProjectID: project.id)
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

    // MARK: - Smooth In-Place Animated Updates

    private func removeWorktreesInMemory(ids: Set<String>, fromProjectID projectID: String) {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
            if let pIdx = projects.firstIndex(where: { $0.id == projectID }) {
                projects[pIdx].worktrees.removeAll { ids.contains($0.id) }
            }
            scanSummary = ScanSummary(projects: projects)
        }
    }

    private func removeProjectInMemory(projectID: String) {
        withAnimation(.snappy(duration: 0.30, extraBounce: 0)) {
            projects.removeAll { $0.id == projectID }
            snapshotsByProjectID.removeValue(forKey: projectID)
            scanSummary = ScanSummary(projects: projects)
        }
    }

    private func refreshProjectInPlace(_ project: ProjectGroup) async {
        let snapshotConfig = configuration
        let refreshed = await ProjectScanner.refreshSingleProject(project, configuration: snapshotConfig)
        let refreshedSnapshot: ProjectHistorySnapshot?
        if let refreshed {
            refreshedSnapshot = await Task.detached(priority: .userInitiated) {
                GitHistoryService.loadSnapshot(
                    for: refreshed,
                    selectedWorktree: nil,
                    maxCommits: 0,
                    includeWorkingTreeChanges: false
                )
            }.value
        } else {
            refreshedSnapshot = nil
        }

        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
            if let refreshed {
                if let pIdx = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[pIdx] = refreshed
                }
                if let refreshedSnapshot {
                    snapshotsByProjectID[project.id] = refreshedSnapshot
                }
            } else {
                projects.removeAll { $0.id == project.id }
                snapshotsByProjectID.removeValue(forKey: project.id)
            }
            scanSummary = ScanSummary(projects: projects)
        }
    }

    private func refreshSnapshotOnly(forProjectID projectID: String) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let snap = await Task.detached(priority: .userInitiated) {
            GitHistoryService.loadSnapshot(
                for: project,
                selectedWorktree: nil,
                maxCommits: 0,
                includeWorkingTreeChanges: false
            )
        }.value
        withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
            self.snapshotsByProjectID[projectID] = snap
        }
    }

    // MARK: - Code Editor, Shell & Finder Launchers

    func openInEditor(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let folderURL = URL(fileURLWithPath: path)
        let editor = configuration.preferredEditor

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

        for bundleID in editor.bundleIdentifiers {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                openFolder(folderURL, withApplicationAt: appURL)
                return
            }
        }

        for appPath in editor.fallbackAppPaths where FileManager.default.fileExists(atPath: appPath) {
            openFolder(folderURL, withApplicationAt: URL(fileURLWithPath: appPath))
            return
        }

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
