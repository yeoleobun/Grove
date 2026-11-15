import GroveCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.configuration.folders.isEmpty {
                    Text("No scan folders configured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.configuration.folders) { folder in
                        LabeledContent {
                            HStack(spacing: 10) {
                                Button {
                                    viewModel.revealInFinder(path: folder.path)
                                } label: {
                                    Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal in Finder")

                                Toggle("Enabled", isOn: Binding(
                                    get: { folder.isEnabled },
                                    set: { viewModel.setFolderEnabled(folder.id, isEnabled: $0) }
                                ))
                                .labelsHidden()

                                Button(role: .destructive) {
                                    viewModel.removeFolder(folder)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove Folder")
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.displayName)
                                    Text(folder.displayPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: folder.exists ? "folder.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(folder.exists ? Color.accentColor : Color.orange)
                            }
                        }
                    }
                }

                Button {
                    viewModel.promptAddFolder()
                } label: {
                    Label("Add Scan Folder…", systemImage: "folder.badge.plus")
                }
            } header: {
                Text("Search Folders (1 Level Deep)")
            } footer: {
                Text("Each enabled folder is checked 1 level deep (`<folder>/<repo>/.git`), and all linked Git worktrees are discovered automatically and deduplicated across folders.")
            }

            Section {
                Picker(
                    "Code Editor / IDE",
                    selection: Binding(
                        get: { viewModel.configuration.preferredEditor },
                        set: { viewModel.updatePreferredEditor($0) }
                    )
                ) {
                    ForEach(PreferredCodeEditor.allCases) { editor in
                        Text(editor.displayName).tag(editor)
                    }
                }

                if viewModel.configuration.preferredEditor == .custom {
                    LabeledContent("Selected App") {
                        HStack(spacing: 8) {
                            Text(viewModel.configuration.customEditorAppPath ?? "None")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                viewModel.chooseCustomEditorApp()
                            }
                        }
                    }
                }

                Picker(
                    "Shell / Terminal",
                    selection: Binding(
                        get: { viewModel.configuration.preferredTerminal },
                        set: { viewModel.updatePreferredTerminal($0) }
                    )
                ) {
                    ForEach(PreferredTerminalApp.allCases) { terminal in
                        Text(terminal.displayName).tag(terminal)
                    }
                }

                if viewModel.configuration.preferredTerminal == .custom {
                    LabeledContent("Selected Shell") {
                        HStack(spacing: 8) {
                            Text(viewModel.configuration.customTerminalAppPath ?? "None")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                viewModel.chooseCustomTerminalApp()
                            }
                        }
                    }
                }
            } header: {
                Text("Code Editor & Shell")
            } footer: {
                Text("Defaults to VS Code and macOS Terminal. Switch anytime or pick any custom `.app` in `/Applications`.")
            }

            Section("Worktrees") {
                Toggle(
                    "Include linked Git worktrees located outside scan folders",
                    isOn: Binding(
                        get: { viewModel.configuration.includeExternalWorktrees },
                        set: { viewModel.updateIncludeExternalWorktrees($0) }
                    )
                )
            }

            Section("Updates") {
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        switch viewModel.updateState {
                        case .idle:
                            Text("v\(UpdateService.currentAppVersion)")
                                .foregroundStyle(.secondary)
                            Button("Check for Updates") {
                                viewModel.checkForUpdates(manual: true)
                            }

                        case .checking:
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking GitHub Releases…")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                        case let .upToDate(ver):
                            Text("v\(ver) (Up to date)")
                                .foregroundStyle(.secondary)
                            Button("Check Again") {
                                viewModel.checkForUpdates(manual: true)
                            }

                        case let .updateAvailable(release):
                            Text("v\(UpdateService.currentAppVersion) → v\(release.version)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(RowDismissButton.groveEmerald)
                            Button("Update to v\(release.version)") {
                                viewModel.installAvailableUpdate(release)
                            }
                            .buttonStyle(.glassProminent)

                        case let .updating(ver):
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating to v\(ver)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                        case let .failed(msg):
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                            Button("Retry") {
                                viewModel.checkForUpdates(manual: true)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}
