import Foundation
import OSLog

@MainActor
extension SessionListViewModel {
    private static let projectLogger = Logger(subsystem: "io.umate.codmate", category: "SessionListVM.ProjectCounts")
    static let otherProjectId = "__other__"
    func loadProjects() async {
        var list = await projectsStore.listProjects()
        if list.isEmpty {
            let cfg = await configService.listProjects()
            if !cfg.isEmpty {
                for p in cfg { await projectsStore.upsertProject(p) }
                list = await projectsStore.listProjects()
            }
        }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projects = list
            self.rebuildGeminiProjectHashLookup()
            self.projectStructureVersion &+= 1
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
            self.invalidateProjectVisibleCountsCache()
            self.scheduleApplyFilters()
        }
        await geminiProvider.invalidateProjectMappings()
    }

    func setSelectedProject(_ id: String?) {
        if let id {
            selectedProjectIDs = Set([id])

            // Special behavior for the synthetic Others bucket:
            // when there is no active date filter yet, clicking
            // Others focuses on "today" without changing the
            // Created/Last Updated picker. Independently, we fire
            // a targeted incremental refresh for today across
            // Claude and Gemini so newly created/updated sessions
            // appear under Others quickly.
            if id == Self.otherProjectId {
                if selectedDay == nil, selectedDays.isEmpty {
                    setSelectedDay(Date())
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.refreshIncrementalForClaudeToday()
                    await self.refreshIncrementalForGeminiToday()
                }
            }
        } else {
            selectedProjectIDs.removeAll()
        }
    }

    func setSelectedProjects(_ ids: Set<String>) {
        selectedProjectIDs = ids
    }

    func toggleProjectSelection(_ id: String) {
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        } else {
            selectedProjectIDs.insert(id)
        }
    }

    func assignSessions(to projectId: String?, ids: [String]) async {
        let assignments = ids.compactMap { sessionAssignment(forIdentifier: $0) }
        guard !assignments.isEmpty else { return }
        await projectsStore.assign(sessions: assignments, to: projectId)
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
            self.scheduleApplyFilters()
        }
    }

    func projectCountsFromStore() -> [String: Int] { projectCounts }

    func visibleProjectCountsForDateScope() -> [String: Int] {
        let key = ProjectVisibleKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count,
            membershipVersion: projectMembershipsVersion
        )
        if let cached = cachedProjectVisibleCounts, cached.key == key {
            return cached.value
        }
        var visible: [String: Int] = [:]
        let allowed = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }
        let descriptors = Self.makeDayDescriptors(selectedDays: selectedDays, singleDay: selectedDay)
        let filterByDay = !descriptors.isEmpty

        var other = 0
        for session in allSessions {
            if filterByDay && !matchesDayFilters(session, descriptors: descriptors) {
                continue
            }
            if let pid = projectId(for: session) {
                let allowedSources = allowed[pid] ?? ProjectSessionSource.allSet
                if !allowedSources.contains(session.source.projectSource) { continue }
                visible[pid, default: 0] += 1
            } else {
                other += 1
            }
        }
        if other > 0 { visible[Self.otherProjectId] = other }
        cachedProjectVisibleCounts = (key, visible)
        return visible
    }

    func projectCountsDisplay() -> [String: (visible: Int, total: Int)] {
        var directVisible = visibleProjectCountsForDateScope()
        let directTotal = projectCounts

        // Cold-start smoothing: when sessions尚未加载、visible为空但总数已知，先用总数填充，避免出现 “N/0” 闪烁
        if directVisible.isEmpty, isLoading {
            for (k, v) in directTotal {
                directVisible[k] = v
            }
            Self.projectLogger.log("projectCountsDisplay smoothing with totals only count=\(directTotal.values.reduce(0, +), privacy: .public)")
        }

        // Build cache key
        let visibleKey = ProjectVisibleKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count,
            membershipVersion: projectMembershipsVersion
        )
        let totalCountsHash = directTotal.values.reduce(0) { $0 ^ $1 }
        let cacheKey = ProjectAggregatedKey(
            visibleKey: visibleKey,
            totalCountsHash: totalCountsHash,
            structureVersion: projectStructureVersion
        )

        // Check cache
        if let cached = cachedProjectAggregated, cached.key == cacheKey {
            return cached.value
        }

        // Cache miss - compute aggregated counts
        var children: [String: [String]] = [:]
        for p in projects {
            if let parent = p.parentId { children[parent, default: []].append(p.id) }
        }
        func aggregate(for id: String, using map: inout [String: (Int, Int)]) -> (Int, Int) {
            if let cached = map[id] { return cached }
            var v = directVisible[id] ?? 0
            var t = directTotal[id] ?? 0
            for c in (children[id] ?? []) {
                let (cv, ct) = aggregate(for: c, using: &map)
                v += cv
                t += ct
            }
            map[id] = (v, t)
            return (v, t)
        }
        var memo: [String: (Int, Int)] = [:]
        var out: [String: (visible: Int, total: Int)] = [:]
        for p in projects {
            let (v, t) = aggregate(for: p.id, using: &memo)
            out[p.id] = (v, t)
        }
        // Add synthetic Other bucket
        let otherVisible = directVisible[Self.otherProjectId] ?? 0
        let otherTotal = directTotal[Self.otherProjectId] ?? otherVisible
        if otherVisible > 0 || otherTotal > 0 {
            out[Self.otherProjectId] = (otherVisible, otherTotal)
        }

        // Cache the result
        cachedProjectAggregated = (cacheKey, out)
        return out
    }

    func visibleAllCountForDateScope() -> Int {
        let key = SessionListViewModel.VisibleCountKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count
        )
        if let cached = cachedVisibleCount, cached.key == key {
            return cached.value
        }

        // Cold-start: if sessions尚未加载但缓存覆盖度可用，直接返回缓存总数，避免 0 闪烁。
        if allSessions.isEmpty {
            if let coverage = cacheCoverage {
                cachedVisibleCount = (key, coverage.sessionCount)
                Self.projectLogger.log("visibleAllCount use coverage sessionCount=\(coverage.sessionCount, privacy: .public)")
                return coverage.sessionCount
            }
            if let meta = indexMeta {
                cachedVisibleCount = (key, meta.sessionCount)
                Self.projectLogger.log("visibleAllCount use meta sessionCount=\(meta.sessionCount, privacy: .public)")
                return meta.sessionCount
            }
            Self.projectLogger.log("visibleAllCount no cache available, default 0")
        }

        let descriptors = Self.makeDayDescriptors(selectedDays: selectedDays, singleDay: selectedDay)
        let value: Int
        if descriptors.isEmpty {
            value = allSessions.count
        } else {
            value = allSessions.filter { matchesDayFilters($0, descriptors: descriptors) }.count
        }
        cachedVisibleCount = (key, value)
        Self.projectLogger.log("visibleAllCount computed from sessions count=\(value, privacy: .public) descriptors=\(descriptors.count, privacy: .public)")
        return value
    }

    // Calendar helper: days within the given month that have at least one session
    // belonging to any of the currently selected projects (including descendants), respecting
    // each project's allowed sources. Returns nil when no project is selected.
    func calendarEnabledDaysForSelectedProject(monthStart: Date, dimension: DateDimension) -> Set<Int>? {
        guard !selectedProjectIDs.isEmpty else { return nil }
        let monthKey = monthKey(for: monthStart)

        // Build allowed project set: include descendants of each selected project
        var allowedProjects = Set<String>()
        for pid in selectedProjectIDs {
            allowedProjects.insert(pid)
            allowedProjects.formUnion(collectDescendants(of: pid, in: projects))
        }

        // Resolve allowed sources per project
        let allowedSourcesByProject = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }

        var days: Set<Int> = []
        for session in allSessions {
            if let assigned = projectId(for: session) {
                guard allowedProjects.contains(assigned) else { continue }
                let allowed = allowedSourcesByProject[assigned] ?? ProjectSessionSource.allSet
                if !allowed.contains(session.source.projectSource) { continue }
            } else {
                // Include unassigned only when Other is selected
                guard allowedProjects.contains(Self.otherProjectId) else { continue }
            }
            let bucket = dayIndex(for: session)
            switch dimension {
            case .created:
                guard bucket.createdMonthKey == monthKey else { continue }
                days.insert(bucket.createdDay)
            case .updated:
                let coverageKey = SessionMonthCoverageKey(sessionID: session.id, monthKey: monthKey)
                if let covered = updatedMonthCoverage[coverageKey], !covered.isEmpty {
                    days.formUnion(covered)
                } else if bucket.updatedMonthKey == monthKey {
                    days.insert(bucket.updatedDay)
                }
            }
        }
        return days
    }

    func allSessionsInSameProject(as anchor: SessionSummary) -> [SessionSummary] {
        if let pid = projectId(for: anchor) {
            let allowed = projects.first(where: { $0.id == pid })?.sources ?? ProjectSessionSource.allSet
            return allSessions.filter {
                projectId(for: $0) == pid && allowed.contains($0.source.projectSource)
            }
        }
        return allSessions
    }

    func createOrUpdateProject(_ project: Project) async {
        await projectsStore.upsertProject(project)
        await loadProjects()
    }

    func deleteProject(id: String) async {
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        }
        scheduleApplyFilters()
    }

    func deleteProjectCascade(id: String) async {
        let list = await projectsStore.listProjects()
        let ids = collectDescendants(of: id, in: list) + [id]
        for pid in ids { await projectsStore.deleteProject(id: pid) }
        await loadProjects()
        if !selectedProjectIDs.isDisjoint(with: ids) {
            selectedProjectIDs.subtract(ids)
        }
        scheduleApplyFilters()
    }

    func deleteProjectMoveChildrenUp(id: String) async {
        let list = await projectsStore.listProjects()
        for p in list where p.parentId == id {
            var moved = p
            moved.parentId = nil
            await projectsStore.upsertProject(moved)
        }
        await projectsStore.deleteProject(id: id)
        await loadProjects()
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        }
        scheduleApplyFilters()
    }

    func changeProjectParent(projectId: String, newParentId: String?) async {
        // Don't allow changing the Other synthetic project
        guard projectId != Self.otherProjectId else { return }
        // Don't allow setting Other as a parent
        guard newParentId != Self.otherProjectId else { return }

        let list = await projectsStore.listProjects()
        guard let project = list.first(where: { $0.id == projectId }) else { return }

        // No-op if already has the same parent
        if project.parentId == newParentId { return }

        // Prevent circular dependency: can't make a project its own parent or descendant
        if let newParent = newParentId {
            if newParent == projectId { return }
            let descendants = collectDescendants(of: projectId, in: list)
            if descendants.contains(newParent) { return }
        }

        var updated = project
        updated.parentId = newParentId
        await projectsStore.upsertProject(updated)
        await loadProjects()
    }

    func collectDescendants(of id: String, in list: [Project]) -> [String] {
        var result: [String] = []
        func dfs(_ pid: String) {
            for p in list where p.parentId == pid {
                result.append(p.id)
                dfs(p.id)
            }
        }
        dfs(id)
        return result
    }

    func importMembershipsFromNotesIfNeeded(notes: [String: SessionNote]) async {
        let existing = await projectsStore.membershipsSnapshot()
        if !existing.isEmpty { return }
        var buckets: [String: [SessionAssignment]] = [:]
        for (sid, n) in notes {
            guard let pid = n.projectId else { continue }
            guard let assignment = sessionAssignment(forIdentifier: sid) else { continue }
            buckets[pid, default: []].append(assignment)
        }
        guard !buckets.isEmpty else { return }
        for (pid, entries) in buckets { await projectsStore.assign(sessions: entries, to: pid) }
        let counts = await projectsStore.counts()
        let memberships = await projectsStore.membershipsSnapshot()
        await MainActor.run {
            self.projectCounts = counts
            self.setProjectMemberships(memberships)
            self.recomputeProjectCounts()
        }
    }

    @MainActor
    func recomputeProjectCounts() {
        // Optimize: use visibleProjectCountsForDateScope if it's for current filter state
        // to avoid re-traversing all sessions
        let currentKey = ProjectVisibleKey(
            dimension: dateDimension,
            selectedDay: selectedDay,
            selectedDays: selectedDays,
            sessionCount: allSessions.count,
            membershipVersion: projectMembershipsVersion
        )

        // If we have cached visible counts for current state, reuse them as total counts
        // (when no date filter is active)
        if selectedDay == nil && selectedDays.isEmpty,
           let cached = cachedProjectVisibleCounts, cached.key == currentKey {
            projectCounts = cached.value
            return
        }

        // Otherwise compute from scratch
        var counts: [String: Int] = [:]
        var other = 0
        let allowed = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
            $0[$1.id] = $1.sources
        }
        for session in allSessions {
            if let pid = projectId(for: session) {
                let allowedSources = allowed[pid] ?? ProjectSessionSource.allSet
                if allowedSources.contains(session.source.projectSource) {
                    counts[pid, default: 0] += 1
                }
            } else {
                other += 1
            }
        }
        if other > 0 { counts[Self.otherProjectId] = other }
        projectCounts = counts
    }

    func requestProjectExpansion(for projectId: String) {
        let chain = projectAncestorChain(projectId: projectId)
        guard !chain.isEmpty else { return }
        NotificationCenter.default.post(
            name: .codMateExpandProjectTree,
            object: nil,
            userInfo: ["ids": chain]
        )
    }

    private func projectAncestorChain(projectId: String) -> [String] {
        guard !projects.isEmpty else { return [] }
        var map: [String: Project] = [:]
        for p in projects { map[p.id] = p }
        var chain: [String] = []
        var current: String? = projectId
        while let id = current, let project = map[id] {
            chain.insert(project.id, at: 0)
            current = project.parentId
        }
        return chain
    }
}
