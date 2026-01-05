import SwiftUI
import AppKit

struct CLIProxyAdvancedPane: View {
  @StateObject private var service = CLIProxyService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Conflict warning
      if let warning = service.conflictWarning {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
          Text(warning)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
      }

      settingsCard {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Label("Binary Location", systemImage: "app.badge")
                .font(.subheadline).fontWeight(.medium)
              Text("CLIProxyAPI binary executable path")
                .font(.caption).foregroundColor(.secondary)
            }
            Text(service.binaryFilePath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .trailing)
              .onTapGesture(count: 2) {
                revealBinaryInFinder()
              }
              .help("Double-click to reveal in Finder")
            HStack(spacing: 8) {
              if service.isInstalling {
                ProgressView()
                  .scaleEffect(0.6)
                  .frame(width: 14, height: 14)
                Text("Installing")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else {
                Button(actionButtonTitle) {
                  Task {
                    if service.binarySource == .homebrew {
                      try? await service.brewUpgrade()
                    } else {
                      try? await service.install()
                    }
                  }
                }
                .buttonStyle(.borderedProminent)
                .tint(actionButtonColor)
              }
            }
            .frame(width: 90, alignment: .trailing)
            .disabled(service.isInstalling)
          }

          gridDivider

          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Label("Config File", systemImage: "doc.text")
                .font(.subheadline).fontWeight(.medium)
              Text("CLIProxyAPI configuration file")
                .font(.caption).foregroundColor(.secondary)
            }
            Text(configFilePath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Reveal") { revealConfigInFinder() }
              .buttonStyle(.bordered)
              .frame(width: 90, alignment: .trailing)
          }

          gridDivider

          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Label("Auth Directory", systemImage: "folder")
                .font(.subheadline).fontWeight(.medium)
              Text("OAuth credential storage")
                .font(.caption).foregroundColor(.secondary)
            }
            Text(authDirPath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Reveal") { revealAuthDirInFinder() }
              .buttonStyle(.bordered)
              .frame(width: 90, alignment: .trailing)
          }

          gridDivider

          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Label("Logs", systemImage: "doc.plaintext")
                .font(.subheadline).fontWeight(.medium)
              Text("CLIProxyAPI log files directory")
                .font(.caption).foregroundColor(.secondary)
            }
            Text(logsPath)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Reveal") { revealLogsInFinder() }
              .buttonStyle(.bordered)
              .frame(width: 90, alignment: .trailing)
          }
        }
      }
    }
  }

  private var gridDivider: some View {
    Divider()
  }

  private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(12)
    .background(Color(nsColor: .separatorColor).opacity(0.35))
    .cornerRadius(10)
  }

  private var configFilePath: String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let configPath = appSupport.appendingPathComponent("CodMate/config.yaml")
    return configPath.path
  }

  private var authDirPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".codmate/auth").path
  }

  private var logsPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".codmate/auth/logs").path
  }

  private func revealConfigInFinder() {
    let url = URL(fileURLWithPath: configFilePath)
    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
  }

  private func revealAuthDirInFinder() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let authPath = home.appendingPathComponent(".codmate/auth")
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: authPath.path)
  }

  private func revealLogsInFinder() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let logsPath = home.appendingPathComponent(".codmate/auth/logs")
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath.path)
  }

  private func revealBinaryInFinder() {
    let url = URL(fileURLWithPath: service.binaryFilePath)
    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
  }

  private var binarySourceDescription: String {
    switch service.binarySource {
    case .none:
      return "No binary detected"
    case .homebrew:
      return "Homebrew installation (managed via brew services)"
    case .codmate:
      return "CodMate built-in installation"
    case .other:
      return "Other installation (potential conflicts)"
    }
  }

  private var binarySourceLabel: String {
    switch service.binarySource {
    case .none:
      return "Not Detected"
    case .homebrew:
      return "Homebrew"
    case .codmate:
      return "CodMate"
    case .other:
      return "Other"
    }
  }

  private var binarySourceColor: Color {
    switch service.binarySource {
    case .none:
      return .secondary
    case .homebrew:
      return .green
    case .codmate:
      return .blue
    case .other:
      return .orange
    }
  }

  private var actionButtonTitle: String {
    switch service.binarySource {
    case .none:
      return "Install"
    case .homebrew:
      return service.isBinaryInstalled ? "Upgrade" : "Install"
    case .codmate:
      return service.isBinaryInstalled ? "Reinstall" : "Install"
    case .other:
      return service.isBinaryInstalled ? "Reinstall" : "Install"
    }
  }

  private var actionButtonColor: Color {
    switch service.binarySource {
    case .none:
      return .blue
    case .homebrew:
      return .green
    case .codmate:
      return service.isBinaryInstalled ? .red : .blue
    case .other:
      return service.isBinaryInstalled ? .red : .blue
    }
  }
}
