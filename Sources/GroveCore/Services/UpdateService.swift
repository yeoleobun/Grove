import CryptoKit
import Darwin
import Foundation

public struct ReleaseAssetInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let zipDownloadURL: URL
    public let sha256SumsURL: URL?
    public let releasePageURL: URL

    public init(
        version: String,
        tagName: String,
        zipDownloadURL: URL,
        sha256SumsURL: URL? = nil,
        releasePageURL: URL
    ) {
        self.version = version
        self.tagName = tagName
        self.zipDownloadURL = zipDownloadURL
        self.sha256SumsURL = sha256SumsURL
        self.releasePageURL = releasePageURL
    }
}

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(ReleaseAssetInfo)
    case updating(version: String)
    case failed(message: String)
}

public enum UpdateServiceError: LocalizedError {
    case badHTTPStatus(Int)
    case invalidAssetChecksum
    case missingAppBundleInArchive
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .badHTTPStatus(code):
            return "GitHub Releases returned HTTP \(code)."
        case .invalidAssetChecksum:
            return "Downloaded update failed SHA-256 integrity verification."
        case .missingAppBundleInArchive:
            return "Update archive did not contain a valid Grove.app bundle."
        case let .stagingFailed(msg):
            return msg
        }
    }
}

public enum UpdateService {
    public static let githubLatestReleaseAPI = URL(
        string: "https://api.github.com/repos/yeoleobun/Grove/releases/latest"
    )!
    public static let assetZipName = "Grove-macos-arm64.zip"
    public static let sha256SumsName = "SHA256SUMS.txt"

    public static var currentAppVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !ver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeVersionString(ver)
        }
        return "0.1.0"
    }

    // MARK: - GitHub Releases Wire Models

    private struct GitHubReleaseWire: Decodable {
        let tagName: String
        let htmlUrl: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GitHubAssetWire]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    private struct GitHubAssetWire: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    // MARK: - Semantic Version Comparison & Release Parsing

    public static func normalizeVersionString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIdx = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIdx])
        }
        return trimmed
    }

    /// Returns `true` strictly when `candidate` is a newer semantic version than `current`.
    public static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let cleanCandidate = normalizeVersionString(candidate)
        let cleanCurrent = normalizeVersionString(current)
        if cleanCandidate == cleanCurrent { return false }

        let candParts = cleanCandidate.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let currParts = cleanCurrent.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

        let candNums = candParts[0].split(separator: ".").map { Int($0) ?? 0 }
        let currNums = currParts[0].split(separator: ".").map { Int($0) ?? 0 }
        let count = max(candNums.count, currNums.count)

        for i in 0..<count {
            let a = i < candNums.count ? candNums[i] : 0
            let b = i < currNums.count ? currNums[i] : 0
            if a != b {
                return a > b
            }
        }

        // Same numeric core: stable release is newer than a pre-release (`0.2.0` > `0.2.0-beta.1`)
        let candPre = candParts.count > 1 ? String(candParts[1]) : nil
        let currPre = currParts.count > 1 ? String(currParts[1]) : nil
        if candPre == nil && currPre != nil {
            return true
        }
        return false
    }

    /// Parses GitHub `/releases/latest` JSON and returns `ReleaseAssetInfo` if a newer arm64 release is available.
    public static func parseLatestReleaseData(
        _ data: Data,
        currentVersion: String
    ) throws -> ReleaseAssetInfo? {
        let release = try JSONDecoder().decode(GitHubReleaseWire.self, from: data)
        if release.draft == true || release.prerelease == true {
            return nil
        }

        let remoteVersion = normalizeVersionString(release.tagName)
        guard isNewerVersion(remoteVersion, than: currentVersion) else {
            return nil
        }

        guard let zipAsset = release.assets.first(where: { $0.name == assetZipName }),
              let zipURL = URL(string: zipAsset.browserDownloadUrl),
              let pageURL = URL(string: release.htmlUrl) else {
            return nil
        }

        let shaURL = release.assets
            .first(where: { $0.name == sha256SumsName })
            .flatMap { URL(string: $0.browserDownloadUrl) }

        return ReleaseAssetInfo(
            version: remoteVersion,
            tagName: release.tagName,
            zipDownloadURL: zipURL,
            sha256SumsURL: shaURL,
            releasePageURL: pageURL
        )
    }

    public static func extractExpectedSHA256(from sumsText: String, assetName: String = assetZipName) -> String? {
        for rawLine in sumsText.components(separatedBy: .newlines) {
            let parts = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2 {
                let hash = String(parts[0]).lowercased()
                let file = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                if file == assetName, hash.count == 64 {
                    return hash
                }
            }
        }
        return nil
    }

    // MARK: - Live Check & Self-Update Installer

    public static func fetchLatestUpdate(currentVersion: String = currentAppVersion) async throws -> ReleaseAssetInfo? {
        var req = URLRequest(url: githubLatestReleaseAPI)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Grove/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            if !(200...299).contains(http.statusCode) {
                throw UpdateServiceError.badHTTPStatus(http.statusCode)
            }
        }
        return try parseLatestReleaseData(data, currentVersion: currentVersion)
    }

    /// Downloads, SHA-256 verifies, unquarantines, swaps `Grove.app`, and spawns a detached relauncher.
    /// Caller should terminate the current app immediately after this method returns.
    public static func stageAndLaunchReplacement(for release: ReleaseAssetInfo) async throws {
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory.appendingPathComponent("grove-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let zipPath = stageDir.appendingPathComponent(assetZipName)

        // 1. Download release ZIP
        var zipReq = URLRequest(url: release.zipDownloadURL)
        zipReq.cachePolicy = .reloadIgnoringLocalCacheData
        zipReq.timeoutInterval = 60
        let (tempURL, response) = try await URLSession.shared.download(for: zipReq)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fm.removeItem(at: stageDir)
            throw UpdateServiceError.badHTTPStatus(http.statusCode)
        }
        if fm.fileExists(atPath: zipPath.path) {
            try fm.removeItem(at: zipPath)
        }
        try fm.moveItem(at: tempURL, to: zipPath)

        // 2. Verify SHA-256 against SHA256SUMS.txt when published on the release
        if let sumsURL = release.sha256SumsURL {
            var sumsReq = URLRequest(url: sumsURL)
            sumsReq.cachePolicy = .reloadIgnoringLocalCacheData
            sumsReq.timeoutInterval = 15
            if let (sumsData, sumsResp) = try? await URLSession.shared.data(for: sumsReq),
               (sumsResp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
               let sumsText = String(data: sumsData, encoding: .utf8),
               let expectedHash = extractExpectedSHA256(from: sumsText) {
                let archiveData = try Data(contentsOf: zipPath, options: .mappedIfSafe)
                let digest = SHA256.hash(data: archiveData)
                let actualHash = digest.map { String(format: "%02x", $0) }.joined()
                guard actualHash == expectedHash else {
                    try? fm.removeItem(at: stageDir)
                    throw UpdateServiceError.invalidAssetChecksum
                }
            }
        }

        // 3. Unpack ZIP with ditto and clear quarantine before moving into place
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipPath.path, stageDir.path])
        let stagedAppURL = stageDir.appendingPathComponent("Grove.app", isDirectory: true)
        let stagedBinaryURL = stagedAppURL.appendingPathComponent("Contents/MacOS/Grove")
        guard fm.isExecutableFile(atPath: stagedBinaryURL.path) else {
            try? fm.removeItem(at: stageDir)
            throw UpdateServiceError.missingAppBundleInArchive
        }
        _ = try? runProcess("/usr/bin/xattr", arguments: ["-cr", stagedAppURL.path])

        // 4. Determine destination .app path (replace running bundle if inside a writable folder, else /Applications/Grove.app)
        let bundleURL = Bundle.main.bundleURL
        let destinationAppPath: String
        if bundleURL.pathExtension == "app",
           fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            destinationAppPath = bundleURL.path
        } else {
            destinationAppPath = "/Applications/Grove.app"
        }

        // 5. Spawn detached background swap-and-relaunch script
        let pid = ProcessInfo.processInfo.processIdentifier
        let swapScript = """
        for _ in {1..50}; do
          kill -0 "$GROVE_OLD_PID" 2>/dev/null || break
          sleep 0.1
        done
        BACKUP="${GROVE_DEST_APP}.bak.$$"
        if [ -d "$GROVE_DEST_APP" ]; then
          mv "$GROVE_DEST_APP" "$BACKUP" || exit 1
        fi
        if mv "$GROVE_STAGED_APP" "$GROVE_DEST_APP"; then
          rm -rf "$BACKUP"
          /usr/bin/xattr -cr "$GROVE_DEST_APP" 2>/dev/null || true
          /usr/bin/open "$GROVE_DEST_APP"
        else
          [ -d "$BACKUP" ] && mv "$BACKUP" "$GROVE_DEST_APP"
        fi
        rm -rf "$GROVE_STAGE_DIR"
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = ["-c", swapScript]
        var env = ProcessInfo.processInfo.environment
        env["GROVE_OLD_PID"] = String(pid)
        env["GROVE_STAGED_APP"] = stagedAppURL.path
        env["GROVE_DEST_APP"] = destinationAppPath
        env["GROVE_STAGE_DIR"] = stageDir.path
        helper.environment = env
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice

        do {
            try helper.run()
        } catch {
            try? fm.removeItem(at: stageDir)
            throw UpdateServiceError.stagingFailed("Failed to launch updater helper: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, arguments: [String]) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw UpdateServiceError.stagingFailed("\(launchPath) exited with code \(proc.terminationStatus).")
        }
        return proc.terminationStatus
    }
}
