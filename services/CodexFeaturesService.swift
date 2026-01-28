import Foundation

struct CodexFeatureInfo: Identifiable, Equatable {
    let name: String
    let stage: String
    let enabled: Bool

    var id: String { name }
}

actor CodexFeaturesService {
    enum Error: Swift.Error, LocalizedError {
        case cliFailed(stderr: String)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .cliFailed(let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Failed to invoke codex features list" : trimmed
            case .parseFailed:
                return "Unable to parse codex features output"
            }
        }
    }

    func listFeatures() throws -> [CodexFeatureInfo] {
        let env = [
            "PATH": CLIEnvironment.buildBasePATH(),
            "NO_COLOR": "1"
        ]
        do {
            let result = try ShellCommandRunner.run(
                executable: "/usr/bin/env",
                arguments: ["codex", "features", "list"],
                environment: env
            )
            return try Self.parseFeatures(from: result.stdout)
        } catch let ShellCommandError.commandFailed(_, _, stderr, _) {
            throw Error.cliFailed(stderr: stderr)
        } catch {
            throw error
        }
    }

    private static func parseFeatures(from stdout: String) throws -> [CodexFeatureInfo] {
        var features: [CodexFeatureInfo] = []
        for rawLine in stdout.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let columns = trimmed.split(omittingEmptySubsequences: true) { ch in
                ch == "\t" || ch == " "
            }
            guard columns.count >= 3 else { continue }
            guard let enabledToken = columns.last?.lowercased() else { continue }
            let enabled: Bool
            switch enabledToken {
            case "true":
                enabled = true
            case "false":
                enabled = false
            default:
                continue
            }
            let name = String(columns[0])
            let stage = columns.dropFirst().dropLast().map(String.init).joined(separator: " ")
            features.append(CodexFeatureInfo(name: name, stage: stage, enabled: enabled))
        }
        if features.isEmpty { throw Error.parseFailed }
        return features
    }
}
