// "Window Rules" panel: Hyprland-style app → workspace pins. Each rule
// sends an app's new windows to a fixed workspace; by default the
// workspace is switched to as well (toggle off for a silent move).

import SwiftUI

/// App → workspace rule list, shown on the Layout tab.
struct WindowRulesPanel: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        HyprPanel("Window Rules",
                  footer: "New windows of these apps always open on their pinned workspace. \"Follow\" also switches to that workspace.") {
            if config.windowRules.isEmpty {
                HyprRow("No rules", icon: "circle.dashed",
                        subtitle: "New windows open on the active workspace", divider: false) { EmptyView() }
            } else {
                ForEach(Array(config.windowRules.enumerated()), id: \.element.id) { idx, rule in
                    ruleRow(rule, isLast: idx == config.windowRules.count - 1)
                }
            }
            HyprRow("Add app", icon: "plus", divider: false) {
                Button("Choose…") { pickApp() }
                    .controlSize(.small)
            }
        }
    }

    private func ruleRow(_ rule: WindowRule, isLast: Bool) -> some View {
        HStack(spacing: HyprSpacing.md) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app").font(.system(size: 16)).foregroundStyle(Color.hyprTextTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appDisplayName(for: rule.bundleID)).font(.hyprBody)
                Text(rule.bundleID).font(.hyprMonoXs).foregroundStyle(Color.hyprTextTertiary)
            }
            Spacer()
            Picker("", selection: binding(for: rule.bundleID, keyPath: \.workspace)) {
                ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 56)
            Toggle("Follow", isOn: Binding(
                get: { !rule.silent },
                set: { follow in update(rule.bundleID) { $0.silent = !follow } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            Button {
                config.windowRules.removeAll { $0.bundleID == rule.bundleID }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, HyprSpacing.md)
        .padding(.vertical, HyprSpacing.sm)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color.hyprSeparator)
                    .frame(height: 0.5)
                    .padding(.leading, HyprSpacing.md + 22 + HyprSpacing.md)
            }
        }
    }

    private func binding(for bundleID: String, keyPath: WritableKeyPath<WindowRule, Int>) -> Binding<Int> {
        Binding(
            get: { config.windowRules.first { $0.bundleID == bundleID }?[keyPath: keyPath] ?? 1 },
            set: { value in update(bundleID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ bundleID: String, _ mutate: (inout WindowRule) -> Void) {
        guard let idx = config.windowRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        var rule = config.windowRules[idx]
        mutate(&rule)
        config.windowRules[idx] = rule
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Application to Pin"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
           !config.windowRules.contains(where: { $0.bundleID == id }) {
            config.windowRules.append(WindowRule(bundleID: id, workspace: 1))
        }
    }
}
