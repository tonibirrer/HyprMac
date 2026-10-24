// "App Rules" panel (fork): per-app effects beside upstream's workspace
// pins (Settings → General → Pin apps to workspaces). A rule can give the
// app a tile sort priority — higher keeps its tiles further top-left,
// lower further bottom-right — honor its own activations, make it sticky
// (Hyprland's `pin`): its windows follow the user across every workspace
// that opts in on the Workspaces panel — grant it a full-height column in
// the dwindle layout, or block synthetic clicks into it.

import SwiftUI

/// Per-app effect list, shown on the Layout tab.
struct AppRulesPanel: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        HyprPanel("App Rules",
                  footer: "Workspace pins live in General → Pin apps to workspaces. \"Activate\" honors the app's activation requests (URL opens) even without a user gesture. \"Sticky\" shows the app on every workspace that opts in (Workspaces panel below). \"Full height\" always gives the app a full-height column — other windows stack beside it, never above or below. Sort keeps the app's tiles in order: higher = top-left, lower = bottom-right.") {
            if config.appRules.isEmpty {
                HyprRow("No rules", icon: "circle.dashed",
                        subtitle: "Apps tile in insertion order", divider: false) { EmptyView() }
            } else {
                ForEach(Array(config.appRules.enumerated()), id: \.element.id) { idx, rule in
                    ruleRow(rule, isLast: idx == config.appRules.count - 1)
                }
            }
            HyprRow("Add app", icon: "plus", divider: false) {
                Button("Choose…") { pickApp() }
                    .controlSize(.small)
            }
        }
    }

    private func ruleRow(_ rule: AppRule, isLast: Bool) -> some View {
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
                config.appRules.removeAll { $0.bundleID == rule.bundleID }
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

    private func binding(for bundleID: String, keyPath: WritableKeyPath<AppRule, Int>) -> Binding<Int> {
        Binding(
            get: { config.appRules.first { $0.bundleID == bundleID }?[keyPath: keyPath] ?? 0 },
            set: { value in update(bundleID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ bundleID: String, _ mutate: (inout AppRule) -> Void) {
        guard let idx = config.appRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        var rule = config.appRules[idx]
        mutate(&rule)
        config.appRules[idx] = rule
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
           !config.appRules.contains(where: { $0.bundleID == id }) {
            // new rules start neutral: priority 0, every effect off —
            // adding an app changes nothing until the user picks an effect.
            config.appRules.append(AppRule(bundleID: id))
        }
    }
}
