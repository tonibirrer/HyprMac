// Segmented picker for `switchWorkspace`, `moveToWorkspace` and
// `moveToWorkspaceAndFollow`.

import SwiftUI

/// Segmented workspace picker.
struct WorkspacePicker: View {
    @Binding var workspace: Int
    @ObservedObject private var config = UserConfig.shared

    var body: some View {
        Picker("Workspace", selection: $workspace) {
            ForEach(Constants.workspaceRange, id: \.self) {
                Text(UserConfig.workspaceDisplayName($0, names: config.workspaceNames, fallback: "\($0)")).tag($0)
            }
        }
        .pickerStyle(.segmented)
    }
}
