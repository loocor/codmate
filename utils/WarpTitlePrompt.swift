import Foundation

#if canImport(AppKit)
import AppKit

enum WarpTitlePrompt {
    static func requestCustomTitle(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Warp Tab Title"
        alert.informativeText = "Enter a short slug for the new tab (letters, digits, hyphen). Leave blank to use the suggested value."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        field.selectText(nil)
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return field.stringValue
        } else {
            return nil
        }
    }
}
#else
enum WarpTitlePrompt {
    static func requestCustomTitle(defaultValue: String) -> String? { defaultValue }
}
#endif
