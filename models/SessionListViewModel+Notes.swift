import Foundation

@MainActor
extension SessionListViewModel {
    func timelineVisibleKindsOverride(for sessionId: String) -> Set<MessageVisibilityKind>? {
        let raw = notesSnapshot[sessionId]?.timelineVisibleKinds
        return Set<MessageVisibilityKind>.fromRawValues(raw)
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
