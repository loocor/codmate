import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Simplified provider picker for CLI settings with only two options:
/// - Default (Built-in): Use CLI's built-in provider
/// - Auto-Proxy (CliProxyAPI): Route through CLI Proxy API
struct SimpleProviderPicker: View {
  let builtInTitle: String
  let autoProxyTitle: String
  let builtInTooltip: String
  let autoProxyTooltip: String

  @Binding var providerId: String?

  private enum ProviderOption: String, CaseIterable {
    case builtIn = "builtIn"
    case autoProxy = "autoProxy"
  }

  private var selection: Binding<ProviderOption> {
    Binding(
      get: {
        providerId == UnifiedProviderID.autoProxyId ? .autoProxy : .builtIn
      },
      set: { newValue in
        providerId = newValue == .autoProxy ? UnifiedProviderID.autoProxyId : nil
      }
    )
  }

  init(
    builtInTitle: String = "Default (Built-in)",
    autoProxyTitle: String = "Auto-Proxy (CliProxyAPI)",
    builtInTooltip: String = "Use CLI's built-in provider configuration",
    autoProxyTooltip: String = "Route all requests through CliProxyAPI for unified provider management",
    providerId: Binding<String?>
  ) {
    self.builtInTitle = builtInTitle
    self.autoProxyTitle = autoProxyTitle
    self.builtInTooltip = builtInTooltip
    self.autoProxyTooltip = autoProxyTooltip
    self._providerId = providerId
  }

  var body: some View {
    Picker("", selection: selection) {
      Text(builtInTitle).tag(ProviderOption.builtIn)
      Text(autoProxyTitle).tag(ProviderOption.autoProxy)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .tint(selection.wrappedValue == .autoProxy ? .red : nil)
    .padding(2)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// Simplified model picker for displaying sanitized model names
/// Supports provider icon/prefix display and searchable menu for long lists
struct SimpleModelPicker: View {
  let models: [String]
  let includeDefault: Bool
  let defaultTitle: String
  let isDisabled: Bool
  let sanitizeNames: Bool
  let onEditModels: (() -> Void)?
  let editModelsHelp: String?
  let providerId: String?
  let providerCatalog: UnifiedProviderCatalogModel?

  @Binding var modelId: String?
  @State private var searchText: String = ""
  @State private var isMenuOpen: Bool = false

  init(
    models: [String],
    includeDefault: Bool = true,
    defaultTitle: String = "(default)",
    isDisabled: Bool = false,
    sanitizeNames: Bool = true,
    onEditModels: (() -> Void)? = nil,
    editModelsHelp: String? = nil,
    providerId: String? = nil,
    providerCatalog: UnifiedProviderCatalogModel? = nil,
    modelId: Binding<String?>
  ) {
    self.models = models
    self.includeDefault = includeDefault
    self.defaultTitle = defaultTitle
    self.isDisabled = isDisabled
    self.sanitizeNames = sanitizeNames
    self.onEditModels = onEditModels
    self.editModelsHelp = editModelsHelp
    self.providerId = providerId
    self.providerCatalog = providerCatalog
    self._modelId = modelId
  }

  private var filteredModels: [String] {
    if searchText.isEmpty {
      return models
    }
    let query = searchText.lowercased()
    return models.filter { model in
      let display = displayName(for: model).lowercased()
      return display.contains(query) || model.lowercased().contains(query)
    }
  }

  private var shouldUseSearchableMenu: Bool {
    models.count > 10  // Use searchable menu for lists with more than 10 items
  }

  var body: some View {
    HStack(spacing: 8) {
      if shouldUseSearchableMenu {
        searchableMenuPicker
      } else {
        standardPicker
      }

      if let onEditModels {
        Button {
          onEditModels()
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .help(editModelsHelp ?? "Edit models")
      }
    }
  }

  private var standardPicker: some View {
    Picker("", selection: $modelId) {
      if includeDefault {
        Text(defaultTitle).tag(String?.none)
      }
      if models.isEmpty {
        // Show a placeholder when models are empty and includeDefault is false
        if !includeDefault {
          Text("(no models available)").tag(String?.none).disabled(true)
        }
      } else {
        ForEach(models, id: \.self) { model in
          modelMenuItem(model: model)
        }
      }
    }
    .labelsHidden()
    .disabled(isDisabled)
  }

  @State private var isSearchPopoverPresented = false

  private var searchableMenuPicker: some View {
    HStack(spacing: 4) {
      Button {
        isSearchPopoverPresented = true
      } label: {
        HStack {
          if let modelId = modelId {
            modelLabel(model: modelId)
          } else {
            Text(defaultTitle)
          }
          Image(systemName: "chevron.down")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
      .disabled(isDisabled)
      .popover(isPresented: $isSearchPopoverPresented, arrowEdge: .bottom) {
        searchableModelListPopover
      }
    }
  }

  private var searchableModelListPopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Search field
      TextField("Search models", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .padding(.top, 16)

      Divider()

      // Model list
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if includeDefault {
            modelRowButton(
              isSelected: modelId == nil,
              action: {
                modelId = nil
                isSearchPopoverPresented = false
              },
              content: {
                HStack {
                  Text(defaultTitle)
                  Spacer()
                  if modelId == nil {
                    Image(systemName: "checkmark")
                  }
                }
              },
              index: 0
            )
          }

          if filteredModels.isEmpty {
            Text("No models found")
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
          } else {
            ForEach(Array(filteredModels.enumerated()), id: \.element) { index, model in
              modelRowButton(
                isSelected: modelId == model,
                action: {
                  modelId = model
                  isSearchPopoverPresented = false
                },
                content: {
                  HStack {
                    modelLabel(model: model)
                    Spacer()
                    if modelId == model {
                      Image(systemName: "checkmark")
                    }
                  }
                },
                index: includeDefault ? index + 1 : index
              )
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
  private func modelRowButton<Content: View>(
    isSelected: Bool,
    action: @escaping () -> Void,
    @ViewBuilder content: () -> Content,
    index: Int
  ) -> some View {
    Button(action: action) {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
                .background(
                  Group {
                    if isSelected {
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
    .buttonStyle(ModelRowButtonStyle())
    .onHover { hovering in
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
  }

  @ViewBuilder
  private func modelMenuItem(model: String) -> some View {
    modelLabel(model: model)
      .tag(String?(model))
  }

  @ViewBuilder
  private func modelLabel(model: String) -> some View {
    HStack(spacing: 6) {
      if let providerId = providerId, let catalog = providerCatalog {
        modelLabelProviderInfo(model: model, providerId: providerId, catalog: catalog)
      }
      Text(displayName(for: model))
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
    // If providerId is nil (autoProxy mode), infer icon from title (service provider name)
    if providerId == nil || providerId == UnifiedProviderID.autoProxyId {
      // Priority 1: Try OAuth provider icon by title
      if let authProvider = LocalAuthProvider.allCases.first(where: { $0.displayName == title }) {
        let iconName = iconNameForOAuthProvider(authProvider)
        if let nsImage = ProviderIconThemeHelper.menuImage(named: iconName, size: NSSize(width: 14, height: 14)) {
          return Image(nsImage: nsImage)
        }
      }
      // Priority 2: Try API key provider icon by title (check customIcon first)
      // Try to find provider by title to check for customIcon
      if let provider = findProviderByTitle(title), let customIcon = provider.customIcon {
        return Image(systemName: customIcon)
      }
      // Priority 3: Try preset PNG icon
      if let iconName = ProviderIconResource.iconName(for: title),
         let nsImage = ProviderIconResource.processedImage(
           named: iconName,
           size: NSSize(width: 14, height: 14),
           isDarkMode: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
         ) {
        return Image(nsImage: nsImage)
      }
      // No fallback - if title doesn't match any known provider, return nil (shows default circle)
      return nil
    }

    let parsed = UnifiedProviderID.parse(providerId ?? "")
    switch parsed {
    case .oauth(let authProvider, _):
      // For OAuth providers, we can use LocalAuthProviderIconView but need to return Image
      // Since we're in a Menu context, we'll use the icon name directly
      let iconName = iconNameForOAuthProvider(authProvider)
      if let nsImage = ProviderIconThemeHelper.menuImage(named: iconName, size: NSSize(width: 14, height: 14)) {
        return Image(nsImage: nsImage)
      }
      return nil
    case .api(let apiId):
      // Priority 1: Check for custom SF Symbol icon
      if let provider = findProviderById(apiId), let customIcon = provider.customIcon {
        return Image(systemName: customIcon)
      }
      // Priority 2: Try preset PNG icon
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

  // Helper to find provider by ID from registry
  private func findProviderById(_ id: String) -> ProvidersRegistryService.Provider? {
    let registry = ProvidersRegistryService()
    // Use synchronous load() instead of async listProviders() to avoid actor isolation warnings
    let loadedRegistry = registry.load()
    return loadedRegistry.providers.first(where: { $0.id == id })
  }

  // Helper to find provider by title/name from registry
  private func findProviderByTitle(_ title: String) -> ProvidersRegistryService.Provider? {
    let registry = ProvidersRegistryService()
    // Use synchronous load() instead of async listProviders() to avoid actor isolation warnings
    let loadedRegistry = registry.load()
    return loadedRegistry.providers.first(where: { provider in
      let displayName = UnifiedProviderID.providerDisplayName(provider)
      return displayName == title || provider.name == title || provider.id == title
    })
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

  private func providerTitle(for providerId: String?) -> String? {
    guard let providerId = providerId else { return nil }
    return providerCatalog?.providerTitle(for: providerId)
  }

  private func displayName(for model: String) -> String {
    if sanitizeNames {
      return ModelNameSanitizer.sanitizeSingle(model)
    }
    return model
  }
}

// MARK: - Model Row Button Style
private struct ModelRowButtonStyle: ButtonStyle {
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
