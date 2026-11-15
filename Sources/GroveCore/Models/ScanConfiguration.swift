import Foundation

public struct ScanFolder: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var isEnabled: Bool
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        path: String,
        isEnabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.path = Self.normalizePath(path)
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

public enum PreferredCodeEditor: String, Codable, CaseIterable, Identifiable, Sendable {
    case vscode
    case cursor
    case zed
    case windsurf
    case antigravity
    case xcode
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .windsurf: return "Windsurf"
        case .antigravity: return "Antigravity"
        case .xcode: return "Xcode"
        case .custom: return "Custom App…"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .zed: return ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .windsurf: return ["com.exafunction.windsurf"]
        case .antigravity: return ["com.google.antigravity"]
        case .xcode: return ["com.apple.dt.Xcode"]
        case .custom: return []
        }
    }

    public var fallbackAppPaths: [String] {
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        switch self {
        case .vscode:
            return ["/Applications/Visual Studio Code.app", "\(homeApps)/Visual Studio Code.app"]
        case .cursor:
            return ["/Applications/Cursor.app", "\(homeApps)/Cursor.app"]
        case .zed:
            return ["/Applications/Zed.app", "\(homeApps)/Zed.app"]
        case .windsurf:
            return ["/Applications/Windsurf.app", "\(homeApps)/Windsurf.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app", "\(homeApps)/Antigravity.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .custom:
            return []
        }
    }

    public var cliCommand: String? {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .zed: return "zed"
        case .windsurf: return "windsurf"
        case .antigravity: return "agy"
        case .xcode, .custom: return nil
        }
    }
}

public enum PreferredTerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal
    case iterm
    case ghostty
    case warp
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .custom: return "Custom App…"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .terminal: return ["com.apple.Terminal"]
        case .iterm: return ["com.googlecode.iterm2"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .warp: return ["dev.warp.Warp-Stable"]
        case .custom: return []
        }
    }

    public var fallbackAppPaths: [String] {
        switch self {
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .iterm:
            return ["/Applications/iTerm.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        case .custom:
            return []
        }
    }
}

public struct ScanConfiguration: Codable, Equatable, Sendable {
    public var folders: [ScanFolder]
    public var includeExternalWorktrees: Bool
    public var ignoredDirectoryNames: [String]
    public var displayCountInMenuBar: Bool
    public var preferredEditor: PreferredCodeEditor
    public var customEditorAppPath: String?
    public var preferredTerminal: PreferredTerminalApp
    public var customTerminalAppPath: String?

    public static let defaultIgnoredDirectories: [String] = [
        ".git",
        "vendor",
        "node_modules",
        ".Trash",
        "Library",
        ".venv",
        "venv",
        "Pods",
        "DerivedData",
        ".build",
        "target"
    ]

    public init(
        folders: [ScanFolder] = [],
        includeExternalWorktrees: Bool = true,
        ignoredDirectoryNames: [String] = Self.defaultIgnoredDirectories,
        displayCountInMenuBar: Bool = true,
        preferredEditor: PreferredCodeEditor = .vscode,
        customEditorAppPath: String? = nil,
        preferredTerminal: PreferredTerminalApp = .terminal,
        customTerminalAppPath: String? = nil
    ) {
        self.folders = folders
        self.includeExternalWorktrees = includeExternalWorktrees
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.displayCountInMenuBar = displayCountInMenuBar
        self.preferredEditor = preferredEditor
        self.customEditorAppPath = customEditorAppPath
        self.preferredTerminal = preferredTerminal
        self.customTerminalAppPath = customTerminalAppPath
    }

    private enum CodingKeys: String, CodingKey {
        case folders
        case includeExternalWorktrees
        case ignoredDirectoryNames
        case displayCountInMenuBar
        case preferredEditor
        case customEditorAppPath
        case preferredTerminal
        case customTerminalAppPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.folders = try container.decodeIfPresent([ScanFolder].self, forKey: .folders) ?? []
        self.includeExternalWorktrees = try container.decodeIfPresent(Bool.self, forKey: .includeExternalWorktrees) ?? true
        self.ignoredDirectoryNames = try container.decodeIfPresent([String].self, forKey: .ignoredDirectoryNames) ?? Self.defaultIgnoredDirectories
        self.displayCountInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .displayCountInMenuBar) ?? true
        self.preferredEditor = try container.decodeIfPresent(PreferredCodeEditor.self, forKey: .preferredEditor) ?? .vscode
        self.customEditorAppPath = try container.decodeIfPresent(String.self, forKey: .customEditorAppPath)
        self.preferredTerminal = try container.decodeIfPresent(PreferredTerminalApp.self, forKey: .preferredTerminal) ?? .terminal
        self.customTerminalAppPath = try container.decodeIfPresent(String.self, forKey: .customTerminalAppPath)
    }

    public var enabledFolderPaths: [String] {
        folders.filter(\.isEnabled).map(\.path)
    }

    public var resolvedEditorLabel: String {
        if preferredEditor == .custom, let path = customEditorAppPath, !path.isEmpty {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return preferredEditor.displayName
    }

    public var resolvedTerminalLabel: String {
        if preferredTerminal == .custom, let path = customTerminalAppPath, !path.isEmpty {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return preferredTerminal.displayName
    }
}

public final class ConfigurationStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let overridePath = ProcessInfo.processInfo.environment["GROVE_CONFIG_PATH"],
                  !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.fileURL = URL(fileURLWithPath: ScanFolder.normalizePath(overridePath))
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Grove", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("config.json")
        }
    }

    public func load() -> ScanConfiguration {
        if let data = try? Data(contentsOf: fileURL),
           let config = try? JSONDecoder().decode(ScanConfiguration.self, from: data) {
            return config
        }
        return ScanConfiguration()
    }

    public func save(_ config: ScanConfiguration) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
