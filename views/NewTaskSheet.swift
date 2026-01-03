import SwiftUI

struct NewTaskSheet: View {
  @Environment(\.dismiss) var dismiss
  @ObservedObject var viewModel: SessionListViewModel

  @State private var title: String = ""
  @State private var description: String = ""
  @State private var selectedType: TaskType = .other
  @State private var selectedProvider: ProjectSessionSource = .codex
  @State private var selectedProjectId: String = ""
  @State private var isCreating: Bool = false

  var body: some View {
    Form {
      Section("Task Details") {
        TextField("Task Title", text: $title, prompt: Text("Enter task title"))
          .textFieldStyle(.roundedBorder)

        TextEditor(text: $description)
          .frame(minHeight: 80)
          .overlay(alignment: .topLeading) {
            if description.isEmpty {
              Text("Enter task description (optional)")
                .foregroundColor(.secondary)
                .padding(.leading, 5)
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
          }
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.gray.opacity(0.2), lineWidth: 1)
          )
      }

      Section("Task Type") {
        Picker("Type", selection: $selectedType) {
          ForEach(TaskType.allCases) { type in
            Label {
              Text(type.displayName)
            } icon: {
              Image(systemName: type.icon)
            }
            .tag(type)
          }
        }
        .pickerStyle(.menu)

        Text(selectedType.descriptionTemplate)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Section("Provider") {
        Picker("Default Provider", selection: $selectedProvider) {
          ForEach(ProjectSessionSource.allCases) { provider in
            Text(provider.displayName)
              .tag(provider)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Project") {
        Picker("Project", selection: $selectedProjectId) {
          Text("None").tag("")
          ForEach(viewModel.projects) { project in
            Text(project.name).tag(project.id)
          }
        }
        .pickerStyle(.menu)
      }
    }
    .formStyle(.grouped)
    .frame(width: 500, height: 480)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          createTask()
        }
        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
      }
    }
    .onAppear {
      // Set default project if one is selected
      if let firstSelected = viewModel.selectedProjectIDs.first {
        selectedProjectId = firstSelected
      } else if selectedProjectId.isEmpty, let firstProject = viewModel.projects.first {
        selectedProjectId = firstProject.id
      }
    }
  }

  private func createTask() {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return }

    isCreating = true

    let task = CodMateTask(
      title: trimmedTitle,
      description: description.trimmingCharacters(in: .whitespacesAndNewlines),
      taskType: selectedType,
      projectId: selectedProjectId.isEmpty ? "none" : selectedProjectId,
      status: .pending,
      primaryProvider: selectedProvider
    )

    Task {
      await viewModel.createTask(task)
      await MainActor.run {
        dismiss()
      }
    }
  }
}

#Preview {
  NewTaskSheet(
    viewModel: SessionListViewModel(
      preferences: SessionPreferencesStore()
    )
  )
}
