import SwiftUI

@available(macOS 15.0, *)
struct MCPServerTargetToggle: View {
    let provider: UsageProviderKind
    @Binding var isOn: Bool
    var disabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            if !disabled {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                providerIcon
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    @ViewBuilder
    private var providerIcon: some View {
        let active = isOn && !disabled
        if let name = iconName(for: provider) {
            Image(name)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .modifier(DarkModeInvertModifier(active: provider == .codex && colorScheme == .dark))
                .saturation(active ? 1.0 : 0.0)
                .opacity(active ? 1.0 : 0.2)
        } else {
            Circle()
                .fill(accent(for: provider))
                .frame(width: 10, height: 10)
                .saturation(isOn && !disabled ? 1.0 : 0.0)
                .opacity(isOn && !disabled ? 1.0 : 0.2)
        }
    }

    private func iconName(for provider: UsageProviderKind) -> String? {
        switch provider {
        case .codex: return "ChatGPTIcon"
        case .claude: return "ClaudeIcon"
        case .gemini: return "GeminiIcon"
        }
    }

    private func accent(for provider: UsageProviderKind) -> Color {
        switch provider {
        case .codex: return Color.accentColor
        case .claude: return Color(nsColor: .systemPurple)
        case .gemini: return Color(nsColor: .systemTeal)
        }
    }

    private var helpText: String {
        let name = provider.displayName
        if disabled {
            return "\(name) integration (server disabled)"
        }
        return isOn ? "Disable for \(name)" : "Enable for \(name)"
    }
}
