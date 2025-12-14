import Foundation

enum WarpTitleBuilder {
    private static let dashCharacterSet = CharacterSet(charactersIn: "-")
    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    static func token(from raw: String?) -> String? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var resultScalars: [Character] = []
        var lastWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                resultScalars.append(Character(scalar))
                lastWasDash = false
            } else if scalar == "-" || scalar == "_" {
                resultScalars.append("-")
                lastWasDash = true
            } else if !lastWasDash {
                resultScalars.append("-")
                lastWasDash = true
            }
        }
        let result = String(resultScalars).trimmingCharacters(in: dashCharacterSet)
        return result.isEmpty ? nil : result
    }

    static func timestampString(_ date: Date = Date()) -> String {
        timestampFormatter.string(from: date)
    }

    static func newSessionLabel(
        scope: String?,
        task: String?,
        extras: [String] = [],
        date: Date = Date()
    ) -> String {
        var tokens: [String] = [timestampString(date)]
        if let scopeToken = token(from: scope) { tokens.append(scopeToken) }
        if let taskToken = token(from: task) { tokens.append(taskToken) }
        for raw in extras {
            if let tokenized = token(from: raw) {
                tokens.append(tokenized)
            }
        }
        return tokens.joined(separator: "-")
    }
}
