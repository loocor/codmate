import SwiftUI

struct AutoAssignSheet: View {
    @EnvironmentObject var viewModel: SessionListViewModel
    @Binding var isPresented: Bool

    enum Scope: String, CaseIterable, Identifiable {
        case today = "Today"
        case all = "All"
        case custom = "Custom"
        var id: String { rawValue }
        var localizedName: String {
             switch self {
             case .today: return "Today"
             case .all: return "All Time"
             case .custom: return "Custom Range"
             }
        }
    }

    @State private var scope: Scope = .today
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var isProcessing = false
    @State private var progressMessage: String = ""
    @State private var progressValue: Double = 0.0
    @State private var assignedCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Auto Assign to Projects")
                .font(.headline)

            VStack(alignment: .center, spacing: 12) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s.localizedName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isProcessing)

                if scope == .custom {
                    HStack(spacing: 8) {
                        DatePicker("From", selection: $startDate, displayedComponents: .date)
                            .labelsHidden()
                        Text("-")
                            .foregroundStyle(.secondary)
                        DatePicker("To", selection: $endDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .disabled(isProcessing)
                }
                
                Text("Matches sessions to projects based on their working directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            if isProcessing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progressValue, total: 1.0)
                    Text(progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProcessing)
                
                Spacer()
                
                Button("Start Assignment") {
                    startAssignment()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding()
        .frame(width: 400, height: scope == .custom ? 260 : 200)
    }

    private func startAssignment() {
        isProcessing = true
        progressValue = 0.0
        progressMessage = "Analyzing sessions..."
        assignedCount = 0
        
        Task {
            await performAssignment()
        }
    }
    
    private func performAssignment() async {
        let vm = self.viewModel
        
        // 1. Identify candidates based on scope
        let candidates = filterCandidates()
        
        if candidates.isEmpty {
            await MainActor.run {
                progressMessage = "No unassigned sessions found for this scope."
                progressValue = 1.0
                isProcessing = false
            }
            // Small delay to let user see the message? Or rely on system notification
             await SystemNotifier.shared.notify(title: "CodMate", body: "No unassigned sessions found.")
             isPresented = false
            return
        }
        
        await MainActor.run {
            progressMessage = "Found \(candidates.count) unassigned sessions. Matching..."
        }

        // 2. Match sessions to projects
        // We can batch this to show progress
        var assignments: [String: [String]] = [:]
        let total = Double(candidates.count)
        var processed = 0
        
        for session in candidates {
            if let bestId = vm.bestMatchingProjectId(for: session) {
                assignments[bestId, default: []].append(session.id)
            }
            
            processed += 1
            if processed % 50 == 0 {
                let current = processed
                await MainActor.run {
                    progressValue = Double(current) / total
                }
            }
        }

        guard !assignments.isEmpty else {
            await MainActor.run {
                progressMessage = "No matching projects found."
                progressValue = 1.0
                isProcessing = false
            }
            await SystemNotifier.shared.notify(title: "CodMate", body: "No matching project paths found.")
            isPresented = false
            return
        }

        // 3. Apply assignments
        await MainActor.run {
            progressMessage = "Assigning sessions..."
            progressValue = 1.0 // Matching done
        }
        
        var assignedTotal = 0
        for (pid, ids) in assignments {
            assignedTotal += ids.count
            await vm.assignSessions(to: pid, ids: ids)
        }
        
        await MainActor.run {
            vm.scheduleApplyFilters()
            isProcessing = false
            isPresented = false
        }
        
        await SystemNotifier.shared.notify(
          title: "CodMate",
          body: "Auto-assigned \(assignedTotal) session(s)."
        )
    }
    
    private func filterCandidates() -> [SessionSummary] {
        let vm = self.viewModel
        let allUnassigned = vm.allSessions.filter { vm.projectIdForSession($0.id) == nil }
        
        switch scope {
        case .all:
            return allUnassigned
            
        case .today:
            let today = Date()
            let cal = Calendar.current
            return allUnassigned.filter { session in
                let createdMatch = cal.isDate(session.startedAt, inSameDayAs: today)
                let updatedMatch: Bool
                if let last = session.lastUpdatedAt {
                    updatedMatch = cal.isDate(last, inSameDayAs: today)
                } else {
                    updatedMatch = false
                }
                return createdMatch || updatedMatch
            }
            
        case .custom:
            let start = Calendar.current.startOfDay(for: startDate)
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) else {
                // Calendar operation failed (edge case), fallback to all unassigned
                return allUnassigned
            }
            let range = start..<end
            
            return allUnassigned.filter { session in
                let createdMatch = range.contains(session.startedAt)
                let updatedMatch: Bool
                if let last = session.lastUpdatedAt {
                    updatedMatch = range.contains(last)
                } else {
                    updatedMatch = false
                }
                return createdMatch || updatedMatch
            }
        }
    }
}
