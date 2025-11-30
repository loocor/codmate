import Foundation

@MainActor
extension SessionListViewModel {
    func recordIntentForDetailNew(anchor: SessionSummary) {
        guard let pid = projectIdForSession(anchor.id) else { return }
        let hints = PendingAssignIntent.Hints(
            model: anchor.model,
            sandbox: preferences.resumeOptions.flagSandboxRaw,
            approval: preferences.resumeOptions.flagApprovalRaw
        )
        recordIntent(projectId: pid, expectedCwd: anchor.cwd, hints: hints)
    }

    func recordIntentForProjectNew(project: Project) {
        let expected =
            (project.directory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? NSHomeDirectory()
        let hints = PendingAssignIntent.Hints(
            model: project.profile?.model,
            sandbox: project.profile?.sandbox?.rawValue ?? preferences.resumeOptions.flagSandboxRaw,
            approval: project.profile?.approval?.rawValue
                ?? preferences.resumeOptions.flagApprovalRaw
        )
        recordIntent(projectId: project.id, expectedCwd: expected, hints: hints)
    }
}

extension SessionListViewModel {
    func handleAutoAssignIfMatches(_ s: SessionSummary) {
        guard !pendingAssignIntents.isEmpty else { return }
        let canonical = Self.canonicalPath(s.cwd)
        let candidates = pendingAssignIntents.filter { intent in
            guard canonical == intent.expectedCwd else { return false }
            let windowStart = intent.t0.addingTimeInterval(-2)
            let windowEnd = intent.t0.addingTimeInterval(60)
            return s.startedAt >= windowStart && s.startedAt <= windowEnd
        }
        guard !candidates.isEmpty else { return }
        struct Scored {
            let intent: PendingAssignIntent
            let score: Int
            let timeAbs: TimeInterval
        }
        var scored: [Scored] = []
        for it in candidates {
            var score = 0
            if let m = it.hints.model, let sm = s.model, !m.isEmpty, m == sm { score += 1 }
            if let a = it.hints.approval, let sa = s.approvalPolicy, !a.isEmpty, a == sa {
                score += 1
            }
            let timeAbs = abs(s.startedAt.timeIntervalSince(it.t0))
            scored.append(Scored(intent: it, score: score, timeAbs: timeAbs))
        }
        guard
            let best = scored.max(by: { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.timeAbs > rhs.timeAbs
            })
        else { return }
        let topScore = best.score
        let topTime = best.timeAbs
        let dupCount = scored.filter { $0.score == topScore && abs($0.timeAbs - topTime) < 0.001 }
            .count
        if dupCount > 1 {
            Task {
                await SystemNotifier.shared.notify(
                    title: "CodMate", body: "Assign to \(best.intent.projectId)?")
            }
            return
        }
        Task {
            let assignment = SessionAssignment(id: s.id, source: s.source.projectSource)
            await projectsStore.assign(sessions: [assignment], to: best.intent.projectId)
            let counts = await projectsStore.counts()
            let memberships = await projectsStore.membershipsSnapshot()
            await MainActor.run {
                self.projectCounts = counts
                self.setProjectMemberships(memberships)
                self.recomputeProjectCounts()
                self.scheduleApplyFilters()
            }
            await SystemNotifier.shared.notify(
                title: "CodMate", body: "Assigned to \(best.intent.projectId)")
        }
        pendingAssignIntents.removeAll { $0.id == best.intent.id }
    }

    func pruneExpiredIntents() {
        let now = Date()
        pendingAssignIntents.removeAll { now.timeIntervalSince($0.t0) > 60 }
    }

    func recordIntent(
        projectId: String, expectedCwd: String, hints: PendingAssignIntent.Hints
    ) {
        if !preferences.autoAssignNewToSameProject { return }
        let canonical = Self.canonicalPath(expectedCwd)
        pendingAssignIntents.append(
            PendingAssignIntent(
                projectId: projectId,
                expectedCwd: canonical,
                t0: Date(),
                hints: hints
            ))
        pruneExpiredIntents()
    }
}
