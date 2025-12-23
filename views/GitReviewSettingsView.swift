import SwiftUI

struct GitReviewSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore

  @State private var draftTemplate: String = ""
  @State private var providerId: String? = nil
  @State private var providersList: [ProvidersRegistryService.Provider] = []
  @State private var modelId: String? = nil
  @State private var modelList: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Git Review Settings").font(.title2).fontWeight(.bold)
          Text("Customize Git changes viewer and AI commit generation.")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
      }

      // Match horizontal padding with other settings (no extra inner padding)
      VStack(alignment: .leading, spacing: 0) {
        // Options grid
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Text("Show Line Numbers").font(.subheadline).fontWeight(.medium)
              Text("Show line numbers in diffs.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("", isOn: $preferences.gitShowLineNumbers)
              .labelsHidden().toggleStyle(.switch).controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          gridDivider
          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Text("Wrap Long Lines").font(.subheadline).fontWeight(.medium)
              Text("Enable soft wrap in diff viewer.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("", isOn: $preferences.gitWrapText)
              .labelsHidden().toggleStyle(.switch).controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          gridDivider
          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Text("Commit Model").font(.subheadline).fontWeight(.medium)
              Text("Select Provider and Model for commit generation.")
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Picker(
                "",
                selection: Binding(
                  get: { providerId ?? "(auto)" },
                  set: { newVal in
                    providerId = (newVal == "(auto)") ? nil : newVal
                    preferences.commitProviderId = providerId
                    // Update models list when provider changes
                    let models = modelsForCurrentProvider()
                    modelList = models
                    // Reset model when provider changed
                    modelId =
                      models.contains(preferences.commitModelId ?? "")
                      ? preferences.commitModelId : nil
                  }
                )
              ) {
                Text("Auto").tag("(auto)")
                ForEach(providersList, id: \.id) { p in
                  Text((p.name?.isEmpty == false ? p.name! : p.id)).tag(p.id)
                }
              }
              .labelsHidden()
              Picker(
                "",
                selection: Binding(
                  get: { modelId ?? "(default)" },
                  set: { newVal in
                    modelId = (newVal == "(default)") ? nil : newVal
                    preferences.commitModelId = modelId
                  }
                )
              ) {
                Text("(default)").tag("(default)")
                ForEach(modelList, id: \.self) { mid in Text(mid).tag(mid) }
              }
              .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          gridDivider
          // Prompt template placed last
          VStack(alignment: .leading, spacing: 0) {
            Text("Commit Message Prompt Template").font(.subheadline).fontWeight(.medium)
            Text(
              "Optional preamble used before the diff when generating commit messages. Leave blank to use the built‑in prompt."
            )
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            TextEditor(text: $draftTemplate)
              .font(.system(.body))
              .frame(height: 320)
              .padding(4)
              .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25))
              )
              .onChange(of: draftTemplate) { newVal in
                preferences.commitPromptTemplate = newVal
              }
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        Spacer(minLength: 0)
      }

      // Repository authorization has moved to on-demand prompts in Review.
      // The settings page no longer manages a global list to reduce clutter.
    }
    .onAppear {
      draftTemplate = preferences.commitPromptTemplate
      providerId = preferences.commitProviderId
      Task {
        // Only show user-added providers to avoid confusion
        let list = await ProvidersRegistryService().listProviders()
        providersList = list
        modelList = modelsForCurrentProvider()
        modelId = preferences.commitModelId
      }
    }
  }

  @ViewBuilder
  private var gridDivider: some View {
    Divider()
  }

  private func modelsForCurrentProvider() -> [String] {
    guard let pid = providerId, let p = providersList.first(where: { $0.id == pid }) else {
      return []
    }
    let ids = (p.catalog?.models ?? []).map { $0.vendorModelId }
    return ids
  }
}

// Authorized repositories list has been removed from Settings.
