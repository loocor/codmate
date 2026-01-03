import SwiftUI

struct UnifiedProviderPickerView: View {
  let sections: [UnifiedProviderSection]
  let models: [String]
  let modelSectionTitle: String?
  let includeAuto: Bool
  let autoTitle: String
  let includeDefaultModel: Bool
  let defaultModelTitle: String
  let providerUnavailableHint: String?
  let disableModels: Bool
  let showProviderPicker: Bool
  let showModelPicker: Bool
  let onEditModels: (() -> Void)?
  let editModelsHelp: String?

  @Binding var providerId: String?
  @Binding var modelId: String?

  init(
    sections: [UnifiedProviderSection],
    models: [String],
    modelSectionTitle: String?,
    includeAuto: Bool,
    autoTitle: String,
    includeDefaultModel: Bool,
    defaultModelTitle: String,
    providerUnavailableHint: String?,
    disableModels: Bool,
    showProviderPicker: Bool = true,
    showModelPicker: Bool = true,
    onEditModels: (() -> Void)? = nil,
    editModelsHelp: String? = nil,
    providerId: Binding<String?>,
    modelId: Binding<String?>
  ) {
    self.sections = sections
    self.models = models
    self.modelSectionTitle = modelSectionTitle
    self.includeAuto = includeAuto
    self.autoTitle = autoTitle
    self.includeDefaultModel = includeDefaultModel
    self.defaultModelTitle = defaultModelTitle
    self.providerUnavailableHint = providerUnavailableHint
    self.disableModels = disableModels
    self.showProviderPicker = showProviderPicker
    self.showModelPicker = showModelPicker
    self.onEditModels = onEditModels
    self.editModelsHelp = editModelsHelp
    self._providerId = providerId
    self._modelId = modelId
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 8) {
        if showProviderPicker {
          providerPicker
        }
        if showModelPicker {
          modelPicker
        }
        if showModelPicker, let onEditModels {
          Button {
            onEditModels()
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .buttonStyle(.borderless)
          .help(editModelsHelp ?? "Edit models")
        }
      }
      if showProviderPicker, let hint = providerUnavailableHint, !hint.isEmpty {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var providerPicker: some View {
    Picker("", selection: $providerId) {
      if includeAuto {
        Text(autoTitle).tag(String?.none)
      }
      ForEach(sections) { section in
        Section(section.title) {
          ForEach(section.providers) { provider in
            Text(provider.title)
              .tag(String?(provider.id))
              .disabled(!provider.isAvailable)
          }
        }
      }
    }
    .labelsHidden()
  }

  private var modelPicker: some View {
    Picker("", selection: $modelId) {
      if includeDefaultModel {
        Text(defaultModelTitle).tag(String?.none)
      }
      if let title = modelSectionTitle, !models.isEmpty {
        Section(title) {
          ForEach(models, id: \.self) { model in
            Text(model).tag(String?(model))
          }
        }
      } else {
        ForEach(models, id: \.self) { model in
          Text(model).tag(String?(model))
        }
      }
    }
    .labelsHidden()
    .disabled(disableModels)
  }
}
