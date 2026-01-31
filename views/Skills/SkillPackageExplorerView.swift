import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

struct SkillPackageExplorerView: View {
  let skill: SkillSummary
  var onReveal: () -> Void
  var onUninstall: () -> Void
  var showsHeader: Bool = true
  var showsActions: Bool = true

  @State private var treeQuery: String = ""
  @State private var expandedDirs: Set<String> = []
  @State private var nodes: [GitReviewNode] = []
  @State private var displayedRows: [BrowserRow] = []
  @State private var isLoading: Bool = false
  @State private var treeError: String? = nil
  @State private var treeTruncated: Bool = false
  @State private var totalEntries: Int = 0
  @State private var selectedPath: String? = nil
  @State private var previewText: String = ""
  @State private var previewError: String? = nil
  #if canImport(AppKit)
    @State private var previewImage: NSImage? = nil
  #endif
  @State private var previewTask: Task<Void, Never>? = nil
  @State private var reloadToken: UUID = UUID()

  private let indentStep: CGFloat = 16
  private let chevronWidth: CGFloat = 16
  private let rowHeight: CGFloat = 22
  private let browserEntryLimit: Int = 4000

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if showsHeader {
        header
      }
      HStack(alignment: .top, spacing: 12) {
        fileTree
          .frame(minWidth: 240, maxWidth: 280, maxHeight: .infinity)
        previewPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { reloadTree(force: true) }
    .onChange(of: skill.id) { _ in
      treeQuery = ""
      expandedDirs = []
      nodes = []
      displayedRows = []
      treeTruncated = false
      totalEntries = 0
      treeError = nil
      selectedPath = nil
      previewText = ""
      previewError = nil
      previewTask?.cancel()
      #if canImport(AppKit)
        previewImage = nil
      #endif
      reloadToken = UUID()
      reloadTree(force: true)
    }
    .onChange(of: treeQuery) { _ in rebuildDisplayed() }
    .onChange(of: selectedPath) { _ in loadPreview() }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(skill.displayName)
          .font(.title3.weight(.semibold))
        Text(skill.description.isEmpty ? skill.summary : skill.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if showsActions {
        HStack(spacing: 8) {
          Button {
            onReveal()
          } label: {
            Image(systemName: "finder")
          }
          .buttonStyle(.borderless)
          .help("Reveal in Finder")
          Button(role: .destructive) {
            onUninstall()
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Move to Trash")
        }
      }
    }
  }

  private var fileTree: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        ToolbarSearchField(
          placeholder: "Search files",
          text: $treeQuery,
          onFocusChange: { _ in },
          onSubmit: {}
        )
        .frame(maxWidth: .infinity)
        Button {
          collapseAll()
        } label: {
          Image(systemName: "arrow.up.right.and.arrow.down.left")
        }
        .buttonStyle(.borderless)
        .help("Expand all")
        Button {
          expandAll()
        } label: {
          Image(systemName: "arrow.down.left.and.arrow.up.right")
        }
        .buttonStyle(.borderless)
        .help("Collapse all")
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if isLoading {
            HStack(spacing: 8) {
              ProgressView()
              Text("Loading files…")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
          } else if let error = treeError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 6)
          } else if displayedRows.isEmpty {
            Text(
              treeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No files." : "No matches."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
          } else {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(displayedRows) { row in
                browserRow(row)
              }
            }
          }
        }
      }

      if treeTruncated {
        Text("Showing first \(browserEntryLimit) files. Narrow search to see more.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if !isLoading, treeError == nil, totalEntries > 0 {
        Text("\(totalEntries)\(treeTruncated ? "+" : "") items")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private var previewPane: some View {
    Group {
      #if canImport(AppKit)
        if let img = previewImage {
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: img)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding(12)
          }
        } else {
          previewTextView
        }
      #else
        previewTextView
      #endif
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private var previewTextView: some View {
    let emptyText: String = {
      if let error = previewError, !error.isEmpty { return error }
      return selectedPath == nil ? "Select a file to preview." : "(Empty preview)"
    }()
    return AttributedTextView(
      text: previewText.isEmpty ? emptyText : previewText,
      isDiff: false,
      wrap: false,
      showLineNumbers: true,
      fontSize: 12,
      searchQuery: ""
    )
  }

  private func browserRow(_ row: BrowserRow) -> some View {
    if row.node.isDirectory {
      return AnyView(directoryRow(row))
    }
    return AnyView(fileRow(row))
  }

  private func directoryRow(_ row: BrowserRow) -> some View {
    let key = row.directoryKey ?? row.node.name
    let indent = CGFloat(max(row.depth, 0)) * indentStep
    let isExpanded =
      !treeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || expandedDirs.contains(key)
    return HStack(spacing: 0) {
      ZStack(alignment: .leading) {
        Color.clear.frame(width: indent + chevronWidth)
        if row.depth > 0 {
          let guideColor = Color.secondary.opacity(0.15)
          ForEach(0..<row.depth, id: \.self) { idx in
            Rectangle()
              .fill(guideColor)
              .frame(width: 1)
              .offset(x: CGFloat(idx) * indentStep + chevronWidth / 2)
          }
        }
        HStack(spacing: 0) {
          Spacer().frame(width: indent)
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: chevronWidth, height: rowHeight)
        }
      }
      HStack(spacing: 6) {
        Image(systemName: "folder")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Text(row.node.name)
          .font(.system(size: 13))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.trailing, 8)
    }
    .frame(height: rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { toggleDirectory(key) }
    .contextMenu {
      #if canImport(AppKit)
        Button("Reveal in Finder") { revealPath(path: key, isDirectory: true) }
      #endif
    }
  }

  private func fileRow(_ row: BrowserRow) -> some View {
    guard let path = row.filePath else { return AnyView(EmptyView()) }
    let indent = CGFloat(max(row.depth, 0)) * indentStep
    let isSelected = selectedPath == path
    let icon = GitFileIcon.icon(for: path)
    let bg = isSelected ? Color.accentColor.opacity(0.12) : Color.clear
    return AnyView(
      HStack(spacing: 0) {
        ZStack(alignment: .leading) {
          Color.clear.frame(width: indent)
          if row.depth > 0 {
            let guideColor = Color.secondary.opacity(0.15)
            ForEach(0..<row.depth, id: \.self) { idx in
              Rectangle()
                .fill(guideColor)
                .frame(width: 1)
                .offset(x: CGFloat(idx) * indentStep - indentStep / 2)
            }
          }
        }
        .frame(width: indent)
        HStack(spacing: 6) {
          Image(systemName: icon.name)
            .font(.system(size: 12))
            .foregroundStyle(icon.color)
          Text(row.node.name)
            .font(.system(size: 13))
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
      }
      .frame(height: rowHeight)
      .contentShape(Rectangle())
      .background(RoundedRectangle(cornerRadius: 4).fill(bg))
      .onTapGesture { selectedPath = path }
      .contextMenu {
        #if canImport(AppKit)
          Button("Reveal in Finder") { revealPath(path: path, isDirectory: false) }
        #endif
      }
    )
  }

  private func reloadTree(force: Bool = false) {
    guard let rootURL = skill.path.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
      nodes = []
      displayedRows = []
      treeError = "Skill folder not found."
      isLoading = false
      return
    }
    if !force, !nodes.isEmpty { return }
    if !FileManager.default.fileExists(atPath: rootURL.path) {
      nodes = []
      displayedRows = []
      treeError = "Skill folder not found."
      isLoading = false
      return
    }
    isLoading = true
    treeError = nil
    let limit = browserEntryLimit
    let token = reloadToken
    let skillPath = rootURL.path
    Task {
      let result = buildBrowserTreeFromFileSystem(root: rootURL, limit: limit)
      await MainActor.run {
        guard token == reloadToken,
          skill.path == skillPath
        else { return }
        isLoading = false
        if let error = result.error, result.nodes.isEmpty {
          treeError = error
          nodes = []
          displayedRows = []
          treeTruncated = false
          totalEntries = 0
        } else {
          treeError = nil
          nodes = GitReviewTreeBuilder.explorerSort(result.nodes)
          treeTruncated = result.truncated
          totalEntries = result.total
          rebuildDisplayed()
          if selectedPath == nil {
            let skillFile = rootURL.appendingPathComponent("SKILL.md")
            if FileManager.default.fileExists(atPath: skillFile.path) {
              selectedPath = "SKILL.md"
            }
          }
        }
      }
    }
  }

  private func rebuildDisplayed() {
    let query = treeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = query.isEmpty ? nodes : filteredNodes(nodes, query: query)
    displayedRows = flattenBrowserNodes(filtered, depth: 0, forceExpand: !query.isEmpty)
  }

  private func expandAll() {
    expandedDirs = Set(allDirectoryKeys(nodes))
    rebuildDisplayed()
  }

  private func collapseAll() {
    expandedDirs.removeAll()
    rebuildDisplayed()
  }

  private func allDirectoryKeys(_ nodes: [GitReviewNode]) -> [String] {
    var keys: [String] = []
    func walk(_ ns: [GitReviewNode]) {
      for node in ns {
        if let dir = node.dirPath {
          keys.append(dir)
          if let children = node.children { walk(children) }
        }
      }
    }
    walk(nodes)
    return keys
  }

  private func filteredNodes(_ nodes: [GitReviewNode], query: String) -> [GitReviewNode] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return nodes }
    func filter(_ ns: [GitReviewNode]) -> [GitReviewNode] {
      var out: [GitReviewNode] = []
      for n in ns {
        if n.isDirectory {
          let kids = n.children.map(filter) ?? []
          if n.name.localizedCaseInsensitiveContains(q) || !kids.isEmpty {
            var dir = n
            dir.children = kids
            out.append(dir)
          }
        } else if let p = n.fullPath {
          if n.name.localizedCaseInsensitiveContains(q) || p.localizedCaseInsensitiveContains(q) {
            out.append(n)
          }
        }
      }
      return out
    }
    return filter(nodes)
  }

  private func flattenBrowserNodes(_ nodes: [GitReviewNode], depth: Int, forceExpand: Bool)
    -> [BrowserRow]
  {
    var rows: [BrowserRow] = []
    for node in nodes {
      rows.append(BrowserRow(node: node, depth: depth))
      if node.isDirectory, let key = node.dirPath ?? (depth == 0 ? node.name : nil) {
        if forceExpand || expandedDirs.contains(key) {
          let children = GitReviewTreeBuilder.explorerSort(node.children ?? [])
          rows.append(
            contentsOf: flattenBrowserNodes(children, depth: depth + 1, forceExpand: forceExpand))
        }
      }
    }
    return rows
  }

  private func toggleDirectory(_ key: String) {
    if expandedDirs.contains(key) {
      expandedDirs.remove(key)
    } else {
      expandedDirs.insert(key)
    }
    rebuildDisplayed()
  }

  private func buildBrowserTreeFromFileSystem(root: URL, limit: Int) -> (
    nodes: [GitReviewNode], truncated: Bool, total: Int, error: String?
  ) {
    let (paths, truncated, error) = collectFileSystemPaths(root: root, limit: limit)
    if paths.isEmpty {
      return ([], truncated, 0, error ?? "Unable to enumerate skill files.")
    }
    let nodes = buildBrowserTreeFromPaths(paths)
    return (nodes, truncated, paths.count, error)
  }

  private func collectFileSystemPaths(root: URL, limit: Int) -> ([String], Bool, String?) {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
    var encounteredError: String?
    let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
    guard
      let enumerator = fm.enumerator(
        at: root, includingPropertiesForKeys: keys, options: options,
        errorHandler: { _, error in
          encounteredError = error.localizedDescription
          return true
        })
    else {
      return ([], false, "Unable to enumerate skill files.")
    }

    let rootResolved = root.resolvingSymlinksInPath()
    let base = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
    var collected: [String] = []
    var truncated = false

    while let item = enumerator.nextObject() as? URL {
      let itemPath = item.resolvingSymlinksInPath().path
      guard itemPath.hasPrefix(base) else { continue }
      let relative = String(itemPath.dropFirst(base.count))
      if relative.isEmpty { continue }
      if relative == ".codmate.json" || relative.hasSuffix("/.codmate.json") { continue }
      if relative == ".git" || relative.hasPrefix(".git/") {
        enumerator.skipDescendants()
        continue
      }
      if let values = try? item.resourceValues(forKeys: Set(keys)), values.isDirectory == true {
        continue
      }
      collected.append(relative)
      if collected.count >= limit {
        truncated = true
        break
      }
    }
    return (collected, truncated, encounteredError)
  }

  private func buildBrowserTreeFromPaths(_ paths: [String]) -> [GitReviewNode] {
    struct Builder {
      var children: [String: Builder] = [:]
      var filePath: String? = nil
    }
    var root = Builder()
    for path in paths {
      let components = path.split(separator: "/").map(String.init)
      guard !components.isEmpty else { continue }
      func insert(_ index: Int, current: inout Builder) {
        let key = components[index]
        if index == components.count - 1 {
          var child = current.children[key, default: Builder()]
          child.filePath = path
          current.children[key] = child
        } else {
          var child = current.children[key, default: Builder()]
          insert(index + 1, current: &child)
          current.children[key] = child
        }
      }
      insert(0, current: &root)
    }
    func convert(_ builder: Builder, prefix: String?) -> [GitReviewNode] {
      var nodes: [GitReviewNode] = []
      for (name, child) in builder.children {
        let fullPath = prefix.map { "\($0)/\(name)" } ?? name
        if let filePath = child.filePath, child.children.isEmpty {
          nodes.append(GitReviewNode(name: name, fullPath: filePath, dirPath: nil, children: nil))
        } else {
          let childrenNodes = convert(child, prefix: fullPath)
          nodes.append(
            GitReviewNode(
              name: name,
              fullPath: nil,
              dirPath: fullPath,
              children: GitReviewTreeBuilder.explorerSort(childrenNodes)
            )
          )
        }
      }
      return GitReviewTreeBuilder.explorerSort(nodes)
    }
    return convert(root, prefix: nil)
  }

  private func loadPreview() {
    previewTask?.cancel()
    let token = reloadToken
    previewTask = Task {
      guard let root = skill.path.map({ URL(fileURLWithPath: $0, isDirectory: true) }),
        let path = selectedPath
      else {
        await MainActor.run {
          previewText = ""
          previewError = nil
          #if canImport(AppKit)
            previewImage = nil
          #endif
        }
        return
      }
      let fileURL = root.appendingPathComponent(path)
      if isImagePath(path) {
        #if canImport(AppKit)
          let img = NSImage(contentsOf: fileURL)
          await MainActor.run {
            guard token == reloadToken else { return }
            previewImage = img
            previewText = ""
            previewError = img == nil ? "Unable to load image." : nil
          }
        #else
          await MainActor.run {
            guard token == reloadToken else { return }
            previewText = "Image preview not supported."
            previewError = nil
          }
        #endif
        return
      }

      do {
        let handle = try FileHandle(forReadingFrom: fileURL)
        let data = try handle.read(upToCount: 256_000) ?? Data()
        try? handle.close()
        if let text = String(data: data, encoding: .utf8) {
          await MainActor.run {
            #if canImport(AppKit)
              guard token == reloadToken else { return }
              previewImage = nil
            #endif
            previewText = text
            previewError = text.isEmpty ? "(Empty file)" : nil
          }
        } else {
          await MainActor.run {
            #if canImport(AppKit)
              guard token == reloadToken else { return }
              previewImage = nil
            #endif
            previewText = ""
            previewError = "Binary or unsupported file."
          }
        }
      } catch {
        await MainActor.run {
          #if canImport(AppKit)
            guard token == reloadToken else { return }
            previewImage = nil
          #endif
          previewText = ""
          previewError = "Unable to read file."
        }
      }
    }
  }

  private func isImagePath(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    return ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"].contains(ext)
  }

  #if canImport(AppKit)
    private func revealPath(path: String, isDirectory: Bool) {
      guard let root = skill.path.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
        return
      }
      let target = root.appendingPathComponent(path)
      if isDirectory {
        NSWorkspace.shared.open(target)
      } else {
        NSWorkspace.shared.activateFileViewerSelecting([target])
      }
    }
  #endif
}

private struct BrowserRow: Identifiable {
  let node: GitReviewNode
  let depth: Int

  var id: String { node.id + "-\(depth)" }
  var directoryKey: String? { node.dirPath }
  var filePath: String? { node.fullPath }
}
