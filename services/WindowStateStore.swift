import Foundation
import CoreGraphics

/// Persists and restores the main window state across app launches
@MainActor
final class WindowStateStore: ObservableObject {
  private let defaults: UserDefaults

  private struct Keys {
    static let selectedProjectIDs = "codmate.window.selectedProjectIDs"
    static let selectedDay = "codmate.window.selectedDay"
    static let selectedDays = "codmate.window.selectedDays"
    static let monthStart = "codmate.window.monthStart"
    static let selectedSessionIDs = "codmate.window.selectedSessionIDs"
    static let selectionPrimaryId = "codmate.window.selectionPrimaryId"
    static let contentColumnWidth = "codmate.window.contentColumnWidth"
    static let reviewLeftPaneWidth = "codmate.window.reviewLeftPaneWidth"
    static let expandedProjects = "codmate.window.expandedProjects"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: - Save State

  func saveProjectSelection(_ projectIDs: Set<String>) {
    let array = Array(projectIDs)
    defaults.set(array, forKey: Keys.selectedProjectIDs)
  }

  func saveCalendarSelection(selectedDay: Date?, selectedDays: Set<Date>, monthStart: Date) {
    if let day = selectedDay {
      defaults.set(day.timeIntervalSinceReferenceDate, forKey: Keys.selectedDay)
    } else {
      defaults.removeObject(forKey: Keys.selectedDay)
    }

    let intervals = selectedDays.map { $0.timeIntervalSinceReferenceDate }
    defaults.set(intervals, forKey: Keys.selectedDays)

    defaults.set(monthStart.timeIntervalSinceReferenceDate, forKey: Keys.monthStart)
  }

  func saveSessionSelection(selectedIDs: Set<SessionSummary.ID>, primaryId: SessionSummary.ID?) {
    let array = Array(selectedIDs)
    defaults.set(array, forKey: Keys.selectedSessionIDs)

    if let primary = primaryId {
      defaults.set(primary, forKey: Keys.selectionPrimaryId)
    } else {
      defaults.removeObject(forKey: Keys.selectionPrimaryId)
    }
  }

  // MARK: - Column Width Persistence
  func saveContentColumnWidth(_ width: CGFloat) {
    defaults.set(Double(width), forKey: Keys.contentColumnWidth)
  }

  func restoreContentColumnWidth() -> CGFloat? {
    let w = defaults.double(forKey: Keys.contentColumnWidth)
    return w > 0 ? CGFloat(w) : nil
  }

  func saveReviewLeftPaneWidth(_ width: CGFloat) {
    defaults.set(Double(width), forKey: Keys.reviewLeftPaneWidth)
  }

  func restoreReviewLeftPaneWidth() -> CGFloat? {
    let w = defaults.double(forKey: Keys.reviewLeftPaneWidth)
    return w > 0 ? CGFloat(w) : nil
  }

  // MARK: - Restore State

  func restoreProjectSelection() -> Set<String> {
    guard let array = defaults.array(forKey: Keys.selectedProjectIDs) as? [String] else {
      return []
    }
    return Set(array)
  }

  func restoreCalendarSelection() -> (
    selectedDay: Date?, selectedDays: Set<Date>, monthStart: Date?
  ) {
    let selectedDay: Date? = {
      let interval = defaults.double(forKey: Keys.selectedDay)
      guard interval != 0 else { return nil }
      return Date(timeIntervalSinceReferenceDate: interval)
    }()

    let selectedDays: Set<Date> = {
      guard let intervals = defaults.array(forKey: Keys.selectedDays) as? [TimeInterval] else {
        return []
      }
      return Set(intervals.map { Date(timeIntervalSinceReferenceDate: $0) })
    }()

    let monthStart: Date? = {
      let interval = defaults.double(forKey: Keys.monthStart)
      guard interval != 0 else { return nil }
      return Date(timeIntervalSinceReferenceDate: interval)
    }()

    return (selectedDay, selectedDays, monthStart)
  }

  func restoreSessionSelection() -> (
    selectedIDs: Set<SessionSummary.ID>, primaryId: SessionSummary.ID?
  ) {
    let selectedIDs: Set<SessionSummary.ID> = {
      guard let array = defaults.array(forKey: Keys.selectedSessionIDs) as? [String] else {
        return []
      }
      return Set(array)
    }()

    let primaryId = defaults.string(forKey: Keys.selectionPrimaryId)

    return (selectedIDs, primaryId)
  }

  func saveProjectExpansions(_ ids: Set<String>) {
    defaults.set(Array(ids), forKey: Keys.expandedProjects)
  }

  func restoreProjectExpansions() -> Set<String> {
    guard let array = defaults.array(forKey: Keys.expandedProjects) as? [String] else {
      return []
    }
    return Set(array)
  }

  // MARK: - Clear State

  func clearAll() {
    defaults.removeObject(forKey: Keys.selectedProjectIDs)
    defaults.removeObject(forKey: Keys.selectedDay)
    defaults.removeObject(forKey: Keys.selectedDays)
    defaults.removeObject(forKey: Keys.monthStart)
    defaults.removeObject(forKey: Keys.contentColumnWidth)
    defaults.removeObject(forKey: Keys.reviewLeftPaneWidth)
    defaults.removeObject(forKey: Keys.selectedSessionIDs)
    defaults.removeObject(forKey: Keys.selectionPrimaryId)
    defaults.removeObject(forKey: Keys.expandedProjects)
  }
}
