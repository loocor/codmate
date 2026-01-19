import SwiftUI

/// A reusable tag/chip component that supports closing, enabling/disabling, and custom styling.
struct TagView: View {
    let text: String
    var isEnabled: Bool = true
    var isClosable: Bool = true
    var isRemovable: Bool = true
    var onClose: (() -> Void)? = nil
    var onToggle: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            // Tag text (clickable to toggle if onToggle is provided)
            Text(text)
                .font(.caption)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .monospaced()
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let onToggle = onToggle {
                        onToggle(!isEnabled)
                    }
                }

            // Close button (if closable and removable)
            if isClosable && isRemovable, let onClose = onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .opacity(isHovered ? 1.0 : 0.2)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: isHovered ? 1 : 0)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return Color.secondary.opacity(0.08)
        }
        return Color.accentColor.opacity(isHovered ? 0.15 : 0.12)
    }

    private var borderColor: Color {
        Color.accentColor.opacity(0.3)
    }
}

/// A container view for displaying multiple tags in a flow layout.
struct TagsView: View {
    let tags: [TagItem]
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        FlowLayout(spacing: spacing, alignment: alignment) {
            ForEach(tags.indices, id: \.self) { index in
                TagView(
                    text: tags[index].text,
                    isEnabled: tags[index].isEnabled,
                    isClosable: tags[index].isClosable,
                    isRemovable: tags[index].isRemovable,
                    onClose: tags[index].onClose,
                    onToggle: tags[index].onToggle
                )
            }
        }
    }
}

/// Data model for a tag item.
struct TagItem: Identifiable {
    let id: String
    let text: String
    var isEnabled: Bool = true
    var isClosable: Bool = true
    var isRemovable: Bool = true
    var onClose: (() -> Void)? = nil
    var onToggle: ((Bool) -> Void)? = nil

    init(
        id: String? = nil,
        text: String,
        isEnabled: Bool = true,
        isClosable: Bool = true,
        isRemovable: Bool = true,
        onClose: (() -> Void)? = nil,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        self.id = id ?? text
        self.text = text
        self.isEnabled = isEnabled
        self.isClosable = isClosable
        self.isRemovable = isRemovable
        self.onClose = onClose
        self.onToggle = onToggle
    }
}

/// A simple flow layout that wraps items to multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 10000  // Use a large default if unspecified
        let result = FlowResult(
            in: maxWidth,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.frames[index].minX,
                    y: bounds.minY + result.frames[index].minY),
                proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for (_, subview) in subviews.enumerated() {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > maxWidth && currentX > 0 {
                    // Start a new line
                    currentY += lineHeight + spacing
                    currentX = 0
                    lineHeight = 0
                }

                frames.append(
                    CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }

            self.size = CGSize(
                width: maxWidth,
                height: currentY + lineHeight
            )
        }
    }
}
