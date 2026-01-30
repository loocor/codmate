import SwiftUI
import AppKit

private let importSheetPadding: CGFloat = 16

struct MCPImportSheet: View {
  @Binding var candidates: [MCPImportCandidate]
  let isImporting: Bool
  let statusMessage: String?
  let title: String
  let subtitle: String
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if isImporting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      } else if candidates.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "server.rack")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text(statusMessage ?? "No MCP servers found.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        List {
          ForEach($candidates) { $item in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $item.isSelected)
                  .labelsHidden()
                  .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 6) {
                    Text(item.name)
                      .font(.body.weight(.medium))
                    Text(item.kind.rawValue)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  if let desc = item.description, !desc.isEmpty {
                    Text(desc)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  } else if let url = item.url, !url.isEmpty {
                    Text(url)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  } else if let cmd = item.command, !cmd.isEmpty {
                    Text(cmd)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                  Text("Sources: \(item.sources.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                  Picker("", selection: $item.resolution) {
                    ForEach(ImportResolutionChoice.allCases) { choice in
                      Text(choice.title).tag(choice)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.segmented)
                  .frame(width: 240)

                  if item.resolution == .rename {
                    TextField("New name", text: $item.renameName)
                      .textFieldStyle(.roundedBorder)
                      .frame(maxWidth: 220)
                  }
                }
              }

              if item.hasConflict {
                Label("Already exists in CodMate (default: skip)", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              } else if item.hasNameCollision {
                Label("Duplicate name in import list", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
            .padding(.vertical, 6)
            .contextMenu {
              buildOpenMenu(sourcePaths: item.sourcePaths)
              buildRevealMenu(sourcePaths: item.sourcePaths)
            }
          }
        }
        .listStyle(.inset)
      }

      Spacer(minLength: 0)

      if let statusMessage, !statusMessage.isEmpty {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("Conflicts default to Skip. Review before importing.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if candidates.isEmpty && !isImporting {
          Button("Close") { onCancel() }
            .buttonStyle(.borderedProminent)
        } else {
          Button("Cancel") { onCancel() }
          Button("Import") { onImport() }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting || candidates.filter { $0.isSelected }.isEmpty)
        }
      }
    }
    .padding(importSheetPadding)
  }
}

struct SkillsImportSheet: View {
  @Binding var candidates: [SkillImportCandidate]
  let isImporting: Bool
  let statusMessage: String?
  let title: String
  let subtitle: String
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if isImporting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      } else if candidates.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "sparkles")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text(statusMessage ?? "No skills found.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        List {
          ForEach($candidates) { $item in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $item.isSelected)
                  .labelsHidden()
                  .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.name)
                    .font(.body.weight(.medium))
                  if !item.summary.isEmpty {
                    Text(item.summary)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Text("Sources: \(item.sources.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }

              if item.hasConflict {
                Label(item.conflictDetail ?? "Already exists in CodMate (default: skip)", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }

              if item.hasConflict {
                HStack(spacing: 8) {
                  Picker("", selection: $item.resolution) {
                    ForEach(ImportResolutionChoice.allCases) { choice in
                      Text(choice.title).tag(choice)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.segmented)
                  .frame(width: 240)

                  if item.resolution == .rename {
                    TextField("New ID", text: $item.renameId)
                      .textFieldStyle(.roundedBorder)
                      .frame(maxWidth: 220)
                  }
                }
              }
            }
            .padding(.vertical, 6)
            .contextMenu {
              buildOpenMenu(sourcePaths: item.sourcePaths)
              buildRevealMenu(sourcePaths: item.sourcePaths)
            }
          }
        }
        .listStyle(.inset)
      }

      Spacer(minLength: 0)

      if let statusMessage, !statusMessage.isEmpty {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("Conflicts default to Skip. Review before importing.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if candidates.isEmpty && !isImporting {
          Button("Close") { onCancel() }
            .buttonStyle(.borderedProminent)
        } else {
          Button("Cancel") { onCancel() }
          Button("Import") { onImport() }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting || candidates.filter { $0.isSelected }.isEmpty)
        }
      }
    }
    .padding(importSheetPadding)
  }
}

struct CommandsImportSheet: View {
  @Binding var candidates: [CommandImportCandidate]
  let isImporting: Bool
  let statusMessage: String?
  let title: String
  let subtitle: String
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if isImporting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      } else if candidates.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "command")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text(statusMessage ?? "No commands found.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        List {
          ForEach($candidates) { $item in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $item.isSelected)
                  .labelsHidden()
                  .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.name)
                    .font(.body.weight(.medium))
                  if !item.description.isEmpty {
                    Text(item.description)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  Text("Sources: \(item.sources.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }

              if item.hasConflict {
                Label("Already exists in CodMate (default: skip)", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }

              if item.hasConflict {
                HStack(spacing: 8) {
                  Picker("", selection: $item.resolution) {
                    ForEach(ImportResolutionChoice.allCases) { choice in
                      Text(choice.title).tag(choice)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.segmented)
                  .frame(width: 240)

                  if item.resolution == .rename {
                    TextField("New ID", text: $item.renameId)
                      .textFieldStyle(.roundedBorder)
                      .frame(maxWidth: 220)
                  }
                }
              }
            }
            .padding(.vertical, 6)
            .contextMenu {
              buildOpenMenu(sourcePaths: item.sourcePaths)
              buildRevealMenu(sourcePaths: item.sourcePaths)
            }
          }
        }
        .listStyle(.inset)
      }

      Spacer(minLength: 0)

      if let statusMessage, !statusMessage.isEmpty {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("Conflicts default to Skip. Review before importing.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if candidates.isEmpty && !isImporting {
          Button("Close") { onCancel() }
            .buttonStyle(.borderedProminent)
        } else {
          Button("Cancel") { onCancel() }
          Button("Import") { onImport() }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting || candidates.filter { $0.isSelected }.isEmpty)
        }
      }
    }
    .padding(importSheetPadding)
  }
}

struct HooksImportSheet: View {
  @Binding var candidates: [HookImportCandidate]
  let isImporting: Bool
  let statusMessage: String?
  let title: String
  let subtitle: String
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      if isImporting {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
      } else if candidates.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "link")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text(statusMessage ?? "No hooks found.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        List {
          ForEach($candidates) { $item in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $item.isSelected)
                  .labelsHidden()
                  .controlSize(.small)

                VStack(alignment: .leading, spacing: 4) {
                  Text(item.rule.name.isEmpty ? item.rule.event : item.rule.name)
                    .font(.body.weight(.medium))
                  Text(summaryText(item.rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                  Text("Sources: \(item.sources.sorted().joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                  Picker("", selection: $item.resolution) {
                    ForEach(ImportResolutionChoice.allCases) { choice in
                      Text(choice.title).tag(choice)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.segmented)
                  .frame(width: 240)

                  if item.resolution == .rename {
                    TextField("New name", text: $item.renameName)
                      .textFieldStyle(.roundedBorder)
                      .frame(maxWidth: 220)
                  }
                }
              }

              if item.hasConflict {
                Label("Already exists in CodMate (default: skip)", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              } else if item.hasNameCollision {
                Label("Duplicate name in import list", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
            }
            .padding(.vertical, 6)
            .contextMenu {
              buildOpenMenu(sourcePaths: item.sourcePaths)
              buildRevealMenu(sourcePaths: item.sourcePaths)
            }
          }
        }
        .listStyle(.inset)
      }

      Spacer(minLength: 0)

      if let statusMessage, !statusMessage.isEmpty {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("Conflicts default to Skip. Review before importing.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if candidates.isEmpty && !isImporting {
          Button("Close") { onCancel() }
            .buttonStyle(.borderedProminent)
        } else {
          Button("Cancel") { onCancel() }
          Button("Import") { onImport() }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting || candidates.filter { $0.isSelected }.isEmpty)
        }
      }
    }
    .padding(importSheetPadding)
  }

  private func summaryText(_ rule: HookRule) -> String {
    let event = rule.event.isEmpty ? "Event" : rule.event
    let matcher = rule.matcher?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = rule.commands.first?.command.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = [
      event,
      (matcher?.isEmpty == false ? "matcher: \(matcher!)" : nil),
      (cmd?.isEmpty == false ? cmd : nil),
      "\(rule.commands.count) command(s)"
    ].compactMap { $0 }
    return parts.joined(separator: " · ")
  }
}

@ViewBuilder
private func buildOpenMenu(sourcePaths: [String: String]) -> some View {
  let editors = EditorApp.installedEditors
  let sortedSources = sourcePaths.keys.sorted()
  if sortedSources.isEmpty {
    EmptyView()
  } else {
    Menu {
      if sortedSources.count == 1, let key = sortedSources.first, let path = sourcePaths[key] {
        buildEditorEntries(editors: editors, path: path)
      } else {
        ForEach(sortedSources, id: \.self) { key in
          if let path = sourcePaths[key] {
            Menu(key) {
              buildEditorEntries(editors: editors, path: path)
            }
          }
        }
      }
    } label: {
      Label("Open in", systemImage: "arrow.up.forward.app")
    }
  }
}

@ViewBuilder
private func buildRevealMenu(sourcePaths: [String: String]) -> some View {
  let sortedSources = sourcePaths.keys.sorted()
  if sortedSources.isEmpty {
    EmptyView()
  } else if sortedSources.count == 1, let key = sortedSources.first, let path = sourcePaths[key] {
    Button {
      revealInFinder(path)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }
  } else {
    Menu {
      ForEach(sortedSources, id: \.self) { key in
        if let path = sourcePaths[key] {
          Button(key) {
            revealInFinder(path)
          }
        }
      }
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }
  }
}

@ViewBuilder
private func buildEditorEntries(editors: [EditorApp], path: String) -> some View {
  if editors.isEmpty {
    Button("Default App") { openSourcePath(path) }
  } else {
    ForEach(editors) { editor in
      Button {
        openSourcePath(path, using: editor)
      } label: {
        Label {
          Text(editor.title)
        } icon: {
          if let icon = editor.menuIcon {
            Image(nsImage: icon)
              .frame(width: 14, height: 14)
          } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
          }
        }
      }
    }
  }
}

private func openSourcePath(_ path: String) {
  let url = URL(fileURLWithPath: path)
  NSWorkspace.shared.open(url)
}

private func revealInFinder(_ path: String) {
  let url = URL(fileURLWithPath: path)
  NSWorkspace.shared.activateFileViewerSelecting([url])
}

private func openSourcePath(_ path: String, using editor: EditorApp) {
  // Try CLI command first.
  if let exe = findExecutableInPath(editor.cliCommand) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = [path]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do {
      try p.run()
      return
    } catch {
      // Fall through to bundle open.
    }
  }
  if let appURL = editor.appURL {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config, completionHandler: nil)
    return
  }
  openSourcePath(path)
}

private func findExecutableInPath(_ name: String) -> String? {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
  process.arguments = [name]
  let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
  do {
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (path?.isEmpty == false) ? path : nil
  } catch {
    return nil
  }
}
