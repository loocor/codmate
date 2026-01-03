import SwiftUI

struct ClaudeModelMappingSheet: View {
  let availableModels: [String]
  let onSave: (_ defaultModel: String?, _ aliases: [String: String]) -> Void
  let onAutoFill: (_ selectedDefault: String?) -> [String: String]

  @State private var draftDefault: String
  @State private var draftAliases: [String: String]
  @Environment(\.dismiss) private var dismiss

  init(
    availableModels: [String],
    defaultModel: String?,
    aliases: [String: String],
    onSave: @escaping (_ defaultModel: String?, _ aliases: [String: String]) -> Void,
    onAutoFill: @escaping (_ selectedDefault: String?) -> [String: String]
  ) {
    self.availableModels = availableModels
    self.onSave = onSave
    self.onAutoFill = onAutoFill
    self._draftDefault = State(initialValue: defaultModel ?? "")
    self._draftAliases = State(initialValue: aliases)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Model Mappings").font(.title2).fontWeight(.semibold)
      Text("Map Claude Code tiers to CLI Proxy model IDs. Defaults apply to Claude Code 2.x; the default model also feeds legacy variables.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 12) {
        mappingRow(
          title: "Default",
          help: "Used for ANTHROPIC_MODEL and as the fallback for missing tiers.",
          binding: $draftDefault
        )
        mappingRow(
          title: "Opus",
          help: "ANTHROPIC_DEFAULT_OPUS_MODEL",
          binding: aliasBinding("opus")
        )
        mappingRow(
          title: "Sonnet",
          help: "ANTHROPIC_DEFAULT_SONNET_MODEL",
          binding: aliasBinding("sonnet")
        )
        mappingRow(
          title: "Haiku",
          help: "ANTHROPIC_DEFAULT_HAIKU_MODEL + ANTHROPIC_SMALL_FAST_MODEL",
          binding: aliasBinding("haiku")
        )
      }
      .padding(10)
      .background(Color(nsColor: .separatorColor).opacity(0.35))
      .cornerRadius(10)

      HStack(spacing: 8) {
        Button("Auto Fill") {
          let auto = onAutoFill(normalized(draftDefault))
          for (key, value) in auto {
            draftAliases[key] = value
          }
          if let autoDefault = auto["default"], draftDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftDefault = autoDefault
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save") {
          let cleanedDefault = normalized(draftDefault)
          let cleanedAliases = sanitizeAliases(draftAliases)
          onSave(cleanedDefault, cleanedAliases)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(minWidth: 560)
  }

  private func mappingRow(title: String, help: String, binding: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(title)
          .frame(width: 90, alignment: .leading)
        TextField("model-id", text: binding)
        if !availableModels.isEmpty {
          Menu {
            ForEach(availableModels, id: \.self) { model in
              Button(model) { binding.wrappedValue = model }
            }
          } label: {
            Image(systemName: "chevron.down")
          }
          .help("Pick from available models")
        }
        Button {
          binding.wrappedValue = ""
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Clear")
      }
      Text(help)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 98)
    }
  }

  private func aliasBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { draftAliases[key] ?? "" },
      set: { draftAliases[key] = $0 }
    )
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func sanitizeAliases(_ aliases: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in aliases {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        out[key] = trimmed
      }
    }
    return out
  }
}
