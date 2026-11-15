import Foundation
import Testing
@testable import GroveCore

@Suite("Grove Git & Worktree Integration Tests")
struct GroveTests {
    private func makeTempDirectory() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.resolvingSymlinksInPath()
    }

    private func initGitRepo(at dir: URL, initialFile: String = "README.md", content: String = "# Repo\n") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(initialFile), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["init", "-b", "main"], currentDirectory: dir.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["config", "user.email", "test@example.com"], currentDirectory: dir.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: dir.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: dir.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "initial"], currentDirectory: dir.path)
    }

    @Test("Failed inspections and unknown integration targets never become cleanup candidates")
    func failedInspectionIsNotClean() throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let status = GitWorktreeService.inspectStatusAndUpstream(at: sandbox.path).status
        #expect(status.inspectionError != nil)
        #expect(!status.isClean)
        let item = WorktreeItem(path: sandbox.path, name: "unknown", kind: .linked, workingTreeStatus: status)
        #expect(!item.isSafeToRemoveLinkedWorktree)
        let noBase = WorktreeItem(path: sandbox.path, name: "no base", kind: .linked)
        #expect(!noBase.isSafeToRemoveLinkedWorktree)
    }

    @Test("Cleanup rechecks detached HEAD and preserves unique commits before removal")
    func staleDetachedCleanupPreservesHistory() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = sandbox.appendingPathComponent("repo")
        let checkout = sandbox.appendingPathComponent("detached")
        try initGitRepo(at: repo)
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", repo.path, "worktree", "add", "--detach", checkout.path])
        let project = try #require(await ProjectScanner.scan(configuration: ScanConfiguration(folders: [ScanFolder(path: sandbox.path)])).first)
        let staleItem = try #require(project.worktrees.first { $0.path == checkout.path })
        #expect(staleItem.isSafeToRemoveLinkedWorktree)
        try "unique\n".write(to: checkout.appendingPathComponent("unique.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", checkout.path, "add", "."])
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", checkout.path, "commit", "-m", "unique detached work"])
        let head = try ShellRunner.run(executable: "git", arguments: ["-C", checkout.path, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(throws: GitWorktreeError.self) {
            _ = try GitWorktreeService.removeLinkedWorktree(staleItem, in: project, options: WorktreeRemovalOptions())
        }
        #expect(FileManager.default.fileExists(atPath: checkout.path))
        let warnings = try GitWorktreeService.removeLinkedWorktree(staleItem, in: project, options: WorktreeRemovalOptions(preserveCommits: true))
        #expect(warnings.contains { $0.contains("refs/grove/rescued/") })
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        let refs = try ShellRunner.run(executable: "git", arguments: ["-C", repo.path, "for-each-ref", "--format=%(objectname)", "refs/grove/rescued/"])
        #expect(refs.stdout.contains(head))
    }

    @Test("Ignored local files prevent permanent removal even after a clean scan")
    func ignoredFilesArePreserved() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = sandbox.appendingPathComponent("repo")
        let checkout = sandbox.appendingPathComponent("checkout")
        try initGitRepo(at: repo, initialFile: ".gitignore", content: ".env\n")
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", repo.path, "worktree", "add", "--detach", checkout.path])
        let project = try #require(await ProjectScanner.scan(configuration: ScanConfiguration(folders: [ScanFolder(path: sandbox.path)])).first)
        let item = try #require(project.worktrees.first { $0.path == checkout.path })
        try "local config".write(to: checkout.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let status = GitWorktreeService.inspectStatusAndUpstream(at: checkout.path).status
        #expect(status.ignoredCount == 1)
        var updated = item
        updated.workingTreeStatus = status
        #expect(!updated.isSafeToRemoveLinkedWorktree)
        #expect(throws: GitWorktreeError.self) {
            _ = try GitWorktreeService.removeLinkedWorktree(item, in: project, options: WorktreeRemovalOptions(forceIfDirtyOrLocked: true))
        }
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".env").path))
    }

    @Test("Ancestry takes priority over feature upstream push status")
    func containedCommitsDoNotNeedAnotherPush() {
        let item = WorktreeItem(path: "/unused", name: "merged", kind: .linked,
            gitComparison: GitBranchComparison(upstreamRef: "origin/feature", unpushedCount: 2,
                baseRef: "origin/main", aheadOfBaseCount: 0, behindBaseCount: 1))
        #expect(item.isSafeToRemoveLinkedWorktree)
    }

    @Test("Pruning missing detached worktrees retains their commits")
    func missingDetachedWorktreeRecovery() throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = sandbox.appendingPathComponent("repo")
        let checkout = sandbox.appendingPathComponent("checkout")
        try initGitRepo(at: repo)
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", repo.path, "worktree", "add", "--detach", checkout.path])
        _ = try ShellRunner.run(executable: "git", arguments: ["-C", checkout.path, "commit", "--allow-empty", "-m", "detached history"])
        let head = try ShellRunner.run(executable: "git", arguments: ["-C", checkout.path, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: checkout)
        try GitWorktreeService.pruneWorktrees(in: repo.path)
        let refs = try ShellRunner.run(executable: "git", arguments: ["-C", repo.path, "for-each-ref", "--format=%(objectname)", "refs/grove/rescued/"])
        #expect(refs.stdout.contains(head))
        #expect(GitWorktreeService.listWorktrees(for: repo.path).count == 1)
    }

    @Test("Discovers Git repos of any language (JS, Python, Rust), groups linked & nested worktrees, and ignores non-Git dirs")
    func discoversUniversalGitReposAndGroupsWorktrees() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 1. TypeScript / Web Git repository with sibling & nested worktrees
        let webRepo = sandbox.appendingPathComponent("web-dashboard", isDirectory: true)
        try initGitRepo(at: webRepo, initialFile: "package.json", content: "{\"name\":\"web-dashboard\"}\n")

        let siblingWT = sandbox.appendingPathComponent("web-wt-auth", isDirectory: true)
        let nestedWT = webRepo.appendingPathComponent(".worktrees/hotfix", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", siblingWT.path, "-b", "feat/auth"], currentDirectory: webRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", nestedWT.path, "-b", "fix/hotfix"], currentDirectory: webRepo.path)

        // 2. Python Git repository (single checkout)
        let pyRepo = sandbox.appendingPathComponent("ml-pipeline", isDirectory: true)
        try initGitRepo(at: pyRepo, initialFile: "pyproject.toml", content: "[project]\nname = \"ml-pipeline\"\n")

        // 3. Plain non-Git folder (ignored) + 2-levels-deep Git repo (ignored by 1-level scan)
        let plainFolder = sandbox.appendingPathComponent("scratch-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        try "hello".write(to: plainFolder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let buriedRepo = sandbox.appendingPathComponent("archive/old-repo", isDirectory: true)
        try initGitRepo(at: buriedRepo)

        let config = ScanConfiguration(folders: [ScanFolder(path: sandbox.path)])
        let projects = await ProjectScanner.scan(configuration: config)

        #expect(projects.count == 2)

        let webGroup = try #require(projects.first(where: { $0.name == "web-dashboard" }))
        #expect(webGroup.worktrees.count == 3)
        #expect(webGroup.subWorktrees.count == 2)
        #expect(webGroup.mainWorktree?.kind == .main)

        let pyGroup = try #require(projects.first(where: { $0.name == "ml-pipeline" }))
        #expect(pyGroup.worktrees.count == 1)
        #expect(pyGroup.subWorktrees.isEmpty)
    }

    @Test("Accurately classifies Needs Commit, Needs Push, Awaiting Merge, Merged, Squash-merged, Synced, and Missing")
    func fullActionStateLifecycleClassification() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let originBare = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["init", "--bare", "-b", "main", originBare.path])

        let scanRoot = sandbox.appendingPathComponent("scan", isDirectory: true)
        let mainRepo = scanRoot.appendingPathComponent("api-service", isDirectory: true)
        try initGitRepo(at: mainRepo, initialFile: "app.py", content: "print('v1')\n")
        _ = try ShellRunner.run(executable: "git", arguments: ["remote", "add", "origin", originBare.path], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "main"], currentDirectory: mainRepo.path)

        // 1. Ancestor-merged worktree (created at v1 before main advances)
        let ancestorWT = scanRoot.appendingPathComponent("wt-ancestor", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", ancestorWT.path, "-b", "feat/ancestor"], currentDirectory: mainRepo.path)

        // 2. Squash-merged worktree (2 commits squashed into main + unrelated commit on main)
        let squashWT = scanRoot.appendingPathComponent("wt-squash", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", squashWT.path, "-b", "feat/squash"], currentDirectory: mainRepo.path)
        try "def feature(): return 1\n".write(to: squashWT.appendingPathComponent("feature.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: squashWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "squash 1"], currentDirectory: squashWT.path)
        try "def feature(): return 2\n".write(to: squashWT.appendingPathComponent("feature.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-am", "squash 2"], currentDirectory: squashWT.path)

        _ = try ShellRunner.run(executable: "git", arguments: ["merge", "--squash", "feat/squash"], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: squash merge (#1)"], currentDirectory: mainRepo.path)
        try "EXTRA = True\n".write(to: mainRepo.appendingPathComponent("extra.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "chore: extra main work"], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "origin", "main"], currentDirectory: mainRepo.path)

        // 3. Synced worktree sitting cleanly at current `origin/main`
        let syncedWT = scanRoot.appendingPathComponent("wt-synced", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", syncedWT.path, "-b", "feat/synced"], currentDirectory: mainRepo.path)

        // 4. Local commit NOT pushed yet -> `needsPush`
        let unpushedWT = scanRoot.appendingPathComponent("wt-unpushed", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", unpushedWT.path, "-b", "feat/unpushed"], currentDirectory: mainRepo.path)
        try "LOCAL_ONLY = 1\n".write(to: unpushedWT.appendingPathComponent("local.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: unpushedWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: local commit"], currentDirectory: unpushedWT.path)

        // 5. Pushed to `origin/feat/pr-open`, awaiting merge into `origin/main` -> `awaitingMerge`
        let pushedPRWT = scanRoot.appendingPathComponent("wt-pr-open", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", pushedPRWT.path, "-b", "feat/pr-open"], currentDirectory: mainRepo.path)
        try "PR_READY = 1\n".write(to: pushedPRWT.appendingPathComponent("pr.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: pushedPRWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: pushed for PR"], currentDirectory: pushedPRWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "feat/pr-open"], currentDirectory: pushedPRWT.path)

        // 6. Dirty worktree (1 staged + 1 modified + 1 untracked = 3 dirty files) -> `needsCommit`
        let dirtyWT = scanRoot.appendingPathComponent("wt-dirty", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", dirtyWT.path, "-b", "feat/dirty"], currentDirectory: mainRepo.path)
        try "STAGED = 1\n".write(to: dirtyWT.appendingPathComponent("staged.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "staged.py"], currentDirectory: dirtyWT.path)
        try "print('modified')\n".write(to: dirtyWT.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        try "UNTRACKED = 1\n".write(to: dirtyWT.appendingPathComponent("untracked.py"), atomically: true, encoding: .utf8)

        // 7. Missing on disk (prunable worktree)
        let missingWT = scanRoot.appendingPathComponent("wt-missing", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", missingWT.path, "-b", "feat/missing"], currentDirectory: mainRepo.path)
        try FileManager.default.removeItem(at: missingWT)

        // Also create 1 unpushed commit on `main` itself -> `main` should report `needsPush(count: 1, noUpstream: false)`!
        try "MAIN_NEXT = 1\n".write(to: mainRepo.appendingPathComponent("next.py"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "."], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "chore: local commit on main"], currentDirectory: mainRepo.path)

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)

        let mainItem = try #require(project.mainWorktree)
        #expect(mainItem.actionState == .needsPush(count: 1, noUpstream: false))

        let byPath = Dictionary(uniqueKeysWithValues: project.subWorktrees.map { ($0.path, $0) })

        let ancestorItem = try #require(byPath[ancestorWT.path])
        #expect(ancestorItem.actionState == .readyToRemove(reason: .mergedIntoBase, baseRef: "origin/main"))

        let squashItem = try #require(byPath[squashWT.path])
        #expect(!squashItem.isSafeToRemoveLinkedWorktree)
        #expect(squashItem.gitComparison?.isSquashMergedIntoBase == true)

        let syncedItem = try #require(byPath[syncedWT.path])
        #expect(syncedItem.actionState == .readyToRemove(reason: .syncedAtBase, baseRef: "origin/main"))

        let unpushedItem = try #require(byPath[unpushedWT.path])
        #expect(unpushedItem.actionState == .needsPush(count: 1, noUpstream: true))

        let pushedPRItem = try #require(byPath[pushedPRWT.path])
        #expect(pushedPRItem.actionState == .awaitingMerge(count: 1, baseRef: "origin/main"))

        let dirtyItem = try #require(byPath[dirtyWT.path])
        #expect(dirtyItem.workingTreeStatus.stagedCount == 1)
        #expect(dirtyItem.workingTreeStatus.modifiedCount == 1)
        #expect(dirtyItem.workingTreeStatus.untrackedCount == 1)
        #expect(dirtyItem.actionState == .needsCommit(dirtyCount: 3, hasConflicts: false, isLocked: false))

        let missingItem = try #require(byPath[missingWT.path])
        #expect(missingItem.actionState == .missingOnDisk)

        let summary = ScanSummary(projects: projects)
        #expect(summary.needsCommitCount == 1)
        #expect(summary.needsPushCount == 2) // `main` + `wt-unpushed`
        #expect(summary.removableWorktreeCount == 2) // Only ancestry-verified, present worktrees
        #expect(summary.actionableCount == 7) // `wt-pr-open` is awaiting merge, not requiring commit/push/remove
    }

    @Test("Deduplicates identical repos, linked worktrees, and symlinks across overlapping scan folders")
    func deduplicatesOverlappingScanFoldersAndSymlinks() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let reposDir = sandbox.appendingPathComponent("repos", isDirectory: true)
        let engineRepo = reposDir.appendingPathComponent("core-engine", isDirectory: true)
        try initGitRepo(at: engineRepo)

        let worktreesDir = sandbox.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        let linkedWT = worktreesDir.appendingPathComponent("core-engine-wt-1", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", linkedWT.path, "-b", "feat/one"], currentDirectory: engineRepo.path)

        let symlinkRepos = sandbox.appendingPathComponent("repos-symlink")
        try FileManager.default.createSymbolicLink(at: symlinkRepos, withDestinationURL: reposDir)

        let config = ScanConfiguration(
            folders: [
                ScanFolder(path: reposDir.path),
                ScanFolder(path: engineRepo.path),
                ScanFolder(path: worktreesDir.path),
                ScanFolder(path: symlinkRepos.path)
            ]
        )

        let projects = await ProjectScanner.scan(configuration: config)
        #expect(projects.count == 1)
        #expect(projects.first?.worktrees.count == 2)
    }

    @Test("Safely guards dirty worktrees and cleanly removes linked worktrees & branches")
    func safeGitWorktreeRemoval() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let mainRepo = sandbox.appendingPathComponent("service-repo", isDirectory: true)
        try initGitRepo(at: mainRepo, initialFile: "index.js", content: "console.log('ok');\n")

        let cleanWT = sandbox.appendingPathComponent("service-wt-clean", isDirectory: true)
        let dirtyWT = sandbox.appendingPathComponent("service-wt-dirty", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", cleanWT.path, "-b", "feat/clean"], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", dirtyWT.path, "-b", "feat/dirty"], currentDirectory: mainRepo.path)

        try "console.log('dirty');\n".write(to: dirtyWT.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let config = ScanConfiguration(folders: [ScanFolder(path: sandbox.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)

        let cleanItem = try #require(project.worktrees.first(where: { $0.path == cleanWT.path }))
        let dirtyItem = try #require(project.worktrees.first(where: { $0.path == dirtyWT.path }))

        let warnings = try GitWorktreeService.removeLinkedWorktree(
            cleanItem,
            in: project,
            options: WorktreeRemovalOptions(mode: .gitWorktreeRemove, forceIfDirtyOrLocked: false, deleteLocalBranch: true)
        )
        #expect(warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cleanWT.path))

        #expect(throws: GitWorktreeError.self) {
            _ = try GitWorktreeService.removeLinkedWorktree(
                dirtyItem,
                in: project,
                options: WorktreeRemovalOptions(mode: .gitWorktreeRemove, forceIfDirtyOrLocked: false)
            )
        }
        #expect(FileManager.default.fileExists(atPath: dirtyWT.path))

        _ = try GitWorktreeService.removeLinkedWorktree(
            dirtyItem,
            in: project,
            options: WorktreeRemovalOptions(mode: .gitWorktreeRemove, forceIfDirtyOrLocked: true, deleteLocalBranch: true, forceDeleteBranch: true)
        )
        #expect(!FileManager.default.fileExists(atPath: dirtyWT.path))
        #expect(GitWorktreeService.listWorktrees(for: mainRepo.path).count == 1)
    }

    @Test("Supports contextual Commit and Push actions, auto-setting upstream on new worktree branches")
    func commitAndPushWorktreeActions() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let originBare = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["init", "--bare", "-b", "main", originBare.path])

        let scanRoot = sandbox.appendingPathComponent("scan", isDirectory: true)
        let mainRepo = scanRoot.appendingPathComponent("app-repo", isDirectory: true)
        try initGitRepo(at: mainRepo, initialFile: "main.ts", content: "export const v = 1;\n")
        _ = try ShellRunner.run(executable: "git", arguments: ["remote", "add", "origin", originBare.path], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "main"], currentDirectory: mainRepo.path)

        let featWT = scanRoot.appendingPathComponent("app-wt-login", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", featWT.path, "-b", "feat/login"], currentDirectory: mainRepo.path)

        // 1. Add dirty untracked + modified files -> verify `needsCommit`
        try "export const v = 2;\n".write(to: featWT.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)
        try "export const login = true;\n".write(to: featWT.appendingPathComponent("login.ts"), atomically: true, encoding: .utf8)

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        var projects = await ProjectScanner.scan(configuration: config)
        var wt = try #require(projects.first?.subWorktrees.first)
        #expect(wt.actionState == .needsCommit(dirtyCount: 2, hasConflicts: false, isLocked: false))

        // 2. Commit without pushing -> transitions cleanly to `needsPush`!
        let commitRes = try GitWorktreeService.commitChanges(
            at: featWT.path,
            message: "feat: add login",
            pushAfterCommit: false
        )
        #expect(commitRes.commitHash != nil)
        #expect(commitRes.pushedDestination == nil)

        projects = await ProjectScanner.scan(configuration: config)
        wt = try #require(projects.first?.subWorktrees.first)
        #expect(wt.actionState == .needsPush(count: 1, noUpstream: true))

        // 3. Push -> auto-sets `origin/feat/login` upstream and transitions to `awaitingMerge`!
        let pushedDest = try GitWorktreeService.pushChanges(at: featWT.path)
        #expect(pushedDest == "origin/feat/login")

        projects = await ProjectScanner.scan(configuration: config)
        wt = try #require(projects.first?.subWorktrees.first)
        #expect(wt.actionState == .awaitingMerge(count: 1, baseRef: "origin/main"))
    }

    @Test("Scans 20+ repositories with linked worktrees concurrently without cooperative thread-pool deadlock")
    func highConcurrencyManyReposScan() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for idx in 0..<20 {
            let repoDir = sandbox.appendingPathComponent(String(format: "repo-%02d", idx), isDirectory: true)
            try initGitRepo(at: repoDir, initialFile: "README.md", content: "# Repo \(idx)\n")
            if idx % 4 == 0 {
                let wtDir = sandbox.appendingPathComponent(String(format: "repo-%02d-wt", idx), isDirectory: true)
                _ = try ShellRunner.run(
                    executable: "git",
                    arguments: ["worktree", "add", wtDir.path, "-b", "feat/item-\(idx)"],
                    currentDirectory: repoDir.path
                )
            }
        }

        let config = ScanConfiguration(folders: [ScanFolder(path: sandbox.path)])
        let projects = await ProjectScanner.scan(configuration: config)

        #expect(projects.count == 20)
        #expect(projects.allSatisfy { !$0.isInspecting })
        #expect(projects.flatMap(\.worktrees).count == 25)
        #expect(projects.flatMap(\.worktrees).allSatisfy { !$0.isInspecting })
    }

    @Test("Builds multi-worktree Git commit graph, detects orphaned vs reachable detached HEADs, and reports working-tree diffs")
    func multiWorktreeCommitGraphAndDetachedHeadSafety() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("scan", isDirectory: true)
        let mainRepo = scanRoot.appendingPathComponent("grove-core", isDirectory: true)
        try initGitRepo(at: mainRepo, initialFile: "app.swift", content: "let v = 1\n")

        // Second commit on main so `HEAD~1` is an ancestor along main
        try "let v = 2\n".write(to: mainRepo.appendingPathComponent("app.swift"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "app.swift"], currentDirectory: mainRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "main: bump to v2"], currentDirectory: mainRepo.path)

        // Worktree 1: Named feature branch with 1 new commit + dirty working tree
        let featWT = scanRoot.appendingPathComponent("grove-feat", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", featWT.path, "-b", "feat/graph"], currentDirectory: mainRepo.path)
        try "let graph = true\n".write(to: featWT.appendingPathComponent("graph.swift"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "graph.swift"], currentDirectory: featWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: add graph engine"], currentDirectory: featWT.path)
        // Make working tree dirty in `featWT`
        try "let graph = true\nlet lanes = 3\n".write(to: featWT.appendingPathComponent("graph.swift"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: featWT.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // Worktree 2: Reachable detached HEAD pinned on `main~1` (safe!)
        let safeDetachedWT = scanRoot.appendingPathComponent("grove-detached-safe", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", "--detach", safeDetachedWT.path, "HEAD~1"], currentDirectory: mainRepo.path)

        // Worktree 3: Orphaned detached HEAD with a commit NOT on any branch!
        let orphanDetachedWT = scanRoot.appendingPathComponent("grove-detached-orphan", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", "--detach", orphanDetachedWT.path, "HEAD"], currentDirectory: mainRepo.path)
        try "let experiment = 42\n".write(to: orphanDetachedWT.appendingPathComponent("exp.swift"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "exp.swift"], currentDirectory: orphanDetachedWT.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "exp: detached commit"], currentDirectory: orphanDetachedWT.path)

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)
        #expect(project.worktrees.count == 4)

        let featItem = try #require(project.worktrees.first(where: { $0.name == "grove-feat" }))
        let safeDetachedItem = try #require(project.worktrees.first(where: { $0.name == "grove-detached-safe" }))
        let orphanDetachedItem = try #require(project.worktrees.first(where: { $0.name == "grove-detached-orphan" }))

        // 1. Snapshot focused on `featItem`: includes all 4 worktree markers across the graph + 2 changed files
        let featSnap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: featItem)
        let allMarkers = featSnap.commits.flatMap(\.worktreeMarkers)
        #expect(allMarkers.count == 4)
        #expect(featSnap.changedFiles.count == 2)
        let hasGraphModified = featSnap.changedFiles.contains { item in
            item.path == "graph.swift" && item.status == .modified && item.additions == 1
        }
        let hasNotesUntracked = featSnap.changedFiles.contains { item in
            item.path == "notes.txt" && item.status == .untracked
        }
        #expect(hasGraphModified)
        #expect(hasNotesUntracked)

        // Base trunk (`main`) commits stay anchored on Lane 0 (`colorIndex == 0`)
        let mainMarkerRow = try #require(featSnap.commits.first(where: { $0.worktreeMarkers.contains(where: \.isPrimary) }))
        #expect(mainMarkerRow.lane == 0)
        #expect(mainMarkerRow.colorIndex == 0)

        // 2. Reachable detached HEAD is NOT flagged as orphaned
        let safeSnap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: safeDetachedItem)
        #expect(safeSnap.positionSummary.isOrphanedDetached == false)
        #expect(safeSnap.positionSummary.tone == .blue)

        // 3. Orphaned detached HEAD IS flagged as orphaned with Amber warning!
        let orphanSnap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: orphanDetachedItem)
        #expect(orphanSnap.positionSummary.isOrphanedDetached == true)
        #expect(orphanSnap.positionSummary.tone == .amber)
        let orphanID = orphanDetachedItem.id
        let orphanRow = try #require(orphanSnap.commits.first(where: { row in
            row.worktreeMarkers.contains(where: { $0.worktreeID == orphanID })
        }))
        #expect(orphanRow.isOrphanedDetached == true)
    }

    @Test("Fetches from origin and classifies Merged, PR Squash-Merged (origin gone), Active PR, and Local Experiment branches")
    func classifiesLocalBranchesAndFetchesOrigin() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 1. Bare `origin` remote + primary local clone + separate collaborator clone (simulating GitHub PR merges!)
        let bareOrigin = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["init", "--bare", "-b", "main", bareOrigin.path])

        let scanRoot = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let localRepo = scanRoot.appendingPathComponent("grove-branches", isDirectory: true)
        try initGitRepo(at: localRepo, initialFile: "README.md", content: "# Grove\n")
        _ = try ShellRunner.run(executable: "git", arguments: ["remote", "add", "origin", bareOrigin.path], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "main"], currentDirectory: localRepo.path)

        // Branch A: Ancestor-merged branch (`feat/merged`)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "feat/merged"], currentDirectory: localRepo.path)
        try "merged\n".write(to: localRepo.appendingPathComponent("merged.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "merged.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: merged"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["merge", "--no-ff", "feat/merged", "-m", "Merge feat/merged"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "origin", "main"], currentDirectory: localRepo.path)

        // Branch B: Multi-commit PR branch (`pr/squash`) pushed to origin, then Squash-Merged on "GitHub" & remote branch deleted!
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "pr/squash"], currentDirectory: localRepo.path)
        try "part 1\n".write(to: localRepo.appendingPathComponent("squash.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "squash.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "pr commit 1"], currentDirectory: localRepo.path)
        try "part 1\npart 2\n".write(to: localRepo.appendingPathComponent("squash.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "squash.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "pr commit 2"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "pr/squash"], currentDirectory: localRepo.path)

        // Branch C: Active tracked PR branch (`pr/open`) with 1 unmerged commit
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "pr/open"], currentDirectory: localRepo.path)
        try "open pr\n".write(to: localRepo.appendingPathComponent("open.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "open.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: open pr"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "pr/open"], currentDirectory: localRepo.path)

        // Branch D: Pure local experiment (`exp/local-idea`), never pushed!
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "exp/local-idea"], currentDirectory: localRepo.path)
        try "idea\n".write(to: localRepo.appendingPathComponent("idea.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "idea.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "wip: local idea"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: localRepo.path)

        // Simulate GitHub Squash-Merge of `pr/squash` into `origin/main` + remote branch deletion
        let remoteClone = sandbox.appendingPathComponent("github-runner", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["clone", bareOrigin.path, remoteClone.path])
        _ = try ShellRunner.run(executable: "git", arguments: ["config", "user.email", "bot@github.com"], currentDirectory: remoteClone.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["config", "user.name", "GitHub"], currentDirectory: remoteClone.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["merge", "--squash", "origin/pr/squash"], currentDirectory: remoteClone.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "pr: squash merge (#42)"], currentDirectory: remoteClone.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "origin", "main"], currentDirectory: remoteClone.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "origin", "--delete", "pr/squash"], currentDirectory: remoteClone.path)

        // 2. Run Grove's `fetchFromRemote` (`git fetch --prune origin`) on `localRepo` (note: local `main` hasn't even pulled yet!)
        let fetchedRemote = try GitWorktreeService.fetchFromRemote(at: localRepo.path)
        #expect(fetchedRemote == "origin")

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)
        let snap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree)

        #expect(snap.hasRemote == true)

        let byName = Dictionary(uniqueKeysWithValues: snap.localBranches.map { ($0.name, $0) })
        let mainBranch = try #require(byName["main"])
        let mergedBranch = try #require(byName["feat/merged"])
        let squashBranch = try #require(byName["pr/squash"])
        let openPRBranch = try #require(byName["pr/open"])
        let expBranch = try #require(byName["exp/local-idea"])

        #expect(mainBranch.relationship == .baseTrunk)
        #expect(mainBranch.checkedOutWorktreeID != nil)
        #expect(mainBranch.behindUpstream == 1)

        #expect(mergedBranch.relationship == .mergedIntoBase(viaSquashOrRebase: false, upstreamGone: false))
        #expect(mergedBranch.isSafeToRemove == true)

        #expect(squashBranch.relationship == .mergedIntoBase(viaSquashOrRebase: true, upstreamGone: true))
        #expect(squashBranch.isSafeToRemove == false)
        #expect(squashBranch.requiresForceFlagWhenDeleting == true)

        #expect(openPRBranch.relationship == .activePROrTracked)
        #expect(openPRBranch.aheadOfBase == 1)
        #expect(openPRBranch.behindBase == 1)
        #expect(openPRBranch.isSafeToRemove == false)

        #expect(expBranch.relationship == .localExperiment)
        #expect(expBranch.aheadOfBase == 1)
        #expect(expBranch.behindBase == 1)
        #expect(expBranch.isSafeToRemove == false)

        // 3. Only ancestry-merged branches enter automatic cleanup.
        for removable in snap.removableBranches {
            try GitWorktreeService.deleteLocalBranchNamed(
                removable.name,
                in: localRepo.path,
                force: removable.requiresForceFlagWhenDeleting
            )
        }

        let afterSnap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree)
        #expect(afterSnap.removableBranches.isEmpty)
        #expect(afterSnap.localBranches.count == 4) // Squash-equivalent history is retained for review.
    }

    @Test("Detects low-risk force-delete requirement when branch is merged into HEAD/main yet unpushed to its remote tracking ref")
    func detectsForceDeleteReasonForMergedBranchUnpushedToUpstream() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let bareOrigin = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["init", "--bare", "-b", "main", bareOrigin.path])

        let scanRoot = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let localRepo = scanRoot.appendingPathComponent("realtime-repo", isDirectory: true)
        try initGitRepo(at: localRepo, initialFile: "README.md", content: "# Realtime\n")
        _ = try ShellRunner.run(executable: "git", arguments: ["remote", "add", "origin", bareOrigin.path], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "main"], currentDirectory: localRepo.path)

        // Create `feat/realtime-quality`, push 1st commit to `origin/feat/realtime-quality`,
        // then add a 2nd local commit (NOT pushed to `origin/feat/realtime-quality`), and merge into `main`!
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "feat/realtime-quality"], currentDirectory: localRepo.path)
        try "step 1\n".write(to: localRepo.appendingPathComponent("quality.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "quality.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: quality 1"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["push", "-u", "origin", "feat/realtime-quality"], currentDirectory: localRepo.path)

        try "step 1\nstep 2\n".write(to: localRepo.appendingPathComponent("quality.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "quality.txt"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "feat: quality 2"], currentDirectory: localRepo.path)

        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: localRepo.path)
        _ = try ShellRunner.run(executable: "git", arguments: ["merge", "--no-ff", "feat/realtime-quality", "-m", "Merge feat/realtime-quality"], currentDirectory: localRepo.path)

        try GitWorktreeService.setIntegrationTarget("main", in: localRepo.path)
        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)
        let snap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree)

        let branch = try #require(snap.localBranches.first(where: { $0.name == "feat/realtime-quality" }))
        #expect(branch.isSafeToRemove == true)
        #expect(branch.aheadOfUpstream == 1)
        #expect(
            branch.forceDeleteReason == .mergedToMainButUnpushedToUpstream(
                base: "main",
                upstream: "origin/feat/realtime-quality",
                aheadOfUpstream: 1
            )
        )
        #expect(branch.forceDeleteReason?.riskLevel == .low)

        // Verify `force: false` (`git branch -d`) throws typed `.branchRequiresForceDelete` instead of generic failure
        var caughtRequiresForce = false
        do {
            try GitWorktreeService.deleteLocalBranchNamed("feat/realtime-quality", in: localRepo.path, force: false)
        } catch let GitWorktreeError.branchRequiresForceDelete(branchName, stderr) {
            caughtRequiresForce = true
            #expect(branchName == "feat/realtime-quality")
            #expect(stderr.localizedCaseInsensitiveContains("not deleting branch") || stderr.localizedCaseInsensitiveContains("not fully merged"))
        }
        #expect(caughtRequiresForce == true)

        // Confirming `force: true` (`git branch -D`) cleanly deletes it
        try GitWorktreeService.deleteLocalBranchNamed("feat/realtime-quality", in: localRepo.path, force: true)
        let afterSnap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree)
        #expect(afterSnap.localBranches.contains(where: { $0.name == "feat/realtime-quality" }) == false)
    }

    @Test("Collapses linear main trunk commits while keeping fork points, standalone branches, and idle tips visible")
    func collapsesLinearMainTrunkWhilePreservingForksAndIdleTips() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let repo = scanRoot.appendingPathComponent("topology-repo", isDirectory: true)
        try initGitRepo(at: repo, initialFile: "README.md", content: "# Topology\n")

        // Create an idle feature branch backdated 30 days ago!
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "exp/idle-branch"], currentDirectory: repo.path)
        try "idle\n".write(to: repo.appendingPathComponent("idle.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "idle.txt"], currentDirectory: repo.path)
        let oldISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        _ = try ShellRunner.run(
            executable: "env",
            arguments: [
                "GIT_COMMITTER_DATE=\(oldISO)",
                "GIT_AUTHOR_DATE=\(oldISO)",
                "git", "commit", "-m", "wip: 30d old experiment"
            ],
            currentDirectory: repo.path
        )

        // Advance `main` with 6 plain linear commits (no branches or worktrees on the middle commits)
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: repo.path)
        for idx in 1...6 {
            try "line \(idx)\n".write(to: repo.appendingPathComponent("main_\(idx).txt"), atomically: true, encoding: .utf8)
            _ = try ShellRunner.run(executable: "git", arguments: ["add", "main_\(idx).txt"], currentDirectory: repo.path)
            _ = try ShellRunner.run(executable: "git", arguments: ["commit", "-m", "main linear commit \(idx)"], currentDirectory: repo.path)
        }

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)
        let snap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree)

        // 1. Idle branch tip should be marked `isIdleTip` (`idleDays >= 14`) with standalone `branchMarkers`
        let idleRow = try #require(snap.commits.first(where: { $0.subject == "wip: 30d old experiment" }))
        #expect(idleRow.isIdleTip == true)
        #expect(idleRow.idleDays >= 29)
        #expect(idleRow.standaloneBranchMarkers.map(\.name) == ["exp/idle-branch"])

        // 2. Collapsed display items should compress the middle linear `main` commits into `.collapsedTrunk`
        let collapsedItems = GitHistoryService.buildDisplayItems(commits: snap.commits, collapseLinearTrunk: true)
        let collapsedSegments = collapsedItems.compactMap { item -> (String, Int)? in
            if case let .collapsedTrunk(segID, hidden, _, _, _) = item {
                return (segID, hidden.count)
            }
            return nil
        }
        #expect(!collapsedSegments.isEmpty)
        #expect(collapsedItems.count < snap.commits.count)

        // 3. Expanding that segment ID restores full commit visibility
        let expandedIDs = Set(collapsedSegments.map(\.0))
        let expandedItems = GitHistoryService.buildDisplayItems(
            commits: snap.commits,
            expandedSegmentIDs: expandedIDs,
            collapseLinearTrunk: true
        )
        #expect(expandedItems.count == snap.commits.count)
    }

    @Test("Single-page snapshot (maxCommits: 0) tracks idle commits across both branches and detached-HEAD worktrees")
    func singlePageSnapshotTracksIdleBranchAndDetachedWorktreeCommits() async throws {
        let sandbox = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let repo = scanRoot.appendingPathComponent("hygiene-repo", isDirectory: true)
        try initGitRepo(at: repo, initialFile: "README.md", content: "# Hygiene\n")

        // 1. Standalone idle branch backdated 22 days ago
        let old22d = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-22 * 86_400))
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "-b", "feat/idle-branch"], currentDirectory: repo.path)
        try "b\n".write(to: repo.appendingPathComponent("branch.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "branch.txt"], currentDirectory: repo.path)
        _ = try ShellRunner.run(
            executable: "env",
            arguments: ["GIT_COMMITTER_DATE=\(old22d)", "GIT_AUTHOR_DATE=\(old22d)", "git", "commit", "-m", "feat: 22d branch"],
            currentDirectory: repo.path
        )
        _ = try ShellRunner.run(executable: "git", arguments: ["checkout", "main"], currentDirectory: repo.path)

        // 2. Linked worktree on detached HEAD with an orphaned commit backdated 19 days ago
        let old19d = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-19 * 86_400))
        let detachedWT = scanRoot.appendingPathComponent("hygiene-detached", isDirectory: true)
        _ = try ShellRunner.run(executable: "git", arguments: ["worktree", "add", "--detach", detachedWT.path, "HEAD"], currentDirectory: repo.path)
        try "d\n".write(to: detachedWT.appendingPathComponent("detached.txt"), atomically: true, encoding: .utf8)
        _ = try ShellRunner.run(executable: "git", arguments: ["add", "detached.txt"], currentDirectory: detachedWT.path)
        _ = try ShellRunner.run(
            executable: "env",
            arguments: ["GIT_COMMITTER_DATE=\(old19d)", "GIT_AUTHOR_DATE=\(old19d)", "git", "commit", "-m", "exp: 19d detached"],
            currentDirectory: detachedWT.path
        )

        let config = ScanConfiguration(folders: [ScanFolder(path: scanRoot.path)])
        let projects = await ProjectScanner.scan(configuration: config)
        let project = try #require(projects.first)
        let detachedItem = try #require(project.worktrees.first(where: { $0.name == "hygiene-detached" }))

        let snap = GitHistoryService.loadSnapshot(for: project, selectedWorktree: project.mainWorktree, maxCommits: 0)

        #expect(snap.commits.isEmpty)
        #expect(snap.orphanedDetachedWorktreeIDs.contains(detachedItem.id))

        let detachedCommit = try #require(snap.headCommitsByWorktreeID[detachedItem.id])
        #expect(detachedCommit.subject == "exp: 19d detached")
        let detachedCommitDate = try #require(detachedCommit.committedAt)
        let detachedIdleDays = Int(Date().timeIntervalSince(detachedCommitDate) / 86_400)
        #expect(detachedIdleDays >= 18)

        let idleBranch = try #require(snap.localBranches.first(where: { $0.name == "feat/idle-branch" }))
        #expect(idleBranch.idleDays >= 21)
    }

    @Test("UpdateService compares semantic versions, parses GitHub release assets, and verifies SHA256SUMS")
    func updateServiceParsingAndVersionComparison() throws {
        #expect(UpdateService.isNewerVersion("v0.2.0", than: "0.1.0") == true)
        #expect(UpdateService.isNewerVersion("0.1.0", than: "v0.1.0") == false)
        #expect(UpdateService.isNewerVersion("0.1.0", than: "0.1.0-beta.1") == true)
        #expect(UpdateService.isNewerVersion("0.0.9", than: "0.1.0") == false)

        let releaseJSON = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/yeoleobun/Grove/releases/tag/v0.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Grove-macos-arm64.zip",
              "browser_download_url": "https://github.com/yeoleobun/Grove/releases/download/v0.2.0/Grove-macos-arm64.zip"
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/yeoleobun/Grove/releases/download/v0.2.0/SHA256SUMS.txt"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try #require(try UpdateService.parseLatestReleaseData(releaseJSON, currentVersion: "0.1.0"))
        #expect(parsed.version == "0.2.0")
        #expect(parsed.sha256SumsURL != nil)
        #expect(try UpdateService.parseLatestReleaseData(releaseJSON, currentVersion: "0.2.0") == nil)

        let sums = """
        0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  Grove-macos-arm64.zip
        fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  Grove-macos-arm64.dmg
        """
        #expect(UpdateService.extractExpectedSHA256(from: sums) == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }
}
