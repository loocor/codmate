import SwiftUI
import AppKit

struct OpenSourceLicensesView: View {
    let repoURL: URL
    @State private var content: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open Source Licenses")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Open on GitHub") { openOnGitHub() }
            }
            .padding(.bottom, 4)

            if content.isEmpty {
                ProgressView()
                    .task { await loadContent() }
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openOnGitHub() {
        // Point to the file in the default branch
        let url = URL(string: repoURL.absoluteString + "/blob/main/THIRD-PARTY-NOTICES.md")!
        NSWorkspace.shared.open(url)
    }

    private func candidateLocalURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
            urls.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("THIRD-PARTY-NOTICES.md"))
        // When running from Xcode/DerivedData, try a few parents
        let execDir = Bundle.main.bundleURL
        urls.append(execDir.appendingPathComponent("Contents/Resources/THIRD-PARTY-NOTICES.md"))
        return urls
    }

    private func loadContent() async {
        for url in candidateLocalURLs() {
            if FileManager.default.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            {
                await MainActor.run { self.content = text }
                return
            }
        }
        // Fallback to remote raw file on GitHub if local not found
        if let remote = URL(
            string: "https://raw.githubusercontent.com/loocor/CodMate/main/THIRD-PARTY-NOTICES.md")
        {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run { self.content = text }
                }
            } catch {
                await MainActor.run {
                    self.content =
                        "Unable to load licenses. Please see THIRD-PARTY-NOTICES.md in the repository."
                }
            }
        }
    }
}

struct AboutUpdateSection: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Update")
                    .font(.headline)
                Spacer()
                if let lastCheckedAt = viewModel.lastCheckedAt {
                    Text("Last checked \(Self.lastCheckedFormatter.string(from: lastCheckedAt))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if AppDistribution.isAppStore {
                Text("Updates are managed by the App Store.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                content
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .alert("Install", isPresented: $viewModel.showInstallInstructions) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.installInstructions)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            HStack {
                Text("Check for updates.")
                Spacer()
                Button("Check Now") { viewModel.checkNow() }
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking...")
            }
        case .upToDate(let current, _):
            HStack {
                Text("Up to date (\(current)).")
                Spacer()
                Button("Check Now") { viewModel.checkNow() }
            }
        case .updateAvailable(let info):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New version available: \(info.latestVersion)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(info.assetName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if viewModel.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Downloading...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Download & Install") { viewModel.downloadIfNeeded() }
                    }
                }
                if let lastError = viewModel.lastError {
                    Text("Download failed: \(lastError)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        case .error(let message):
            HStack {
                Text("Update check failed: \(message)")
                    .foregroundColor(.red)
                Spacer()
                Button("Retry") { viewModel.checkNow() }
            }
        }
    }

    private static let lastCheckedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
