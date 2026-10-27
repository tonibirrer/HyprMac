// Sheet for naming workspaces 1–10. Presented from the General tab
// "Workspace names" row. Edits save as you type.

import SwiftUI

struct WorkspaceNamesSheet: View {
    @ObservedObject var config: UserConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: HyprSpacing.lg) {
            VStack(alignment: .leading, spacing: HyprSpacing.xs) {
                Text("Workspace Names")
                    .font(.hyprTitle)
                Text("A name replaces the number in the switch HUD, the menu bar and the workspace pickers. "
                     + "Leave it empty to keep the number.")
                    .font(.hyprCaption)
                    .foregroundStyle(Color.hyprTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 1–5 left, 6–10 right
            HStack(alignment: .top, spacing: HyprSpacing.md) {
                column(Array(Constants.workspaceRange.prefix(5)))
                column(Array(Constants.workspaceRange.dropFirst(5)))
            }

            HStack {
                Button("Clear All") { config.workspaceNames = [:] }
                    .disabled(config.workspaceNames.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(HyprSpacing.xl)
        .frame(width: 460)
    }

    private func column(_ workspaces: [Int]) -> some View {
        VStack(spacing: 0) {
            ForEach(workspaces, id: \.self) { workspace in
                HStack(spacing: HyprSpacing.sm) {
                    Text("\(workspace)")
                        .font(.hyprMonoSm)
                        .foregroundStyle(Color.hyprTextSecondary)
                        .frame(width: 18, alignment: .trailing)
                    TextField("Workspace \(workspace)", text: nameBinding(workspace),
                              prompt: Text("Workspace \(workspace)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, HyprSpacing.md)
                .padding(.vertical, HyprSpacing.sm)
                .overlay(alignment: .bottom) {
                    if workspace != workspaces.last {
                        Rectangle()
                            .fill(Color.hyprSeparator)
                            .frame(height: 0.5)
                            .padding(.leading, HyprSpacing.md)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .fill(Color.hyprSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HyprRadius.lg, style: .continuous)
                .strokeBorder(Color.hyprSeparator, lineWidth: 0.5)
        )
    }

    // empty removes the key
    private func nameBinding(_ workspace: Int) -> Binding<String> {
        Binding(get: { config.workspaceNames[String(workspace)] ?? "" },
                set: { config.workspaceNames[String(workspace)] = $0.isEmpty ? nil : $0 })
    }
}
