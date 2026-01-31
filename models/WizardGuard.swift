import Foundation

@MainActor
final class WizardGuard: ObservableObject {
  @Published var isActive: Bool = false
}
