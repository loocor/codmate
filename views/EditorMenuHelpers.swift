import AppKit
import SwiftUI

/// Creates a label with the editor's title and icon
@ViewBuilder
func editorLabel(for editor: EditorApp) -> some View {
  Label {
    Text(editor.title)
  } icon: {
    if let icon = editor.menuIcon {
      Image(nsImage: icon)
    } else {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
    }
  }
}

@ViewBuilder
func openInEditorMenu(
  editors: [EditorApp],
  onOpen: @escaping (EditorApp) -> Void
) -> some View {
  if !editors.isEmpty {
    Menu {
      ForEach(editors) { editor in
        Button {
          onOpen(editor)
        } label: {
          editorLabel(for: editor)
        }
      }
    } label: {
      Label("Open in", systemImage: "arrow.up.forward.app")
    }
  }
}
