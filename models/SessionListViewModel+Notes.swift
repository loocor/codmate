import Foundation
import AppKit
import OSLog

@MainActor
extension SessionListViewModel {

    private static let log = Logger(subsystem: "ai.umate.codmate", category: "SessionSummaryGen")

    // MARK: - Title and Comment Generation

    /// Generates title and comment for a session using LLM
    /// - Parameters:
    ///   - session: The session to generate for
    ///   - force: If true, skip the confirmation dialog when existing content is present
    func generateTitleAndComment(for session: SessionSummary, force: Bool = false) async {
        Self.log.info("Starting generation for session \(session.id, privacy: .public)")
        let statusToken = StatusBarLogStore.shared.beginTask(
            "Generating title & comment...",
            level: .info,
            source: "Session"
        )
        var finalStatus: (message: String, level: StatusBarLogLevel)?
        defer {
            if let finalStatus {
                StatusBarLogStore.shared.endTask(
                    statusToken,
                    message: finalStatus.message,
                    level: finalStatus.level,
                    source: "Session"
                )
            } else {
                StatusBarLogStore.shared.endTask(statusToken)
            }
        }

        // Check if there's existing content and we should confirm
        if !force {
            // Only show confirmation if there's actual non-empty content
            let title = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let comment = session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasExisting = !title.isEmpty || !comment.isEmpty

            if hasExisting {
                Self.log.info("Session has existing content, showing confirmation dialog")
                let shouldProceed = await showOverwriteConfirmation()
                if !shouldProceed {
                    Self.log.info("User cancelled generation")
                    finalStatus = ("Generation cancelled", .warning)
                    return
                }
                Self.log.info("User confirmed, proceeding with generation")
            }
        }

        // Set generating state
        isGeneratingTitleComment = true
        generatingSessionId = session.id
        defer {
            isGeneratingTitleComment = false
            generatingSessionId = nil
        }

        do {
            // Load turns using existing timeline infrastructure
            Self.log.info("Loading conversation turns from \(session.fileURL.path, privacy: .public)")
            Self.log.info("Session source: \(String(describing: session.source), privacy: .public)")

            let turns = await self.timeline(for: session)
            Self.log.info("Loaded \(turns.count) turns")

            if turns.isEmpty {
                Self.log.warning("No conversation turns found")
                await showGenerationError("No conversation data found in session.")
                finalStatus = ("No conversation data found", .warning)
                return
            }

            // Build material using intelligent truncation and summarization
            // Run in background thread to avoid blocking UI
            Self.log.info("Building conversation material")

            let material = await Task.detached {
                SessionSummaryMaterialBuilder.build(turns: turns)
            }.value

            Self.log.info("Material size: \(material.utf8.count) bytes")

            // Build prompt
            let prompt = Self.titleCommentPrompt(material: material)
            Self.log.info("Prompt size: \(prompt.utf8.count) bytes")

            // Call LLM
            Self.log.info("Calling LLM API")
            let llm = LLMHTTPService()
            var options = LLMHTTPService.Options()
            options.preferred = .auto

            // Reuse commit message configuration for now
            if let providerId = UserDefaults.standard.string(forKey: "git.review.commitProviderId"), !providerId.isEmpty {
                options.providerId = providerId
                Self.log.info("Using provider: \(providerId, privacy: .public)")
            }
            if let modelId = UserDefaults.standard.string(forKey: "git.review.commitModelId"), !modelId.isEmpty {
                options.model = modelId
                Self.log.info("Using model: \(modelId, privacy: .public)")
            }

            options.timeout = 45
            options.maxTokens = 500
            options.systemPrompt = "Return only the JSON object. No labels, explanations, or extra commentary."

            let res = try await llm.generateText(prompt: prompt, options: options)
            Self.log.info("LLM responded in \(res.elapsedMs)ms from provider \(res.providerId, privacy: .public)")

            let raw = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("Raw response: \(raw, privacy: .public)")

            // Parse JSON response
            guard let result = Self.parseTitleCommentResponse(raw) else {
                Self.log.error("Failed to parse JSON response")
                await showGenerationError("Failed to parse response from LLM. Response: \(raw)")
                finalStatus = ("Failed to parse LLM response", .error)
                return
            }

            Self.log.info("Parsed title: \(result.title, privacy: .public)")
            Self.log.info("Parsed comment: \(result.comment, privacy: .public)")

            // Update edit fields
            await MainActor.run {
                // If we're already editing this session, just update the fields
                if editingSession?.id == session.id {
                    Self.log.info("Updating existing edit dialog")
                    if !result.title.isEmpty {
                        editTitle = result.title
                    }
                    if !result.comment.isEmpty {
                        editComment = result.comment
                    }
                } else {
                    // Otherwise, open the edit dialog with the generated content
                    Self.log.info("Opening new edit dialog")
                    editingSession = session
                    editTitle = result.title
                    editComment = result.comment
                }
            }

            Self.log.info("Generation completed successfully")
            if preferences.titleCommentNotificationsEnabled {
                await SystemNotifier.shared.notify(
                    title: "Session Summary",
                    body: "Generated title and comment in \(res.elapsedMs)ms",
                    threadId: "session-summary"
                )
            }
            finalStatus = ("Title & comment ready", .success)

        } catch {
            Self.log.error("Generation error: \(error.localizedDescription, privacy: .public)")
            await showGenerationError("Generation failed: \(error.localizedDescription)")
            finalStatus = ("Generation failed: \(error.localizedDescription)", .error)
        }
    }

    private func showGenerationError(_ message: String) async {
        Self.log.error("Showing error: \(message, privacy: .public)")
        if preferences.titleCommentNotificationsEnabled {
            await SystemNotifier.shared.notify(
                title: "Session Summary Error",
                body: message,
                threadId: "session-summary"
            )
        }
    }

    private func showOverwriteConfirmation() async -> Bool {
        // Use NSAlert for confirmation
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Overwrite Existing Content?"
                alert.informativeText = "This session already has a title or comment. Do you want to generate new ones?"
                alert.addButton(withTitle: "Generate")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning

                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: - Prompt Building

    private static func titleCommentPrompt(material: String) -> String {
        let basePrompt: String
        if let payload = Self.payloadTitleCommentPrompt {
            basePrompt = payload
        } else {
            basePrompt = """
            Generate a concise title and descriptive comment for this conversation.
            Return a JSON object with "title" and "comment" fields.
            Title should be 3-8 words. Comment should be 1-3 sentences.
            """
        }
        return [basePrompt, "", material].joined(separator: "\n")
    }

    private static let payloadTitleCommentPrompt: String? = {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "title-and-comment", withExtension: "md", subdirectory: "payload/prompts") else {
            return nil
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    // MARK: - Response Parsing

    private static func parseTitleCommentResponse(_ raw: String) -> (title: String, comment: String)? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove code fences if present
        if cleaned.hasPrefix("```") {
            // Remove opening fence (```json or just ```)
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove closing fence
            if let lastFence = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[..<lastFence.lowerBound])
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to parse JSON
        guard let data = cleaned.data(using: .utf8) else { return nil }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String,
               let comment = json["comment"] as? String {
                return (title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        comment: comment.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - Existing Methods
    func timelineVisibleKindsOverride(for sessionId: String) -> Set<MessageVisibilityKind>? {
        let raw = notesSnapshot[sessionId]?.timelineVisibleKinds
        guard var set = Set<MessageVisibilityKind>.fromRawValues(raw) else { return nil }
        set.remove(.environmentContext)
        if set.contains(.tool) { set.insert(.codeEdit) }
        return set
    }

    func updateTimelineVisibleKindsOverride(
        for sessionId: String,
        kinds: Set<MessageVisibilityKind>?
    ) async {
        let raw = kinds?.rawValues
        await notesStore.updateTimelineVisibleKinds(id: sessionId, kinds: raw)
        if let updatedNote = await notesStore.note(for: sessionId) {
            notesSnapshot[sessionId] = updatedNote
        }
    }

    func clearTimelineVisibleKindsOverride(for sessionId: String) async {
        await updateTimelineVisibleKindsOverride(for: sessionId, kinds: nil)
    }

    func beginEditing(session: SessionSummary) async {
        editingSession = session
        if let note = await notesStore.note(for: session.id) {
            editTitle = note.title ?? ""
            editComment = note.comment ?? ""
        } else {
            editTitle = session.userTitle ?? ""
            editComment = session.userComment ?? ""
        }
    }

    func saveEdits() async {
        guard let session = editingSession else { return }
        let titleValue = editTitle.isEmpty ? nil : editTitle
        let commentValue = editComment.isEmpty ? nil : editComment
        await notesStore.upsert(id: session.id, title: titleValue, comment: commentValue)

        // Reload the complete note from store to ensure cache consistency
        // (preserves projectId, profileId and other fields managed by notesStore)
        if let updatedNote = await notesStore.note(for: session.id) {
            notesSnapshot[session.id] = updatedNote
        }

        await indexer.updateUserMetadata(sessionId: session.id, title: titleValue, comment: commentValue)

        // Update the session in place to preserve sorting and trigger didSet observer
        allSessions = allSessions.map { s in
            guard s.id == session.id else { return s }
            var updated = s
            updated.userTitle = titleValue
            updated.userComment = commentValue
            return updated
        }
        await autoAssignSessionAfterEditIfNeeded(session)
        scheduleApplyFilters()
        cancelEdits()
    }

    func cancelEdits() {
        editingSession = nil
        editTitle = ""
        editComment = ""
    }
}
