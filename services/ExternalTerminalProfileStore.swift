import Foundation

struct ExternalTerminalProfileStore {
    static let shared = ExternalTerminalProfileStore()

    struct Paths {
        let home: URL
        let fileURL: URL
    }

    private let fileManager: FileManager
    private let paths: Paths

    init(fileManager: FileManager = .default, paths: Paths? = nil) {
        self.fileManager = fileManager
        if let paths {
            self.paths = paths
        } else {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let dir = home.appendingPathComponent(".codmate", isDirectory: true)
            self.paths = Paths(home: dir, fileURL: dir.appendingPathComponent("terminals.json"))
        }
    }

    func seedUserFileIfNeeded() {
        guard !fileManager.fileExists(atPath: paths.fileURL.path) else { return }
        guard let bundled = loadBundledProfilesRawData() else { return }
        do {
            try fileManager.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try bundled.write(to: paths.fileURL, options: .atomic)
        } catch {
            // Best-effort only; ignore failures to avoid blocking launch.
        }
    }

    func loadUserProfiles() -> [ExternalTerminalProfile] {
        guard let data = try? Data(contentsOf: paths.fileURL) else { return [] }
        if let decoded = decodeProfiles(from: data) { return decoded }
        rebuildUserFileFromBundle()
        guard let rebuilt = try? Data(contentsOf: paths.fileURL) else { return [] }
        return decodeProfiles(from: rebuilt) ?? []
    }

    func loadBundledProfiles() -> [ExternalTerminalProfile] {
        guard let data = loadBundledProfilesRawData() else { return [] }
        return decodeProfiles(from: data) ?? []
    }

    func mergedProfiles() -> [ExternalTerminalProfile] {
        seedUserFileIfNeeded()
        let protected = Self.protectedIds
        var merged = Self.builtInProfiles
        var indexById: [String: Int] = [:]
        for (idx, profile) in merged.enumerated() {
            indexById[profile.id] = idx
        }

        let user = loadUserProfiles().filter { !protected.contains($0.id) }
        for profile in user {
            if let idx = indexById[profile.id] {
                merged[idx] = profile
            } else {
                indexById[profile.id] = merged.count
                merged.append(profile)
            }
        }
        return merged
    }

    func availableProfiles(includeNone: Bool = true) -> [ExternalTerminalProfile] {
        let profiles = mergedProfiles().filter { $0.isAvailable }
        if includeNone { return profiles }
        return profiles.filter { !$0.isNone }
    }

    func profile(for id: String) -> ExternalTerminalProfile? {
        mergedProfiles().first { $0.id == id }
    }

    func resolvePreferredProfile(id: String?) -> ExternalTerminalProfile? {
        let profiles = availableProfiles(includeNone: true)
        if let id, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        if let terminal = profiles.first(where: { $0.id == "terminal" }) { return terminal }
        return profiles.first
    }

    func resolvePreferredId(id: String?) -> String {
        resolvePreferredProfile(id: id)?.id ?? "terminal"
    }

    private func loadBundledProfilesRawData() -> Data? {
        let bundle = Bundle.main
        var urls: [URL] = []
        if let u = bundle.url(forResource: "terminals", withExtension: "json") { urls.append(u) }
        if let u = bundle.url(forResource: "terminals", withExtension: "json", subdirectory: "payload") { urls.append(u) }
        for url in urls {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    private struct TerminalsFile: Codable { let terminals: [ExternalTerminalProfile] }

    private func decodeProfiles(from data: Data) -> [ExternalTerminalProfile]? {
        let decoder = JSONDecoder()
        if let profiles = try? decoder.decode([ExternalTerminalProfile].self, from: data) {
            return profiles
        }
        if let file = try? decoder.decode(TerminalsFile.self, from: data) {
            return file.terminals
        }
        return nil
    }

    private func rebuildUserFileFromBundle() {
        guard let bundled = loadBundledProfilesRawData() else { return }
        do {
            try fileManager.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try bundled.write(to: paths.fileURL, options: .atomic)
        } catch {
            return
        }
        Self.notifyParseFailureOnce()
    }

    private static var didNotifyParseFailure = false

    private static func notifyParseFailureOnce() {
        guard !didNotifyParseFailure else { return }
        didNotifyParseFailure = true
        Task { await SystemNotifier.shared.notify(
            title: "CodMate",
            body: "Terminals configuration failed to load. Rebuilt defaults."
        ) }
    }

    private static let builtInProfiles: [ExternalTerminalProfile] = [
        ExternalTerminalProfile(
            id: "none",
            title: "None",
            bundleIdentifiers: nil,
            urlTemplate: nil,
            supportsCommand: false,
            supportsDirectory: false,
            managedByCodMate: true,
            commandStyle: .standard
        ),
        ExternalTerminalProfile(
            id: "terminal",
            title: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            urlTemplate: nil,
            supportsCommand: false,
            supportsDirectory: true,
            managedByCodMate: true,
            commandStyle: .standard
        ),
    ]

    private static let protectedIds: Set<String> = ["none", "terminal"]
}
