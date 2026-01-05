import SwiftUI

extension GitChangesPanel {
    var leftPane: some View {
        VStack(spacing: 6) {
            // Toolbar - Search fills
            GeometryReader { _ in
                let spacing: CGFloat = 8
                HStack(spacing: spacing) {
                    // Search box expands to fill — match Tasks column styling
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        TextField("Search", text: $treeQuery)
                            .textFieldStyle(.plain)
                        if !treeQuery.isEmpty {
                            Button {
                                treeQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .frame(maxWidth: .infinity)

                    // Collapse/Expand buttons (shared styling with Tasks column)
                    CollapseExpandButtonGroup(
                        onCollapse: {
                            if mode == .browser {
                                expandedDirsBrowser.removeAll()
                            } else {
                                expandedDirsStaged.removeAll()
                                expandedDirsUnstaged.removeAll()
                            }
                        },
                        onExpand: {
                            if mode == .browser {
                                expandedDirsBrowser = Set(allDirectoryKeys(nodes: browserNodes))
                            } else {
                                expandedDirsStaged = Set(allDirectoryKeys(nodes: cachedNodesStaged))
                                expandedDirsUnstaged = Set(allDirectoryKeys(nodes: cachedNodesUnstaged))
                            }
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 32)

            // Inline commit message (one line, auto-grow; no button)
            // Show in Diff and History (graph) modes; hide in Explorer.
            if mode != .browser {
                GeometryReader { gr in
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $vm.commitMessage)
                            .font(.system(.body))
                            .codmatePlainTextEditorStyleIfAvailable()
                            .frame(minHeight: 20)
                            .frame(height: min(200, max(20, commitInlineHeight)))
                            .padding(.leading, 6)
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                            .padding(.trailing, wandReservedTrailing)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25))
                            )
                        .onChange(of: vm.commitMessage, initial: true) { _ in
                            // account for trailing reserve space
                            let w = max(10, gr.size.width - 12 - wandReservedTrailing)
                            commitInlineHeight = measureCommitHeight(vm.commitMessage, width: w)
                        }
                        if vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Press Command+Return to commit")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }

                        // Wand button at top-right of the commit message box
                        HStack { Spacer() }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    vm.generateCommitMessage(providerId: preferences.commitProviderId, modelId: preferences.commitModelId)
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(hoverWand ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .frame(width: wandButtonSize, height: wandButtonSize)
                                .contentShape(Rectangle())
                                .padding(.top, 4) // keep top-anchored; don't move when TextEditor grows
                                .padding(.trailing, 4)
                                .onHover { hoverWand = $0 }
                                .opacity((vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path) ? 0.4 : 1.0)
                                .animation((vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path) ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: vm.isGenerating)
                                .disabled(vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path)
                                .help("AI generate commit message from staged changes")
                            }
                    }
                }
                .frame(height: min(200, max(20, commitInlineHeight)) + 12)
            }

            // Trees in VS Code-style sections
            ScrollView {
                // In History (.graph) we still show the Diff tree list.
                // Only Explorer mode uses the Explorer tree.
                if mode != .browser {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Staged section
                        HStack(spacing: 6) {
                            Button {
                                stagedCollapsed.toggle()
                            } label: {
                                Image(systemName: stagedCollapsed ? "chevron.right" : "chevron.down")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .frame(width: chevronWidth)
                            Text("Staged Changes (\(vm.changes.filter { $0.staged != nil }.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { stagedCollapsed.toggle() }
                        .onHover { hoverStagedHeader = $0 }
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoverStagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                        )
                        .frame(height: 22)
                        .contextMenu {
                            Button {
                                let paths = allPaths(in: .staged)
                                Task { await vm.unstage(paths: paths) }
                            } label: {
                                Label("Unstage All", systemImage: "minus.circle")
                            }
                        }
                        if !stagedCollapsed {
                            treeRows(nodes: displayedStaged, depth: 1, scope: .staged)
                        }

                        // Unstaged section
                        HStack(spacing: 6) {
                            Button { unstagedCollapsed.toggle() } label: {
                                Image(systemName: unstagedCollapsed ? "chevron.right" : "chevron.down")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .frame(width: chevronWidth)
                            // Show all files with worktree changes, even if they also have staged changes (MM)
                            Text("Changes (\(vm.changes.filter { $0.worktree != nil }.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { unstagedCollapsed.toggle() }
                        .onHover { hoverUnstagedHeader = $0 }
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoverUnstagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                        )
                        .frame(height: 22)
                        .contextMenu {
                            Button {
                                let paths = allPaths(in: .unstaged)
                                Task { await vm.stage(paths: paths) }
                            } label: {
                                Label("Stage All", systemImage: "plus.circle")
                            }
                        }
                        if !unstagedCollapsed {
                            treeRows(nodes: displayedUnstaged, depth: 1, scope: .unstaged)
                        }
                    }
                } else {
                    browserTreeView
                }
            }
            // Provide a generic context menu on empty area as well
            .contextMenu {
                Button {
                    let paths = allPaths(in: .unstaged)
                    Task { await vm.stage(paths: paths) }
                } label: {
                    Label("Stage All", systemImage: "plus.circle")
                }
                Button {
                    let paths = allPaths(in: .staged)
                    Task { await vm.unstage(paths: paths) }
                } label: {
                    Label("Unstage All", systemImage: "minus.circle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Add inner padding to prevent controls from hugging edges
        .padding(16)
    }
}
