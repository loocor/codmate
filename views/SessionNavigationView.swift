import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SessionNavigationView<ProjectsContent: View>: View {
    let state: SidebarState
    let actions: SidebarActions
    let projectWorkspaceMode: ProjectWorkspaceMode
    let isAllOrOtherSelected: Bool
    @ViewBuilder var projectsContent: () -> ProjectsContent

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Projects").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(action: actions.requestNewProject) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("New Project")
                }

                VStack(spacing: 8) {
                    scopeAllRow(
                        title: "All",
                        isSelected: state.selectedProjectIDs.isEmpty,
                        icon: "rectangle.stack",
                        count: (state.visibleAllCount, state.totalSessionCount),
                        action: actions.selectAllProjects
                    )
                    projectsContent()
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)

            // Calendar only visible in Overview/Tasks modes, or Sessions mode (for Others)
            if shouldShowCalendar {
                calendarSection
                    .padding(.top, 8)
            }
        }
        .frame(idealWidth: 240)
    }

    // Show calendar only for Overview, Tasks, or Sessions (Others)
    private var shouldShowCalendar: Bool {
        switch projectWorkspaceMode {
        case .overview, .tasks, .settings:
            return true
        case .sessions:
            // Sessions mode is only used for "Others" project
            return isAllOrOtherSelected
        case .review, .agents, .memory:
            return false
        }
    }

    private func scopeAllRow(
        title: String,
        isSelected: Bool,
        icon: String,
        count: (visible: Int, total: Int)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .font(.caption)
            Text(title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 8)
            if let pair = count {
                Text("\(pair.visible)/\(pair.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            }
        }
        .frame(height: 16)
        .padding(8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    private var calendarSection: some View {
        VStack(spacing: 4) {
            calendarHeader

            Picker("", selection: dimensionBinding) {
                ForEach(DateDimension.allCases) { dim in
                    Text(dim.title).tag(dim)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            CalendarMonthView(
                monthStart: state.monthStart,
                counts: state.calendarCounts,
                selectedDays: state.selectedDays,
                enabledDays: state.enabledProjectDays
            ) { picked in
                handleDaySelection(picked)
            }
        }
        .padding(8)
    }

    private var dimensionBinding: Binding<DateDimension> {
        Binding(
            get: { state.dateDimension },
            set: { actions.setDateDimension($0) }
        )
    }

    private var calendarHeader: some View {
        let cal = Calendar.current
        let monthTitle: String = {
            let df = DateFormatter()
            df.dateFormat = "MMM yyyy"
            return df.string(from: state.monthStart)
        }()
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 16
            HStack(spacing: 0) {
                Button {
                    if let next = cal.date(byAdding: .month, value: -1, to: state.monthStart) {
                        actions.setMonthStart(next)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: columnWidth, height: 24)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    jumpToToday()
                } label: {
                    Text(monthTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    if let next = cal.date(byAdding: .month, value: 1, to: state.monthStart) {
                        actions.setMonthStart(next)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: columnWidth, height: 24)
                }
                .buttonStyle(.plain)
            }
            .frame(width: geometry.size.width)
        }
        .frame(height: 24)
    }

    private func jumpToToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if let month = cal.date(from: cal.dateComponents([.year, .month], from: today)) {
            actions.setMonthStart(month)
        } else {
            actions.setMonthStart(today)
        }
        actions.setSelectedDay(today)
    }

    private func handleDaySelection(_ picked: Date) {
        #if os(macOS)
        let useToggle = (NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        #else
        let useToggle = false
        #endif
        if useToggle {
            actions.toggleSelectedDay(picked)
        } else {
            if let current = state.selectedDay,
               Calendar.current.isDate(current, inSameDayAs: picked) {
                actions.setSelectedDay(nil)
            } else {
                actions.setSelectedDay(picked)
            }
        }
    }
}

private enum SidebarMode: Hashable { case directories, projects }

#Preview {
    let cal = Calendar.current
    let monthStart = cal.date(from: DateComponents(year: 2024, month: 12, day: 1))!
    let state = SidebarState(
        totalSessionCount: 15,
        isLoading: false,
        visibleAllCount: 12,
        selectedProjectIDs: [],
        selectedDay: nil,
        selectedDays: [],
        dateDimension: .updated,
        monthStart: monthStart,
        calendarCounts: [1: 2, 3: 4],
        enabledProjectDays: nil
    )
    let actions = SidebarActions(
        selectAllProjects: {},
        requestNewProject: {},
        requestNewTask: {},
        setDateDimension: { _ in },
        setMonthStart: { _ in },
        setSelectedDay: { _ in },
        toggleSelectedDay: { _ in }
    )

    return SessionNavigationView(
        state: state,
        actions: actions,
        projectWorkspaceMode: .tasks,
        isAllOrOtherSelected: true
    ) {
        EmptyView()
    }
    .frame(width: 280, height: 600)
}

#Preview("Loading State") {
    let cal = Calendar.current
    let monthStart = cal.date(from: DateComponents(year: 2024, month: 12, day: 1))!
    let state = SidebarState(
        totalSessionCount: 0,
        isLoading: true,
        visibleAllCount: 0,
        selectedProjectIDs: [],
        selectedDay: nil,
        selectedDays: [],
        dateDimension: .created,
        monthStart: monthStart,
        calendarCounts: [:],
        enabledProjectDays: nil
    )
    let actions = SidebarActions(
        selectAllProjects: {},
        requestNewProject: {},
        requestNewTask: {},
        setDateDimension: { _ in },
        setMonthStart: { _ in },
        setSelectedDay: { _ in },
        toggleSelectedDay: { _ in }
    )

    return SessionNavigationView(
        state: state,
        actions: actions,
        projectWorkspaceMode: .overview,
        isAllOrOtherSelected: true
    ) {
        EmptyView()
    }
    .frame(width: 280, height: 600)
}

#Preview("Calendar Day Selected") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let start = cal.date(from: DateComponents(year: 2024, month: 11, day: 1))!
    let state = SidebarState(
        totalSessionCount: 8,
        isLoading: false,
        visibleAllCount: 4,
        selectedProjectIDs: [],
        selectedDay: today,
        selectedDays: [today],
        dateDimension: .updated,
        monthStart: start,
        calendarCounts: [cal.component(.day, from: today): 3],
        enabledProjectDays: nil
    )
    let actions = SidebarActions(
        selectAllProjects: {},
        requestNewProject: {},
        requestNewTask: {},
        setDateDimension: { _ in },
        setMonthStart: { _ in },
        setSelectedDay: { _ in },
        toggleSelectedDay: { _ in }
    )

    return SessionNavigationView(
        state: state,
        actions: actions,
        projectWorkspaceMode: .tasks,
        isAllOrOtherSelected: false
    ) {
        EmptyView()
    }
    .frame(width: 280, height: 600)
}

#Preview("Path Selected") {
    let cal = Calendar.current
    let state = SidebarState(
        totalSessionCount: 5,
        isLoading: false,
        visibleAllCount: 5,
        selectedProjectIDs: ["demo"],
        selectedDay: nil,
        selectedDays: [],
        dateDimension: .updated,
        monthStart: cal.startOfDay(for: Date()),
        calendarCounts: [:],
        enabledProjectDays: [1, 3, 5]
    )
    let actions = SidebarActions(
        selectAllProjects: {},
        requestNewProject: {},
        requestNewTask: {},
        setDateDimension: { _ in },
        setMonthStart: { _ in },
        setSelectedDay: { _ in },
        toggleSelectedDay: { _ in }
    )

    return SessionNavigationView(
        state: state,
        actions: actions,
        projectWorkspaceMode: .review,
        isAllOrOtherSelected: false
    ) {
        EmptyView()
    }
    .frame(width: 280, height: 600)
}
