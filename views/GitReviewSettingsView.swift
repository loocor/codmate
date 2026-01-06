import SwiftUI

struct GitReviewSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore

  @StateObject private var providerCatalog = UnifiedProviderCatalogModel()
  @State private var draftTemplate: String = ""
  @State private var providerId: String? = nil
  @State private var modelId: String? = nil
  @State private var modelList: [String] = []
  @State private var lastProviderId: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Git Review Settings").font(.title2).fontWeight(.bold)
        Text("Customize Git changes viewer and AI commit generation.")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("Display").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Show Line Numbers", systemImage: "list.number")
                  .font(.subheadline).fontWeight(.medium)
                Text("Show line numbers in diffs.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Toggle("", isOn: $preferences.gitShowLineNumbers)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Wrap Long Lines", systemImage: "text.line.first.and.arrowtriangle.forward")
                  .font(.subheadline).fontWeight(.medium)
                Text("Enable soft wrap in diff viewer.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Toggle("", isOn: $preferences.gitWrapText)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("Generate").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Commit Model", systemImage: "brain")
                  .font(.subheadline).fontWeight(.medium)
                Text("Select a model from Auto-Proxy mode.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              // Model picker with sanitized names and provider icons
              SimpleModelPicker(
                models: modelList,
                isDisabled: !providerCatalog.isProviderAvailable(providerId),
                providerId: providerId,
                providerCatalog: providerCatalog,
                modelId: $modelId
              )
              .frame(maxWidth: .infinity, alignment: .trailing)
              .onChange(of: modelId) { newVal in
                preferences.commitModelId = newVal
              }
            }
            gridDivider
            // Prompt template placed last
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Commit Message Prompt Template", systemImage: "text.bubble")
                  .font(.subheadline).fontWeight(.medium)
                Text(
                  "Optional preamble used before the diff when generating commit messages. Leave blank to use the built‑in prompt."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
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
              .gridCellColumns(2)
            }
          }
        }
      }

      // Repository authorization has moved to on-demand prompts in Review.
      // The settings page no longer manages a global list to reduce clutter.
    }
    .onAppear {
      draftTemplate = preferences.commitPromptTemplate
      providerId = preferences.commitProviderId
      modelId = preferences.commitModelId
      Task { await reloadCatalog() }
    }
    // Removed rerouteBuiltIn/reroute3P onChange handlers - all providers now use Auto-Proxy mode
    .onChange(of: preferences.oauthProvidersEnabled) { _ in
      Task { await reloadCatalog() }
    }
    .onChange(of: preferences.apiKeyProvidersEnabled) { _ in
      Task { await reloadCatalog() }
    }
    .onChange(of: CLIProxyService.shared.isRunning) { _ in
      Task { await reloadCatalog() }
    }
  }

  @ViewBuilder
  private var gridDivider: some View {
    Divider()
  }

  @ViewBuilder
  private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(10)
    .background(Color(nsColor: .separatorColor).opacity(0.35))
    .cornerRadius(10)
  }

  private func reloadCatalog(forceRefresh: Bool = false) async {
    await providerCatalog.reload(preferences: preferences, forceRefresh: forceRefresh)
    normalizeSelection()
  }

  private func normalizeSelection() {
    // Git Review always uses Auto-Proxy mode
    providerId = UnifiedProviderID.autoProxyId
    preferences.commitProviderId = UnifiedProviderID.autoProxyId

    modelList = providerCatalog.models(for: providerId)
    let providerChanged = lastProviderId != nil && lastProviderId != providerId
    lastProviderId = providerId
    if providerChanged {
      modelId = nil
      preferences.commitModelId = nil
      return
    }
    guard !modelList.isEmpty else {
      return
    }
    let current = preferences.commitModelId
    let nextModel = (current != nil && modelList.contains(current ?? "")) ? current : nil
    modelId = nextModel
    if nextModel == nil {
      preferences.commitModelId = nil
    }
  }

}

// Authorized repositories list has been removed from Settings.
