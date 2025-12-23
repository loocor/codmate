import AppKit

final class MainWindowCoordinator: NSObject, NSWindowDelegate {
  static let shared = MainWindowCoordinator()
  private weak var window: NSWindow?
  private var visibility: SystemMenuVisibility = .visible
  private var didAutoHideOnAttach = false
  private var lastAppliedVisibility: SystemMenuVisibility?

  var hasAttachedWindow: Bool { window != nil }

  func attach(_ window: NSWindow) {
    if self.window === window { return }
    self.window = window
    window.delegate = self
    applyVisibilityOnAttachIfNeeded()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    // If in menuOnly mode, switch back to .accessory after hiding window
    if visibility == .menuOnly {
      NSApplication.shared.setActivationPolicy(.accessory)
    }
    return false
  }

  func applyMenuVisibility(_ visibility: SystemMenuVisibility) {
    self.visibility = visibility
    let previous = lastAppliedVisibility
    lastAppliedVisibility = visibility
    if visibility == .menuOnly, previous != .menuOnly {
      hideMainWindow()
    }
  }

  private func applyVisibilityOnAttachIfNeeded() {
    guard visibility == .menuOnly, didAutoHideOnAttach == false else { return }
    hideMainWindow()
    didAutoHideOnAttach = true
  }

  private func hideMainWindow() {
    window?.orderOut(nil)
  }
}
