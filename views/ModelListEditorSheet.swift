import SwiftUI

struct ModelListEditorSheet: View {
  let title: String
  let description: String
  let availableModels: [String]
  let onSave: ([String]) -> Void
  let onReset: (() -> Void)?

  @State private var draft: [String]
  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    description: String,
    availableModels: [String],
    models: [String],
    onSave: @escaping ([String]) -> Void,
    onReset: (() -> Void)? = nil
  ) {
    self.title = title
    self.description = description
    self.availableModels = availableModels
    self.onSave = onSave
    self.onReset = onReset
    self._draft = State(initialValue: models)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2).fontWeight(.semibold)
      Text(description)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(draft.indices, id: \.self) { index in
          HStack(spacing: 8) {
            TextField("model-id", text: Binding(
              get: { draft[index] },
              set: { draft[index] = $0 }
            ))
            Button(role: .destructive) {
              draft.remove(at: index)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
          }
        }
        if draft.isEmpty {
          Text("No models selected yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(10)
      .background(Color(nsColor: .separatorColor).opacity(0.35))
      .cornerRadius(10)

      HStack(spacing: 8) {
        Menu {
          if !availableModels.isEmpty {
            Section("Available") {
              ForEach(availableModels, id: \.self) { model in
                Button(model) { draft.append(model) }
                  .disabled(draft.contains(model))
              }
            }
            Divider()
          }
          Button("Custom…") { draft.append("") }
        } label: {
          Label("Add", systemImage: "plus")
        }
        if let onReset {
          Button("Reset to Auto") {
            onReset()
            dismiss()
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save") {
          onSave(Self.sanitize(draft))
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(minWidth: 520)
  }

  private static func sanitize(_ list: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for item in list {
      let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if seen.insert(trimmed).inserted {
        out.append(trimmed)
      }
    }
    return out
  }
}
