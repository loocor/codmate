import Foundation
import SwiftUI

extension ProjectWorkspaceViewModel {
    /// Generates title and description for a task based on its sessions' metadata
    /// Uses strategy B: only reads session titles and comments (fast, lightweight)
    /// - Parameters:
    ///   - task: The task to generate for
    ///   - currentTitle: The current title being edited (may differ from task.title)
    ///   - currentDescription: The current description being edited (may differ from task.description)
    ///   - force: If true, skip confirmation dialog
    func generateTitleAndDescription(for task: CodMateTask, currentTitle: String? = nil, currentDescription: String? = nil, force: Bool = false) async {
        // Check if task already has title or description
        let hasTitle = !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDescription = task.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        if !force && (hasTitle || hasDescription) {
            // Show confirmation dialog
            let shouldProceed = await confirmOverwrite(taskTitle: task.effectiveTitle)
            guard shouldProceed else { return }
        }

        // Set loading state
        isGeneratingTitleDescription = true
        generatingTaskId = task.id
        defer {
            isGeneratingTitleDescription = false
            generatingTaskId = nil
        }

        // Get sessions for this task
        let sessions = getSessionsForTask(task.id)

        // Special case: no sessions exist
        if sessions.isEmpty {
            // Use current editing values if provided, otherwise use task values
            let titleToUse = currentTitle ?? task.title
            let descToUse = currentDescription ?? task.description ?? ""

            // If both title and description are empty, nothing to generate from
            let hasTitleContent = !titleToUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasDescContent = !descToUse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            guard hasTitleContent || hasDescContent else {
                return
            }

            // Generate based on available content (title and/or description)
            await generateFromContent(title: titleToUse, description: descToUse)
            return
        }

        // Build material from session metadata (title + comment only)
        let material = buildSessionMetadataMaterial(sessions: sessions)

        // Load prompt template
        guard let promptTemplate = loadPromptTemplate(named: "task-title-and-description") else {
            return
        }

        // Build full prompt
        let fullPrompt = promptTemplate + material

        // Call LLM
        guard let response = await callLLM(prompt: fullPrompt) else {
            return
        }

        // Parse response
        guard let parsed = Self.parseTitleDescriptionResponse(response) else {
            return
        }

        // Update generated content state - EditTaskSheet will pick these up
        generatedTaskTitle = parsed.title
        generatedTaskDescription = parsed.description.isEmpty ? nil : parsed.description
    }

    // MARK: - Private Helpers

    /// Generate title and description based on existing content (when no sessions exist)
    private func generateFromContent(title: String, description: String) async {
        // Load prompt template for content-based generation
        guard let promptTemplate = loadPromptTemplate(named: "task-title-only") else {
            return
        }

        // Build prompt with current title and/or description
        var contentLines: [String] = []

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty {
            contentLines.append("Current title: \(trimmedTitle)")
        }
        if !trimmedDesc.isEmpty {
            contentLines.append("Current description: \(trimmedDesc)")
        }

        let fullPrompt = promptTemplate + "\n\n" + contentLines.joined(separator: "\n")

        // Call LLM
        guard let response = await callLLM(prompt: fullPrompt) else {
            return
        }

        // Parse response
        guard let parsed = Self.parseTitleDescriptionResponse(response) else {
            return
        }

        // Update generated content state
        generatedTaskTitle = parsed.title
        generatedTaskDescription = parsed.description.isEmpty ? nil : parsed.description
    }

    private func buildSessionMetadataMaterial(sessions: [SessionSummary]) -> String {
        var lines: [String] = []

        for (index, session) in sessions.enumerated() {
            let title = session.effectiveTitle
            let comment = session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            lines.append("Session \(index + 1): \"\(title)\"")
            if !comment.isEmpty {
                // Limit comment to 200 characters to keep material compact
                let snippet = comment.count > 200 ? String(comment.prefix(200)) + "…" : comment
                lines.append("  - \(snippet)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func loadPromptTemplate(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "payload/prompts") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func callLLM(prompt: String) async -> String? {
        let llm = LLMHTTPService()
        var options = LLMHTTPService.Options()
        options.preferred = .auto
        options.timeout = 45
        options.maxTokens = 500
        options.systemPrompt = "Return only the JSON object. No labels, explanations, or extra commentary."

        // Use the same provider/model configuration as session generation
        if let providerId = UserDefaults.standard.string(forKey: "git.review.commitProviderId"), !providerId.isEmpty {
            options.providerId = providerId
        }
        if let modelId = UserDefaults.standard.string(forKey: "git.review.commitModelId"), !modelId.isEmpty {
            options.model = modelId
        }

        do {
            let res = try await llm.generateText(prompt: prompt, options: options)
            return res.text
        } catch {
            return nil
        }
    }

    private static func parseTitleDescriptionResponse(_ raw: String) -> (title: String, description: String)? {
        // Remove code fences if present
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = cleaned.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleaned.hasPrefix("```") {
            cleaned = cleaned.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Parse JSON
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let title = json["title"] as? String,
              let description = json["description"] as? String else {
            return nil
        }

        return (
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @MainActor
    private func confirmOverwrite(taskTitle: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Overwrite Existing Content?"
                alert.informativeText = "This task already has a title or description. Do you want to generate new ones?"
                alert.addButton(withTitle: "Generate")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
