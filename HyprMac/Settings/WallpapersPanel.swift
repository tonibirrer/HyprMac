// "Workspaces" panel: per-workspace accent color, desktop image, and
// sticky opt-in. The color drives the focus border on that workspace
// and is served over IPC so status bars (sketchybar) can color-match.
// Switching to a workspace swaps its monitor's wallpaper; workspaces
// without an image keep whatever is currently set. "Sticky" opts the
// workspace into showing sticky-ruled apps (Window Rules panel).

import SwiftUI
import UniformTypeIdentifiers

/// Per-workspace color + wallpaper list, shown on the Layout tab.
struct WallpapersPanel: View {
    @ObservedObject var config = UserConfig.shared

    var body: some View {
        HyprPanel("Workspaces",
                  footer: "The accent color tints the focus border on that workspace and is exposed over IPC for status bars. The wallpaper swaps in when the workspace is shown; workspaces without one keep the current desktop image. \"Sticky\" opts the workspace into showing sticky apps from Window Rules — they follow you between opted-in workspaces on their monitor.") {
            ForEach(1...9, id: \.self) { ws in
                wallpaperRow(ws, isLast: ws == 9)
            }
        }
    }

    private func colorBinding(_ ws: Int) -> Binding<Color> {
        Binding(
            get: {
                if let hex = config.workspaceColors[String(ws)], let c = NSColor.fromHex(hex) {
                    return Color(c)
                }
                return Color(config.resolvedFocusBorderColor)
            },
            set: { config.workspaceColors[String(ws)] = NSColor($0).hexString }
        )
    }

    private func wallpaperRow(_ ws: Int, isLast: Bool) -> some View {
        let path = config.workspaceWallpapers[String(ws)]
        let hasColor = config.workspaceColors[String(ws)] != nil
        return HStack(spacing: HyprSpacing.md) {
            Text("\(ws)")
                .font(.hyprBody.monospacedDigit())
                .frame(width: 22, alignment: .center)
            ColorPicker("", selection: colorBinding(ws), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
                .opacity(hasColor ? 1.0 : 0.45)
                .contextMenu {
                    if hasColor {
                        Button("Use default color") {
                            config.workspaceColors.removeValue(forKey: String(ws))
                        }
                    }
                }
            thumbnail(path)
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "Default")
                .font(path == nil ? .hyprCaption : .hyprBody)
                .foregroundStyle(path == nil ? Color.hyprTextTertiary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle("Sticky", isOn: Binding(
                get: { config.stickyWorkspaces.contains(ws) },
                set: { on in
                    if on { config.stickyWorkspaces.insert(ws) } else { config.stickyWorkspaces.remove(ws) }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.hyprBody)
            .help("Show sticky apps (Window Rules → Sticky) on this workspace")
            Button("Choose…") { pickImage(for: ws) }
                .controlSize(.small)
            if path != nil {
                Button {
                    config.workspaceWallpapers.removeValue(forKey: String(ws))
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.borderless)
            }
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

    @ViewBuilder
    private func thumbnail(_ path: String?) -> some View {
        if let path, let img = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.hyprBackground)
                .frame(width: 36, height: 22)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.hyprTextTertiary)
                )
        }
    }

    private func pickImage(for ws: Int) {
        let panel = NSOpenPanel()
        panel.title = "Wallpaper for Workspace \(ws)"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            config.workspaceWallpapers[String(ws)] = url.path
            // guess the workspace accent from the picture — dominant hue,
            // lifted into border-ready range. monochrome images keep the
            // current color.
            if let img = NSImage(contentsOf: url), let accent = img.dominantAccentColor() {
                config.workspaceColors[String(ws)] = accent.hexString
            }
        }
    }
}
