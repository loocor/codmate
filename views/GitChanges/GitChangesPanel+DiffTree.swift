import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension GitChangesPanel {
    @ViewBuilder
    func treeRows(nodes: [FileNode], depth: Int, scope: TreeScope) -> some View {
        ForEach(nodes) { node in
            if node.isDirectory {
                // Directory row with VS Code-style layout
                let key = node.dirPath ?? ""
                let hoverKey = scopedHoverKey(for: key, scope: scope)
                let isExpanded: Bool = {
                    switch scope {
                    case .staged: return expandedDirsStaged.contains(key)
                    case .unstaged: return expandedDirsUnstaged.contains(key)
                    }
                }()
                HStack(spacing: 0) {
                    // Indentation guides (vertical lines)
                    ZStack(alignment: .leading) {
                        Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
                        let guideColor = Color.secondary.opacity(0.15)
                        ForEach(0..<depth, id: \.self) { i in
                            Rectangle().fill(guideColor).frame(width: 1)
                                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
                        }
                        // Chevron (disclosure triangle)
                        HStack(spacing: 0) {
                            Spacer().frame(width: CGFloat(depth) * indentStep)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: chevronWidth, height: 20)
                        }
                    }
                    // Folder icon and name
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, (hoverDirKey == hoverKey) ? (quickActionWidth + trailingPad) : trailingPad)
                    .overlay(alignment: .trailing) {
                        if let dir = node.dirPath {
                            let dirHoverKey = scopedHoverKey(for: dir, scope: scope)
                            HStack(spacing: hoverButtonSpacing) {
                                Button(action: {
                                    Task {
                                        let paths = filePaths(under: dir)
                                        guard !paths.isEmpty else { return }
                                        if scope == .staged { await vm.unstage(paths: paths) }
                                        else { await vm.stage(paths: paths) }
                                    }
                                }) {
                                    Image(systemName: scope == .staged ? "minus.circle" : "plus.circle")
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverDirButtonPath = dirHoverKey } else if hoverDirButtonPath == dirHoverKey { hoverDirButtonPath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)
                            }
                            .foregroundStyle((hoverDirButtonPath == dirHoverKey) ? Color.accentColor : Color.secondary)
                            .opacity((hoverDirKey == dirHoverKey) ? 1 : 0)
                        }
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill((hoverDirKey == hoverKey) ? Color.secondary.opacity(0.06) : Color.clear)
                )
                .onTapGesture {
                    if let k = node.dirPath {
                        switch scope {
                        case .staged:
                            if expandedDirsStaged.contains(k) { expandedDirsStaged.remove(k) } else { expandedDirsStaged.insert(k) }
                        case .unstaged:
                            if expandedDirsUnstaged.contains(k) { expandedDirsUnstaged.remove(k) } else { expandedDirsUnstaged.insert(k) }
                        }
                    }
                }
                .onHover { inside in
                    if let key = node.dirPath {
                        let dirHover = scopedHoverKey(for: key, scope: scope)
                        if inside { hoverDirKey = dirHover } else if hoverDirKey == dirHover { hoverDirKey = nil }
                    }
                }
                .contextMenu {
                    if let dir = node.dirPath {
                        let allPaths = filePaths(under: dir)
                        if scope == .staged {
                            Button("Unstage Folder") { Task { await vm.unstage(paths: allPaths) } }
                        } else {
                            Button("Stage Folder") { Task { await vm.stage(paths: allPaths) } }
                        }
#if canImport(AppKit)
                        Button("Reveal in Finder") {
                            revealInFinder(path: dir, isDirectory: true)
                        }
#endif
                        if scope == .unstaged {
                            Divider()
                            Button("Discard Folder Changes…", role: .destructive) {
                                pendingDiscardPaths = allPaths
                                pendingDiscardIncludesStaged = false
                                showDiscardAlert = true
                            }
                        }
                    }
                }

                // Expanded children
                if isExpanded {
                    AnyView(treeRows(nodes: node.children ?? [], depth: depth + 1, scope: scope))
                }
            } else {
                // File row
                let path = node.fullPath ?? node.name
                let isSelected = (vm.selectedPath == path) && ((scope == .staged && vm.selectedSide == .staged) || (scope == .unstaged && vm.selectedSide == .unstaged))
                let hoverKey = scopedHoverKey(for: path, scope: scope)
                let quickActionCount = (scope == .staged ? 2 : 3)
                HStack(spacing: 0) {
                    // Indentation guides (vertical lines)
                    ZStack(alignment: .leading) {
                        Color.clear.frame(width: CGFloat(depth) * indentStep + chevronWidth)
                        let guideColor = Color.secondary.opacity(0.15)
                        ForEach(0..<depth, id: \.self) { i in
                            Rectangle().fill(guideColor).frame(width: 1)
                                .offset(x: CGFloat(i) * indentStep + chevronWidth / 2)
                        }
                    }
                    // File icon and name
                    HStack(spacing: 6) {
                        // File type indicator or icon
                        Circle()
                            .fill(statusColor(for: path))
                            .frame(width: 6, height: 6)
                        let icon = fileTypeIconName(for: path)
                        Image(systemName: icon.name)
                            .font(.system(size: 12))
                            .foregroundStyle(icon.color)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(
                        .trailing,
                        (hoverFilePath == hoverKey)
                            ? (statusBadgeWidth + trailingPad + quickActionWidth * CGFloat(quickActionCount) + hoverButtonSpacing * CGFloat(quickActionCount - 1))
                            : (statusBadgeWidth + trailingPad)
                    )
                    .overlay(alignment: .trailing) {
                            HStack(spacing: hoverButtonSpacing) {
                            if hoverFilePath == hoverKey {
                                Button { vm.openFile(path, using: preferences.defaultFileEditor) } label: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle((hoverEditPath == hoverKey) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverEditPath = hoverKey } else if hoverEditPath == hoverKey { hoverEditPath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)

                                if scope == .unstaged {
                                    Button(action: {
                                        pendingDiscardPaths = [path]
                                        pendingDiscardIncludesStaged = false
                                        showDiscardAlert = true
                                    }) {
                                        Image(systemName: "arrow.uturn.backward.circle")
                                            .foregroundStyle((hoverRevertPath == hoverKey) ? Color.red : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { inside in
                                        if inside { hoverRevertPath = hoverKey } else if hoverRevertPath == hoverKey { hoverRevertPath = nil }
                                    }
                                    .frame(width: quickActionWidth, height: quickActionHeight)
                                }

                                Button(action: {
                                    Task {
                                        if scope == .staged { await vm.unstage(paths: [path]) }
                                        else { await vm.stage(paths: [path]) }
                                    }
                                }) {
                                    Image(systemName: scope == .staged ? "minus.circle" : "plus.circle")
                                        .foregroundStyle((hoverStagePath == hoverKey) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { hoverStagePath = hoverKey } else if hoverStagePath == hoverKey { hoverStagePath = nil }
                                }
                                .frame(width: quickActionWidth, height: quickActionHeight)
                            }

                            if let change = vm.changes.first(where: { $0.path == path }) {
                                statusBadge(for: change)
                                    .frame(height: quickActionHeight)
                            }
                        }
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : ((hoverFilePath == hoverKey) ? Color.secondary.opacity(0.06) : Color.clear))
                )
                .onTapGesture {
                    vm.selectedPath = path
                    vm.selectedSide = (scope == .staged ? .staged : .unstaged)
                    // When interacting with the Diff tree (both Diff and History modes),
                    // ensure the right pane shows the Diff reader.
                    if mode != .diff { mode = .diff }
                    if vm.showPreviewInsteadOfDiff { vm.showPreviewInsteadOfDiff = false }
                    Task { await vm.refreshDetail() }
                }
                .onHover { inside in
                    if inside { hoverFilePath = hoverKey } else if hoverFilePath == hoverKey { hoverFilePath = nil }
                }
                .contextMenu {
                    if scope == .staged {
                        Button("Unstage") { Task { await vm.unstage(paths: [path]) } }
                    } else {
                        Button("Stage") { Task { await vm.stage(paths: [path]) } }
                    }
                    Divider()
                    Button("Open in VS Code") { vm.openFile(path, using: .vscode) }
                    Button("Open in Cursor") { vm.openFile(path, using: .cursor) }
                    Button("Open in Zed") { vm.openFile(path, using: .zed) }
                    Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: vm.repoRoot?.appendingPathComponent(path).path ?? path)) }
#if canImport(AppKit)
                    Button("Reveal in Finder") { revealInFinder(path: path, isDirectory: false) }
#endif
                    if scope == .unstaged {
                        Divider()
                        Button("Discard Changes…", role: .destructive) {
                            pendingDiscardPaths = [path]
                            pendingDiscardIncludesStaged = false
                            showDiscardAlert = true
                        }
                    }
                }
            }
        }
    }

    private func scopedHoverKey(for path: String, scope: TreeScope) -> String {
        let prefix = (scope == .staged) ? "S" : "U"
        return "\(prefix)::\(path)"
    }
}
