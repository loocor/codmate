import Foundation

struct SkillRunResult: Sendable {
  var outputText: String
  var stderrText: String
  var exitCode: Int32
}

enum InternalSkillRunnerError: LocalizedError {
  case missingSkill
  case missingInvocation
  case invalidInput
  case executionFailed(String)
  case outputMissing(String)

  var errorDescription: String? {
    switch self {
    case .missingSkill:
      return "Internal skill not available."
    case .missingInvocation:
      return "No CLI invocation is configured for this provider."
    case .invalidInput:
      return "Failed to build skill input."
    case .executionFailed(let message):
      return "Skill execution failed: \(message)"
    case .outputMissing(let details):
      return "Skill did not return any output.\n\(details)"
    }
  }
}

actor InternalSkillRunner {
  private let registry = InternalSkillsRegistry()
  private let docsService = WizardDocsService()

  func run(
    feature: WizardFeature,
    provider: SessionSource.Kind,
    conversation: [WizardMessage],
    defaultExecutable: String,
    progress: @escaping (WizardRunEvent) -> Void
  ) async throws -> SkillRunResult {
    guard let skill = await registry.skill(for: feature) else {
      throw InternalSkillRunnerError.missingSkill
    }
    guard let invocation = skill.definition.invocations.first(where: { $0.provider == provider }) else {
      throw InternalSkillRunnerError.missingInvocation
    }

    let input = try await buildInput(
      feature: feature,
      provider: provider,
      conversation: conversation,
      skill: skill
    )

    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("codmate-skill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    let skillDir = tempRoot.appendingPathComponent("skill", isDirectory: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

    try writeAssets(skill, to: skillDir)

    let inputURL = tempRoot.appendingPathComponent("input.json")
    let outputURL = tempRoot.appendingPathComponent("output.json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(input)
    try data.write(to: inputURL, options: .atomic)
    let promptText = buildPromptText(payloadData: data)
    let promptData = promptText.data(using: .utf8) ?? data

    let args = resolveArgs(
      invocation.args,
      skillDir: skillDir,
      inputFile: inputURL,
      outputFile: outputURL,
      schemaFile: skillDir.appendingPathComponent("schema.json"),
      promptFile: skillDir.appendingPathComponent("prompt.md"),
      skillFile: skillDir.appendingPathComponent("SKILL.md")
    )

    let workingDirectory = InternalWizardPaths.ensureProjectRootExists()
    await MainActor.run { progress(WizardRunEvent(message: "Invoking CLI skill", kind: .status)) }

    let exec = invocation.executable?.trimmingCharacters(in: .whitespacesAndNewlines)
    let executable = (exec?.isEmpty == false) ? exec! : defaultExecutable

    let result = try await runProcess(
      executable: executable,
      args: args,
      input: invocation.inputMode == .stdin ? promptData : nil,
      timeout: invocation.timeoutSeconds,
      workingDirectory: workingDirectory,
      progress: progress
    )

    if result.exitCode != 0 {
      let debug = formatDebugReport(
        executable: executable,
        args: args,
        workingDirectory: workingDirectory,
        result: result,
        outputFile: invocation.outputMode == .file ? outputURL : nil
      )
      throw InternalSkillRunnerError.executionFailed(debug)
    }

    let outputText: String
    switch invocation.outputMode {
    case .stdout:
      outputText = result.outputText
    case .file:
      outputText = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    }

    if outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let debug = formatDebugReport(
        executable: executable,
        args: args,
        workingDirectory: workingDirectory,
        result: result,
        outputFile: invocation.outputMode == .file ? outputURL : nil
      )
      throw InternalSkillRunnerError.outputMissing(debug)
    }

    return SkillRunResult(outputText: outputText, stderrText: result.stderrText, exitCode: result.exitCode)
  }

  // MARK: - Input Build

  private struct WizardSkillInput: Codable {
    var feature: WizardFeature
    var provider: String
    var appLanguage: String
    var appLanguageName: String
    var request: String
    var conversation: [WizardMessage]
    var schema: String?
    var prompt: String?
    var catalogs: [String: [String]]?
    var docs: [WizardDocSnippet]
  }

  private func buildInput(
    feature: WizardFeature,
    provider: SessionSource.Kind,
    conversation: [WizardMessage],
    skill: InternalSkillAsset
  ) async throws -> WizardSkillInput {
    guard let last = conversation.last(where: { $0.role == .user }) else {
      throw InternalSkillRunnerError.invalidInput
    }
    let language = resolveAppLanguage()

    let catalogs = buildCatalogs(for: feature)
    let keywords = catalogs.flatMap { $0.value }
    let docs = await docsService.snippets(
      feature: feature,
      provider: provider,
      overrides: skill.docsOverrides,
      keywords: keywords
    )

    return WizardSkillInput(
      feature: feature,
      provider: provider.rawValue,
      appLanguage: language.code,
      appLanguageName: language.name,
      request: last.text,
      conversation: conversation,
      schema: skill.schema,
      prompt: skill.prompt,
      catalogs: catalogs.isEmpty ? nil : catalogs,
      docs: docs
    )
  }

  private func buildCatalogs(for feature: WizardFeature) -> [String: [String]] {
    switch feature {
    case .hooks:
      let events = HookEventCatalog.all.map { $0.name }
      let vars = HookCommandVariableCatalog.all.map { $0.name }
      return ["events": events, "variables": vars]
    default:
      return [:]
    }
  }

  // MARK: - Assets

  private func writeAssets(_ skill: InternalSkillAsset, to dir: URL) throws {
    if let skillMarkdown = skill.skillMarkdown {
      try skillMarkdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    if let prompt = skill.prompt {
      try prompt.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
    }
    if let schema = skill.schema {
      try schema.write(to: dir.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
    }
  }

  private func buildPromptText(payloadData: Data) -> String {
    let payload = String(data: payloadData, encoding: .utf8) ?? "{}"
    return """
    You are a CodMate internal wizard skill.
    Follow the instructions in the JSON payload field "prompt".
    All user-facing text must use the language specified by payload.appLanguage (BCP-47 code)
    and payload.appLanguageName (English name of the language).
    You do not have tool access. Do not invoke tools, shell commands, or web browsing.
    Use the payload field "schema" as the required JSON Schema for your output.
    Use "docs" and "catalogs" for reference and "conversation" for context.
    If the request is unclear, set mode="question" and provide follow-up questions.
    Return only JSON. Do not include markdown or extra text.

    JSON payload:
    \(payload)
    """
  }

  private func resolveAppLanguage() -> (code: String, name: String) {
    let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
    let locale = Locale(identifier: preferred)
    let languageCode = locale.language.languageCode?.identifier ?? preferred
    let englishName = Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? preferred
    return (preferred, englishName)
  }

  // MARK: - Args

  private func resolveArgs(
    _ args: [String],
    skillDir: URL,
    inputFile: URL,
    outputFile: URL,
    schemaFile: URL,
    promptFile: URL,
    skillFile: URL
  ) -> [String] {
    args.map { raw in
      raw
        .replacingOccurrences(of: "{{skillDir}}", with: skillDir.path)
        .replacingOccurrences(of: "{{inputFile}}", with: inputFile.path)
        .replacingOccurrences(of: "{{outputFile}}", with: outputFile.path)
        .replacingOccurrences(of: "{{schemaFile}}", with: schemaFile.path)
        .replacingOccurrences(of: "{{promptFile}}", with: promptFile.path)
        .replacingOccurrences(of: "{{skillFile}}", with: skillFile.path)
    }
  }

  private func formatDebugReport(
    executable: String,
    args: [String],
    workingDirectory: URL,
    result: ProcessResult,
    outputFile: URL?
  ) -> String {
    let commandLine = ([executable] + args).joined(separator: " ")
    let stderr = truncate(result.stderrText, limit: 8000)
    let stdout = truncate(result.outputText, limit: 8000)
    var fileOutput = ""
    if let outputFile,
       let text = try? String(contentsOf: outputFile, encoding: .utf8),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      fileOutput = truncate(text, limit: 8000)
    }

    var lines: [String] = []
    lines.append("Command: \(commandLine)")
    lines.append("Workdir: \(workingDirectory.path)")
    lines.append("Exit code: \(result.exitCode)")
    if !stderr.isEmpty {
      lines.append("")
      lines.append("STDERR:")
      lines.append(stderr)
    }
    if !stdout.isEmpty {
      lines.append("")
      lines.append("STDOUT:")
      lines.append(stdout)
    }
    if !fileOutput.isEmpty {
      lines.append("")
      lines.append("OUTPUT FILE:")
      lines.append(fileOutput)
    }
    return lines.joined(separator: "\n")
  }

  private func truncate(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let head = text.prefix(limit)
    return "\(head)\n…(truncated)"
  }

  // MARK: - Process

  private struct ProcessResult {
    var outputText: String
    var stderrText: String
    var exitCode: Int32
  }

  private enum OutputStream {
    case stdout
    case stderr
  }

  private final class OutputCollector {
    private let lock = NSLock()
    private var stdoutText: String = ""
    private var stderrText: String = ""
    private var stdoutRemainder: String = ""
    private var stderrRemainder: String = ""

    func append(_ data: Data, stream: OutputStream) -> [String] {
      let text = String(decoding: data, as: UTF8.self)
      guard !text.isEmpty else { return [] }
      lock.lock()
      defer { lock.unlock() }
      switch stream {
      case .stdout:
        stdoutText += text
        return splitLines(text, remainder: &stdoutRemainder)
      case .stderr:
        stderrText += text
        return splitLines(text, remainder: &stderrRemainder)
      }
    }

    func flush(stream: OutputStream) -> String? {
      lock.lock()
      defer { lock.unlock() }
      switch stream {
      case .stdout:
        guard !stdoutRemainder.isEmpty else { return nil }
        let line = stdoutRemainder
        stdoutRemainder = ""
        return line
      case .stderr:
        guard !stderrRemainder.isEmpty else { return nil }
        let line = stderrRemainder
        stderrRemainder = ""
        return line
      }
    }

    func snapshot() -> (stdout: String, stderr: String) {
      lock.lock()
      defer { lock.unlock() }
      return (stdoutText, stderrText)
    }

    private func splitLines(_ text: String, remainder: inout String) -> [String] {
      let combined = remainder + text
      let parts = combined.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      if combined.hasSuffix("\n") || combined.hasSuffix("\r") {
        remainder = ""
        return parts.map(String.init)
      }
      if let last = parts.last {
        remainder = String(last)
        return parts.dropLast().map(String.init)
      }
      remainder = combined
      return []
    }
  }

  private func runProcess(
    executable: String,
    args: [String],
    input: Data?,
    timeout: Double?,
    workingDirectory: URL?,
    progress: @escaping (WizardRunEvent) -> Void
  ) async throws -> ProcessResult {
    let process = Process()
    var env = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    let existingPath = env["PATH"]
    env["PATH"] = [defaultPath, existingPath]
      .compactMap { $0?.isEmpty == false ? $0 : nil }
      .joined(separator: ":")
    process.environment = env
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + args
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let collector = OutputCollector()

    let emit: (WizardRunEvent) -> Void = { event in
      DispatchQueue.main.async {
        progress(event)
      }
    }

    let emitLines: @Sendable (_ lines: [String], _ kind: WizardRunEvent.Kind) -> Void = { lines, kind in
      for line in lines {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        emit(WizardRunEvent(message: line, kind: kind))
      }
    }

    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      let lines = collector.append(data, stream: .stdout)
      emitLines(lines, .stdout)
    }

    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      let lines = collector.append(data, stream: .stderr)
      emitLines(lines, .stderr)
    }

    if input != nil {
      let stdin = Pipe()
      process.standardInput = stdin
      stdin.fileHandleForWriting.writeabilityHandler = { handle in
        handle.write(input!)
        handle.closeFile()
        stdin.fileHandleForWriting.writeabilityHandler = nil
      }
    }

    try process.run()

    if let timeout {
      Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if process.isRunning {
          process.terminate()
        }
      }
    }

    process.waitUntilExit()

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil

    if let remainingOut = try? stdout.fileHandleForReading.readToEnd(), !remainingOut.isEmpty {
      let lines = collector.append(remainingOut, stream: .stdout)
      emitLines(lines, .stdout)
    }
    if let remainingErr = try? stderr.fileHandleForReading.readToEnd(), !remainingErr.isEmpty {
      let lines = collector.append(remainingErr, stream: .stderr)
      emitLines(lines, .stderr)
    }
    if let last = collector.flush(stream: .stdout) {
      emitLines([last], .stdout)
    }
    if let last = collector.flush(stream: .stderr) {
      emitLines([last], .stderr)
    }

    let snapshot = collector.snapshot()
    return ProcessResult(outputText: snapshot.stdout, stderrText: snapshot.stderr, exitCode: process.terminationStatus)
  }
}
