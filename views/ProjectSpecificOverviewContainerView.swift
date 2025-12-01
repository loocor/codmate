import SwiftUI

struct ProjectSpecificOverviewContainerView: View {
    @ObservedObject var sessionListViewModel: SessionListViewModel
    var project: Project
    var onSelectSession: (SessionSummary) -> Void
    var onResumeSession: (SessionSummary) -> Void
    var onFocusToday: () -> Void

    @StateObject private var projectOverviewViewModel: ProjectOverviewViewModel

    init(sessionListViewModel: SessionListViewModel, project: Project, onSelectSession: @escaping (SessionSummary) -> Void, onResumeSession: @escaping (SessionSummary) -> Void, onFocusToday: @escaping () -> Void) {
        self.sessionListViewModel = sessionListViewModel
        self.project = project
        self.onSelectSession = onSelectSession
        self.onResumeSession = onResumeSession
        self.onFocusToday = onFocusToday
        _projectOverviewViewModel = StateObject(wrappedValue: ProjectOverviewViewModel(sessionListViewModel: sessionListViewModel, project: project))
    }
    
    var body: some View {
        ProjectOverviewView(
            viewModel: projectOverviewViewModel,
            onSelectSession: onSelectSession,
            onResumeSession: onResumeSession,
            onFocusToday: onFocusToday
        )
        // Update the project in the ViewModel if it changes from outside
        .onChange(of: project) { _, newProject in
            projectOverviewViewModel.updateProject(newProject)
        }
    }
}
