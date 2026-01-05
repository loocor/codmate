import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ClaudeModelMappingSheet: View {
  let availableModels: [String]
  let defaultModel: String?
  let aliases: [String: String]
  let providerId: String?
  let providerCatalog: UnifiedProviderCatalogModel?
  let onSave: (_ defaultModel: String?, _ aliases: [String: String]) -> Void
  let onAutoFill: (_ selectedDefault: String?) -> [String: String]

  @State private var draftDefault: String = ""
  @State private var draftAliases: [String: String] = [:]
  @Environment(\.dismiss) private var dismiss

  init(
    availableModels: [String],
    defaultModel: String?,
    aliases: [String: String],
    providerId: String? = nil,
    providerCatalog: UnifiedProviderCatalogModel? = nil,
    onSave: @escaping (_ defaultModel: String?, _ aliases: [String: String]) -> Void,
    onAutoFill: @escaping (_ selectedDefault: String?) -> [String: String]
  ) {
    self.availableModels = availableModels
    self.defaultModel = defaultModel
    self.aliases = aliases
    self.providerId = providerId
    self.providerCatalog = providerCatalog
    self.onSave = onSave
    self.onAutoFill = onAutoFill
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
    .onAppear {
      // Reload data when sheet appears to ensure we have the latest values
      // This is critical for SwiftUI sheets which capture initial values at creation time
      // and may not reflect updates that happen after the sheet closure is created
      draftDefault = defaultModel ?? ""
      draftAliases = aliases
    }
  }

  @State private var searchText: [String: String] = [:]
  @State private var isPopoverPresented: [String: Bool] = [:]

  private func mappingRow(title: String, help: String, binding: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(title)
          .frame(width: 90, alignment: .leading)
        TextField("model-id", text: binding)
        if !availableModels.isEmpty {
          searchableModelButton(binding: binding, title: title)
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

  private func searchableModelButton(binding: Binding<String>, title: String) -> some View {
    let searchKey = title
    let isPresented = Binding(
      get: { isPopoverPresented[searchKey] ?? false },
      set: { isPopoverPresented[searchKey] = $0 }
    )
    let searchBinding = Binding(
      get: { searchText[searchKey] ?? "" },
      set: { searchText[searchKey] = $0 }
    )

    return Button {
      isPresented.wrappedValue = true
    } label: {
      Image(systemName: "chevron.down")
    }
    .help("Pick from available models")
    .popover(isPresented: isPresented, arrowEdge: .bottom) {
      searchableModelListPopover(
        binding: binding,
        searchKey: searchKey,
        searchBinding: searchBinding,
        isPresented: isPresented
      )
    }
  }

  private func searchableModelListPopover(
    binding: Binding<String>,
    searchKey: String,
    searchBinding: Binding<String>,
    isPresented: Binding<Bool>
  ) -> some View {
    let filteredModels = filteredModels(for: searchKey)

    return VStack(alignment: .leading, spacing: 8) {
      // Search field
      TextField("Search models", text: searchBinding)
        .textFieldStyle(.roundedBorder)
        .padding(.top, 16)

      Divider()

      // Model list
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if filteredModels.isEmpty {
            Text("No models found")
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
          } else {
            ForEach(Array(filteredModels.enumerated()), id: \.element) { index, model in
              Button {
                binding.wrappedValue = model
                searchText[searchKey] = ""  // Clear search after selection
                isPresented.wrappedValue = false
              } label: {
                HStack {
                  modelLabelWithProvider(model: model)
                  Spacer()
                  if binding.wrappedValue == model {
                    Image(systemName: "checkmark")
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(
                  Group {
                    if binding.wrappedValue == model {
                      Color.accentColor.opacity(0.1)
                    } else if index % 2 == 1 {
                      Color(nsColor: .separatorColor).opacity(0.08)
                    } else {
                      Color.clear
                    }
                  }
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(ClaudeModelRowButtonStyle())
              .onHover { hovering in
                #if os(macOS)
                if hovering {
                  NSCursor.pointingHand.push()
                } else {
                  NSCursor.pop()
                }
                #endif
              }
            }
          }
        }
      }
      .frame(width: 400, height: 300)
    }
    .padding(.bottom, 16)
    .padding(.horizontal, 16)
  }

  @ViewBuilder
  private func modelLabelWithProvider(model: String) -> some View {
    HStack(spacing: 6) {
      if let providerId = providerId, let catalog = providerCatalog {
        modelLabelProviderInfo(model: model, providerId: providerId, catalog: catalog)
      }
      Text(ModelNameSanitizer.sanitizeSingle(model))
    }
  }

  @ViewBuilder
  private func modelLabelProviderInfo(model: String, providerId: String, catalog: UnifiedProviderCatalogModel) -> some View {
    // When providerId is autoProxy, infer provider from model ID
    if providerId == UnifiedProviderID.autoProxyId {
      // Infer provider from model ID
      if let title = catalog.inferProviderFromModel(model) {
        if let icon = providerIcon(for: nil, title: title, modelId: model) {
          icon
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
        } else {
          Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(nsColor: .separatorColor).opacity(0.5))
            .cornerRadius(3)
        }
      }
    } else {
      // Use provider title from catalog
      if let title = catalog.providerTitle(for: providerId) {
        if let icon = providerIcon(for: providerId, title: title, modelId: model) {
          icon
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 14, height: 14)
        } else {
          Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(nsColor: .separatorColor).opacity(0.5))
            .cornerRadius(3)
        }
      }
    }
  }

  private func providerIcon(for providerId: String?, title: String, modelId: String? = nil) -> Image? {
    // If providerId is nil (autoProxy mode), try to infer from modelId
    if providerId == nil || providerId == UnifiedProviderID.autoProxyId {
      if let modelId = modelId, let builtin = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesModelId(modelId) }) {
        let authProvider = UnifiedProviderID.authProvider(for: builtin)
        if let authProvider = authProvider {
          let iconName = iconNameForOAuthProvider(authProvider)
          if let nsImage = ProviderIconThemeHelper.menuImage(named: iconName, size: NSSize(width: 14, height: 14)) {
            return Image(nsImage: nsImage)
          }
        }
      }
      // Try to match by title
      if let authProvider = LocalAuthProvider.allCases.first(where: { $0.displayName == title }) {
        let iconName = iconNameForOAuthProvider(authProvider)
        if let nsImage = ProviderIconThemeHelper.menuImage(named: iconName, size: NSSize(width: 14, height: 14)) {
          return Image(nsImage: nsImage)
        }
      }
      // Try API key provider icon
      if let iconName = ProviderIconResource.iconName(for: title),
         let nsImage = ProviderIconResource.processedImage(
           named: iconName,
           size: NSSize(width: 14, height: 14),
           isDarkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
         ) {
        return Image(nsImage: nsImage)
      }
      return nil
    }

    let parsed = UnifiedProviderID.parse(providerId ?? "")
    switch parsed {
    case .oauth(let authProvider, _):
      let iconName = iconNameForOAuthProvider(authProvider)
      if let nsImage = ProviderIconThemeHelper.menuImage(named: iconName, size: NSSize(width: 14, height: 14)) {
        return Image(nsImage: nsImage)
      }
      return nil
    case .api(let apiId):
      if let iconName = ProviderIconResource.iconName(for: apiId) ?? ProviderIconResource.iconName(for: title),
         let nsImage = ProviderIconResource.processedImage(
           named: iconName,
           size: NSSize(width: 14, height: 14),
           isDarkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
         ) {
        return Image(nsImage: nsImage)
      }
      return nil
    default:
      return nil
    }
  }

  private func iconNameForOAuthProvider(_ provider: LocalAuthProvider) -> String {
    switch provider {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    case .antigravity: return "AntigravityIcon"
    case .qwen: return "QwenIcon"
    }
  }

  private func filteredModels(for searchKey: String) -> [String] {
    let query = (searchText[searchKey] ?? "").lowercased()
    if query.isEmpty {
      return availableModels
    }
    return availableModels.filter { model in
      let display = ModelNameSanitizer.sanitizeSingle(model).lowercased()
      return display.contains(query) || model.lowercased().contains(query)
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

// MARK: - Model Row Button Style
private struct ClaudeModelRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        configuration.isPressed || configuration.role == .destructive
          ? Color(nsColor: .controlAccentColor).opacity(0.2)
          : Color.clear
      )
      .contentShape(Rectangle())
  }
}
