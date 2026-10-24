// Editor sheet for adding a `launchApp` keybind. Presented from the
// Keys tab "＋ Add" menu ("App launcher…").

import SwiftUI
import Carbon

struct AppLauncherEditorSheet: View {
    /// the saved list, to refuse a chord another bind already holds
    var otherBinds: [Keybind] = []
    let onSave: (Keybind) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAppName = ""
    @State private var selectedBundleID = ""
    @State private var recordedKeyCode: UInt16 = 0
    @State private var useHypr = true
    @State private var useShift = false
    @State private var useControl = false
    @State private var useOption = false
    @State private var useCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.lg) {
            Text("Add App Launcher")
                .font(.hyprTitle)

            // app picker
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Application")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                HStack(spacing: HyprSpacing.md) {
                    Group {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selectedBundleID),
                           !selectedAppName.isEmpty {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                        } else {
                            RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                                .fill(Color.hyprSurfaceElevated)
                                .overlay(
                                    Image(systemName: "app")
                                        .foregroundStyle(Color.hyprTextTertiary)
                                )
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        if selectedAppName.isEmpty {
                            Text("No app selected")
                                .font(.hyprBody)
                                .foregroundStyle(Color.hyprTextSecondary)
                        } else {
                            Text(selectedAppName).font(.hyprBody)
                            Text(selectedBundleID)
                                .font(.hyprMonoXs)
                                .foregroundStyle(Color.hyprTextTertiary)
                        }
                    }

                    Spacer()
                    Button("Choose…") { pickApp() }
                }
                .padding(HyprSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .fill(Color.hyprSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                        .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
                )
            }

            // shortcut recorder
            VStack(alignment: .leading, spacing: HyprSpacing.sm) {
                Text("Shortcut")
                    .font(.hyprSection)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                KeyRecorderView(
                    keyCode: $recordedKeyCode,
                    useHypr: $useHypr, useShift: $useShift,
                    useControl: $useControl, useOption: $useOption,
                    useCommand: $useCommand
                )
                if let taken = conflict {
                    Text("Already bound to \(taken.actionDescription)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recordedKeyCode == 0 || selectedBundleID.isEmpty || conflict != nil)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(HyprSpacing.xl)
        .frame(width: 460)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                selectedBundleID = id
                selectedAppName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private var built: Keybind {
        let mods = ModifierFlags.from(hypr: useHypr, shift: useShift, control: useControl, option: useOption, command: useCommand)
        return Keybind(keyCode: recordedKeyCode, modifiers: mods,
                       action: .launchApp(bundleID: selectedBundleID))
    }

    private var conflict: Keybind? {
        recordedKeyCode == 0 ? nil : otherBinds.conflict(with: built, editing: nil)
    }

    private func save() {
        onSave(built)
        dismiss()
    }
}
