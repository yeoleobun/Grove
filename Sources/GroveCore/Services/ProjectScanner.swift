import Darwin
import Foundation

public enum ProjectScanner {
    private struct GitRepoBlueprint: Sendable {
        let commonDir: String
        let commonInode: InodeIdentifier
        let porcelainWorktrees: [GitPorcelainWorktree]
    }

    /// Scans each configured folder **strictly 1 level deep** (`<folder>/.git` and `<folder>/<child>/.git`),
    /// discovers all related Git worktrees via `.git` / `commondir` / `.git/worktrees`, deduplicates overlapping
    /// folders/symlinks/worktrees via canonical paths + APFS `(dev, ino)` inodes, and streams live Git status
    /// (`Needs Commit`, `Needs Push`, `Awaiting Merge`, `Clean · Merged`).
    public static func scan(
        configuration: ScanConfiguration,
        progress: (@Sendable (String) -> Void)? = nil,
        onPartialResults: (@Sendable ([ProjectGroup]) -> Void)? = nil
    ) async -> [ProjectGroup] {
        let scanRoots = deduplicateExactScanFolders(configuration.enabledFolderPaths)
        guard !scanRoots.isEmpty else { return [] }

        let ignoredNames = Set(configuration.ignoredDirectoryNames)

        // STAGE 1: 1-Level-Deep Universal Git Discovery (< 2 ms, zero recursive crawling!)
        progress?("Checking scan folders for Git repositories…")
        let discoveredGitDirs = discoverOneLevelGitDirectories(
            in: scanRoots,
            ignoredNames: ignoredNames
        )

        guard !discoveredGitDirs.isEmpty, !Task.isCancelled else { return [] }

        // Group & deduplicate discovered Git checkouts by canonical `gitCommonDir` `(st_dev, st_ino)` inode,
        // so even if Folder A contains `main` and Folder B contains a linked worktree (or a symlink),
        // they always unify into ONE ProjectGroup.
        var worktreeToCommonInode: [String: InodeIdentifier] = [:]
        var gitBlueprints: [InodeIdentifier: GitRepoBlueprint] = [:]
        var gitDiscoveredWorktrees: [InodeIdentifier: Set<String>] = [:]

        for rawDir in discoveredGitDirs {
            if Task.isCancelled { return [] }

            let canonicalWT = PathNormalizer.canonicalPath(rawDir)
            let commonInode: InodeIdentifier

            if let cached = worktreeToCommonInode[canonicalWT] {
                commonInode = cached
            } else if let resolvedCommon = GitWorktreeService.resolveGitCommonDir(for: canonicalWT),
                      let inode = directoryInode(at: resolvedCommon) {
                commonInode = inode
                worktreeToCommonInode[canonicalWT] = inode

                if gitBlueprints[inode] == nil {
                    let wtList = deduplicatePorcelainWorktrees(
                        GitWorktreeService
                            .listWorktrees(for: canonicalWT, gitCommonDir: resolvedCommon)
                            .filter { !$0.isBare }
                    )
                    gitBlueprints[inode] = GitRepoBlueprint(
                        commonDir: resolvedCommon,
                        commonInode: inode,
                        porcelainWorktrees: wtList
                    )
                }
            } else {
                continue
            }

            gitDiscoveredWorktrees[commonInode, default: []].insert(canonicalWT)
        }

        // Build instant Stage-1 skeleton groups (< 5 ms)
        var currentGroups: [ProjectGroup] = []

        for (commonInode, blueprint) in gitBlueprints {
            let discoveredWTs = gitDiscoveredWorktrees[commonInode] ?? []
            var entries = blueprint.porcelainWorktrees

            if entries.isEmpty {
                entries = discoveredWTs.sorted().map { GitPorcelainWorktree(path: $0) }
            } else if !configuration.includeExternalWorktrees {
                let primaryPath = entries.first?.path ?? ""
                entries = entries.enumerated().compactMap { idx, wt in
                    if idx == 0
                        || wt.isPrunable
                        || isRelatedToScanFolders(wt.path, primaryPath: primaryPath, scanRoots: scanRoots)
                        || discoveredWTs.contains(wt.path) {
                        return wt
                    }
                    return nil
                }
            }

            if let skeleton = buildGitSkeletonGroup(
                id: "git:\(blueprint.commonDir)",
                commonDir: blueprint.commonDir,
                entries: entries,
                scanRoots: scanRoots
            ) {
                currentGroups.append(skeleton)
            }
        }

        guard !currentGroups.isEmpty else { return [] }
        currentGroups = sortProjectsDefault(currentGroups)

        // Emit Stage-1 instant project list to UI right away!
        onPartialResults?(currentGroups)

        // STAGE 2: Bounded Parallel Git Working-Tree Status + Upstream Push + Base Merge Inspection
        progress?("Inspecting Git status across \(currentGroups.count) project\(currentGroups.count == 1 ? "" : "s")…")

        let maxConcurrentProjects = min(6, max(4, ProcessInfo.processInfo.activeProcessorCount - 2))

        let finalGroups = await withTaskGroup(of: (Int, ProjectGroup)?.self, returning: [ProjectGroup].self) { group in
            var nextIndex = 0
            let initialBatch = min(maxConcurrentProjects, currentGroups.count)

            for _ in 0..<initialBatch {
                let idx = nextIndex
                let skeleton = currentGroups[idx]
                nextIndex += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    let hydrated = await hydrateProjectGitStatus(skeleton)
                    return (idx, hydrated)
                }
            }

            var live = currentGroups
            while let completed = await group.next() {
                if nextIndex < currentGroups.count, !Task.isCancelled {
                    let idx = nextIndex
                    let skeleton = currentGroups[idx]
                    nextIndex += 1
                    group.addTask {
                        if Task.isCancelled { return nil }
                        let hydrated = await hydrateProjectGitStatus(skeleton)
                        return (idx, hydrated)
                    }
                }

                guard let (idx, hydrated) = completed else { continue }
                live[idx] = hydrated
                if let onPartialResults, !Task.isCancelled {
                    onPartialResults(sortProjectsDefault(live))
                }
            }
            return sortProjectsDefault(live)
        }

        return finalGroups
    }

    /// Silently refreshes Git status for **one** `ProjectGroup` in ~10–15 ms without rescanning any other repository
    /// or emitting intermediate `isInspecting` skeletons.
    public static func refreshSingleProject(
        _ project: ProjectGroup,
        configuration: ScanConfiguration
    ) async -> ProjectGroup? {
        let primaryCanonical = PathNormalizer.canonicalPath(project.primaryPath)
        var st = stat()
        guard stat(primaryCanonical, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        let scanRoots = deduplicateExactScanFolders(configuration.enabledFolderPaths)
        let commonDir: String = project.gitCommonDir.isEmpty
            ? (GitWorktreeService.resolveGitCommonDir(for: primaryCanonical) ?? primaryCanonical)
            : project.gitCommonDir
        var entries = deduplicatePorcelainWorktrees(
            GitWorktreeService
                .listWorktrees(for: primaryCanonical, gitCommonDir: commonDir)
                .filter { !$0.isBare }
        )

        if entries.isEmpty {
            entries = [GitPorcelainWorktree(path: primaryCanonical)]
        } else if !configuration.includeExternalWorktrees {
            let primaryPath = entries.first?.path ?? primaryCanonical
            entries = entries.enumerated().compactMap { idx, wt in
                if idx == 0
                    || wt.isPrunable
                    || isRelatedToScanFolders(wt.path, primaryPath: primaryPath, scanRoots: scanRoots) {
                    return wt
                }
                return nil
            }
        }

        guard let skeleton = buildGitSkeletonGroup(
            id: project.id,
            commonDir: commonDir,
            entries: entries,
            scanRoots: scanRoots
        ) else {
            return nil
        }

        return await hydrateProjectGitStatus(skeleton)
    }

    // MARK: - Stage 1: Strictly 1-Level-Deep Universal Git Discovery

    /// Checks only:
    ///   • Level 0: `<scanFolder>/.git` (in case the user added a Git repository folder directly)
    ///   • Level 1: `<scanFolder>/<child>/.git` (immediate subdirectories only — never recursive!)
    /// Deduplicates all discovered directories by APFS `(st_dev, st_ino)` inode so overlapping scan folders
    /// or symlinks never produce duplicate candidates.
    private static func discoverOneLevelGitDirectories(
        in scanRoots: [String],
        ignoredNames: Set<String>
    ) -> [String] {
        var seenCandidateInodes = Set<InodeIdentifier>()
        var results: [String] = []

        for root in scanRoots {
            if isGitCheckoutDirectory(root),
               let inode = directoryInode(at: root) {
                if seenCandidateInodes.insert(inode).inserted {
                    results.append(PathNormalizer.canonicalPath(root))
                }
                // `root` itself is a Git checkout; any nested worktrees inside `<root>/.worktrees`
                // are discovered automatically via `git worktree list`!
                continue
            }

            guard let dirPtr = opendir(root) else { continue }
            defer { closedir(dirPtr) }

            while let entryPtr = readdir(dirPtr) {
                let entry = entryPtr.pointee
                if entry.d_name.0 == 46 {
                    // Skip `.`, `..`, and hidden dot-directories at scan-folder level
                    continue
                }

                let name = withUnsafePointer(to: entry.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) { cStr in
                        String(cString: cStr)
                    }
                }

                if ignoredNames.contains(name) {
                    continue
                }

                let childRaw = root.hasSuffix("/") ? (root + name) : (root + "/" + name)

                var st = stat()
                guard stat(childRaw, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
                    continue
                }

                let inode = InodeIdentifier(dev: st.st_dev, ino: st.st_ino)
                guard !seenCandidateInodes.contains(inode) else {
                    continue
                }

                let canonicalChild = PathNormalizer.canonicalPath(childRaw)
                if isGitCheckoutDirectory(canonicalChild) {
                    seenCandidateInodes.insert(inode)
                    results.append(canonicalChild)
                }
            }
        }

        return results.sorted()
    }

    private static func isGitCheckoutDirectory(_ dir: String) -> Bool {
        access(dir + "/.git", F_OK) == 0
    }

    private static func directoryInode(at path: String) -> InodeIdentifier? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return InodeIdentifier(dev: st.st_dev, ino: st.st_ino)
    }

    private static func deduplicatePorcelainWorktrees(_ items: [GitPorcelainWorktree]) -> [GitPorcelainWorktree] {
        var seenInodes = Set<InodeIdentifier>()
        var seenPaths = Set<String>()
        var unique: [GitPorcelainWorktree] = []

        for item in items {
            let normPath = PathNormalizer.canonicalPath(item.path)
            if let inode = directoryInode(at: normPath) {
                guard seenInodes.insert(inode).inserted else { continue }
                seenPaths.insert(normPath)
            } else {
                guard seenPaths.insert(normPath).inserted else { continue }
            }
            var copy = item
            copy.path = normPath
            unique.append(copy)
        }
        return unique
    }

    private static func buildGitSkeletonGroup(
        id: String,
        commonDir: String,
        entries: [GitPorcelainWorktree],
        scanRoots: [String]
    ) -> ProjectGroup? {
        guard let first = entries.first else { return nil }
        let primaryPath = first.path

        var worktrees: [WorktreeItem] = []
        worktrees.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let wtPath = entry.path
            var st = stat()
            let existsOnDisk = lstat(wtPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            let kind: WorktreeKind = (!existsOnDisk || entry.isPrunable)
                ? .prunable
                : (index == 0 ? .main : .linked)
            let isExternal = !isRelatedToScanFolders(wtPath, primaryPath: primaryPath, scanRoots: scanRoots)

            if kind == .prunable {
                worktrees.append(
                    WorktreeItem(
                        path: wtPath,
                        name: URL(fileURLWithPath: wtPath).lastPathComponent,
                        kind: .prunable,
                        isExternalToScanRoots: isExternal,
                        branchName: entry.branch,
                        headCommitShort: entry.head.map { String($0.prefix(7)) },
                        isDetached: entry.isDetached,
                        isLocked: entry.isLocked,
                        lockReason: entry.lockReason,
                        prunableReason: entry.prunableReason ?? "Worktree directory no longer exists on disk",
                        isInspecting: false
                    )
                )
            } else {
                let modDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                worktrees.append(
                    WorktreeItem(
                        path: wtPath,
                        name: URL(fileURLWithPath: wtPath).lastPathComponent,
                        kind: kind,
                        isExternalToScanRoots: isExternal,
                        branchName: entry.branch,
                        headCommitShort: entry.head.map { String($0.prefix(7)) },
                        isDetached: entry.isDetached,
                        isLocked: entry.isLocked,
                        lockReason: entry.lockReason,
                        lastModified: modDate,
                        isInspecting: true
                    )
                )
            }
        }

        guard !worktrees.isEmpty else { return nil }
        let projectName = URL(fileURLWithPath: primaryPath).lastPathComponent

        return ProjectGroup(
            id: id,
            name: projectName,
            primaryPath: primaryPath,
            gitCommonDir: commonDir,
            worktrees: worktrees
        )
    }

    // MARK: - Stage 2: Parallel Git Inspection

    private static func hydrateProjectGitStatus(_ skeleton: ProjectGroup) async -> ProjectGroup {
        let preferredBase = GitWorktreeService.resolvePreferredBase(
            in: skeleton.primaryPath,
            gitCommonDir: skeleton.gitCommonDir
        )

        // Fast path for single-worktree repositories: avoid extra TaskGroup overhead
        if skeleton.worktrees.count <= 1 {
            var updated = skeleton
            updated.worktrees = skeleton.worktrees.map { wt in
                guard wt.kind != .prunable else { return wt }
                return hydrateSingleWorktree(wt, preferredBase: preferredBase)
            }
            return updated
        }

        let maxConcurrentWorktrees = min(4, skeleton.worktrees.count)
        let updatedWorktrees = await withTaskGroup(of: (Int, WorktreeItem).self, returning: [WorktreeItem].self) { group in
            var nextWTIndex = 0
            for _ in 0..<maxConcurrentWorktrees {
                let idx = nextWTIndex
                let wt = skeleton.worktrees[idx]
                nextWTIndex += 1
                group.addTask {
                    if wt.kind == .prunable {
                        return (idx, wt)
                    }
                    let hydrated = hydrateSingleWorktree(wt, preferredBase: preferredBase)
                    return (idx, hydrated)
                }
            }

            var pairs: [(Int, WorktreeItem)] = []
            pairs.reserveCapacity(skeleton.worktrees.count)
            while let p = await group.next() {
                pairs.append(p)
                if nextWTIndex < skeleton.worktrees.count {
                    let idx = nextWTIndex
                    let wt = skeleton.worktrees[idx]
                    nextWTIndex += 1
                    group.addTask {
                        if wt.kind == .prunable {
                            return (idx, wt)
                        }
                        let hydrated = hydrateSingleWorktree(wt, preferredBase: preferredBase)
                        return (idx, hydrated)
                    }
                }
            }
            var sorted = pairs.sorted { $0.0 < $1.0 }.map(\.1)
            sorted.sort { lhs, rhs in
                if lhs.kind.sortRank != rhs.kind.sortRank {
                    return lhs.kind.sortRank < rhs.kind.sortRank
                }
                if lhs.actionState.urgencyRank != rhs.actionState.urgencyRank {
                    return lhs.actionState.urgencyRank < rhs.actionState.urgencyRank
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return sorted
        }

        var updated = skeleton
        updated.worktrees = updatedWorktrees
        return updated
    }

    private static func hydrateSingleWorktree(
        _ worktree: WorktreeItem,
        preferredBase: PreferredGitBase
    ) -> WorktreeItem {
        let snapshot = GitWorktreeService.inspectStatusAndUpstream(at: worktree.path)
        let comparison = GitWorktreeService.inspectBranchComparison(
            at: worktree.path,
            kind: worktree.kind,
            branchName: worktree.branchName,
            upstreamRef: snapshot.upstreamRef,
            unpushedCount: snapshot.unpushedCount,
            behindUpstreamCount: snapshot.behindUpstreamCount,
            preferredBase: preferredBase
        )

        var latestDate = worktree.lastModified
        if let commitDate = comparison?.lastCommit?.committedAt,
           latestDate == nil || commitDate > latestDate! {
            latestDate = commitDate
        }

        // Also check `.git/index` mtime when `.git` is a directory so staging/unstaging updates `lastModified`
        var indexSt = stat()
        let indexPath = (try? ShellRunner.run(executable: "git", arguments: ["-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-path", "index"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let indexPath, lstat(indexPath, &indexSt) == 0 {
            let idxDate = Date(timeIntervalSince1970: TimeInterval(indexSt.st_mtimespec.tv_sec))
            if latestDate == nil || idxDate > latestDate! {
                latestDate = idxDate
            }
        }

        var hydrated = worktree
        hydrated.workingTreeStatus = snapshot.status
        hydrated.gitComparison = comparison
        if hydrated.headCommitShort == nil, let sha = comparison?.lastCommit?.shortHash {
            hydrated.headCommitShort = sha
        }
        hydrated.lastModified = latestDate
        hydrated.isInspecting = false
        return hydrated
    }

    // MARK: - Helpers

    private static func sortProjectsDefault(_ list: [ProjectGroup]) -> [ProjectGroup] {
        list.sorted { lhs, rhs in
            if lhs.highestUrgencyRank != rhs.highestUrgencyRank {
                return lhs.highestUrgencyRank < rhs.highestUrgencyRank
            }
            if lhs.subWorktrees.count != rhs.subWorktrees.count {
                return lhs.subWorktrees.count > rhs.subWorktrees.count
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func deduplicateExactScanFolders(_ rawPaths: [String]) -> [String] {
        var seenInodes = Set<InodeIdentifier>()
        var kept: [String] = []
        for raw in rawPaths {
            let canonical = PathNormalizer.canonicalPath(raw)
            guard let inode = directoryInode(at: canonical) else { continue }
            if seenInodes.insert(inode).inserted {
                kept.append(canonical)
            }
        }
        return kept
    }

    private static func isRelatedToScanFolders(
        _ worktreePath: String,
        primaryPath: String,
        scanRoots: [String]
    ) -> Bool {
        let norm = PathNormalizer.canonicalPath(worktreePath)
        if !primaryPath.isEmpty && (norm == primaryPath || norm.hasPrefix(primaryPath + "/")) {
            return true
        }
        let parent = (norm as NSString).deletingLastPathComponent
        return scanRoots.contains { root in
            norm == root || parent == root
        }
    }
}
