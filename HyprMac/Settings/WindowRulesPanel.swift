// "Window Rules" panel: Hyprland-style per-app rules. Each rule can
// pin an app's new windows to a fixed workspace (by default the
// workspace is switched to as well; toggle off for a silent move)
// and/or give the app a tile sort priority — higher keeps its tiles
// further top-left, lower further bottom-right — and/or make the app
// sticky (Hyprland's `pin`): its windows follow the user across every
// workspace that opts in on the Workspaces panel — and/or grant the app
// a full-height column in the dwindle layout.

import SwiftUI

/// Per-app rule list (workspace pin + sort priority), shown on the Layout tab.
struct WindowRulesPanel: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        HyprPanel("Window Rules",
                  footer: "New windows of these apps open on their pinned workspace (\"—\" = no pin); \"Follow\" also switches to it. \"Activate\" honors the app's activation requests (URL opens) even without a user gesture. \"Sticky\" shows the app on every workspace that opts in (Workspaces panel below). \"Full height\" always gives the app a full-height column — other windows stack beside it, never above or below. Sort keeps the app's tiles in order: higher = top-left, lower = bottom-right.") {
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
                Text("—").tag(0)
                ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 56)
            .help("Pin new windows of this app to a workspace (\"—\" = no pin)")
            Toggle("Follow", isOn: Binding(
                get: { !rule.silent },
                set: { follow in update(rule.bundleID) { $0.silent = !follow } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .disabled(rule.workspace == 0)
            .help("Also switch to the pinned workspace when a window opens")
            Toggle("Activate", isOn: Binding(
                get: { rule.focusOnActivate },
                set: { on in update(rule.bundleID) { $0.focusOnActivate = on } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .help("Always honor this app's activation requests: switch to its workspace even without a click or keystroke — e.g. when another app opens a URL in it (Hyprland's focus_on_activate)")
            Toggle("Sticky", isOn: Binding(
                get: { rule.sticky },
                set: { on in update(rule.bundleID) { $0.sticky = on } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .help("Show this app's windows on every workspace that opts in (Workspaces → Sticky): they follow you between those workspaces on their monitor and hide like any other window elsewhere (Hyprland's pin, extended to tiled windows)")
            Toggle("Full height", isOn: Binding(
                get: { rule.fullHeight },
                set: { on in update(rule.bundleID) { $0.fullHeight = on } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .help("Always give this app a full-height column: new windows open beside it, never above or below, and no split above it can stack (like a master window in Hyprland's master layout)")
            Toggle("No fake click", isOn: Binding(
                get: { rule.noSyntheticClick },
                set: { on in update(rule.bundleID) { $0.noSyntheticClick = on } }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .help("Never post a synthesized mouse click into this app to force activation under focus-follows-mouse. Turn on for remote desktops, VMs and games that forward mouse input — a fake click there causes stuck or phantom presses. Common clients (Citrix, Microsoft Remote Desktop, VMware, Parallels, VNC…) are blocked by default.")
            HStack(spacing: 2) {
                Text("\(rule.sortPriority)")
                    .font(.hyprMonoXs)
                    .frame(width: 20, alignment: .trailing)
                Stepper("", value: binding(for: rule.bundleID, keyPath: \.sortPriority), in: -9...9)
                    .labelsHidden()
            }
            .help("Sort priority: higher tiles top-left, lower bottom-right, 0 = insertion order")
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
            get: { config.windowRules.first { $0.bundleID == bundleID }?[keyPath: keyPath] ?? 0 },
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
        panel.title = "Select Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
           !config.windowRules.contains(where: { $0.bundleID == id }) {
            // new rules start neutral: no workspace pin, priority 0 —
            // adding an app must not move its windows until the user
            // picks an effect.
            config.windowRules.append(WindowRule(bundleID: id, workspace: 0))
        }
    }
}
