# Tasks 模式与 Timeline 性能优化计划

## 背景

基于 `overview-rework-plan.md` 建立的缓存索引系统，本计划旨在将相同的性能优化理念扩展到：
1. **Tasks 模式**：优化 Sessions/Tasks List 的刷新性能
2. **Timeline**：优化对话记录的加载和增量更新

## 当前架构分析

### Tasks 模式现状

**数据流**：
```
SessionListViewModel.refreshSessions()
  ├─ buildProviders() → [SessionProvider]
  ├─ loadProviders(cacheContext: .cacheOnly) → 从 SQLite 缓存快速加载
  ├─ loadProviders(refreshContext: .refresh) → 完整扫描文件系统
  └─ applyFilters() → 过滤、排序、分组为 SessionDaySection
```

**性能瓶颈**：
- 即使只选中单个会话，刷新时仍会扫描整个 scope（项目/日期组合）
- 文件监控触发时执行完整的 scope 刷新，无法针对单个变更文件
- 选中会话详情查看时，没有针对性的增量刷新机制

### Timeline 现状

**加载流程**：
```
SessionDetailView.initialLoadAndMonitor()
  ├─ reloadConversation(resetUI: true)
  │  ├─ SessionTimelineLoader.load(url) → 完整解析 JSONL 文件
  │  └─ group(events) → 分组为 ConversationTurn
  ├─ applyFilterAndSort() → 搜索/排序/可见性筛选
  └─ DirectoryMonitor 监听文件变化 (300ms 防抖)
     └─ 触发完整 reloadConversation()
```

**性能瓶颈**：
- 每次加载都完整解析整个会话文件（可能数 MB）
- 文件变化时完整重新加载，即使只追加了几行
- 没有缓存折叠状态的预览信息，每次展开都需要重新渲染
- 大型会话（>1000 turns）加载缓慢，UI 有明显延迟

## 优化方案

### 一、Tasks 模式优化

#### 1.1 选中会话的智能增量刷新

**目标**：当用户选中特定会话时，优先刷新这些会话，避免全 scope 扫描。

**实现设计**：

```swift
// SessionListViewModel 新增方法
func refreshSelectedSessions(
    sessionIds: Set<String>,
    force: Bool = false
) async {
    // 1. 从 SQLite 获取这些会话的缓存记录
    let cached = await indexer.fetchRecords(sessionIds: sessionIds)

    // 2. 检查文件 mtime 变化
    var needsRefresh: [String: URL] = [:]
    for (id, record) in cached {
        let fileURL = record.summary.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            needsRefresh[id] = fileURL
            continue
        }

        if let cachedMtime = record.fileModificationTime,
           abs(mtime.timeIntervalSince(cachedMtime)) < 1.0 {
            // 缓存有效，跳过
            continue
        }
        needsRefresh[id] = fileURL
    }

    // 3. 仅重新解析变化的文件
    if !needsRefresh.isEmpty {
        await indexer.reindexFiles(Array(needsRefresh.values))

        // 4. 更新 allSessions 中的对应项
        let refreshed = await indexer.fetchRecords(sessionIds: Set(needsRefresh.keys))
        updateSessions(with: refreshed)

        // 5. 重新应用过滤（仅影响这些会话）
        scheduleFiltersUpdate()
    }
}

// 在选中会话变化时触发
@Published var selection: Set<SessionSummary.ID> = [] {
    didSet {
        if !selection.isEmpty {
            scheduleSelectedSessionsRefresh()
        }
    }
}

private func scheduleSelectedSessionsRefresh() {
    selectedSessionsRefreshTask?.cancel()
    selectedSessionsRefreshTask = Task {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms 防抖
        await refreshSelectedSessions(sessionIds: selection)
    }
}
```

**关键优势**：
- 避免全 scope 文件系统扫描
- 利用 SQLite 缓存的 mtime 快速判断变更
- 仅重新解析变化的文件（通常 0-2 个）
- 不影响现有的 scope 刷新机制

#### 1.2 文件监控的精细化触发

**目标**：DirectoryMonitor 检测到变化时，判断是否为选中会话的文件，仅刷新相关项。

**实现设计**：

```swift
// 扩展 DirectoryMonitor 返回变更的文件路径
final class DirectoryMonitor {
    var changedPathsHandler: (([URL]) -> Void)?

    // 内部追踪变更的文件
    private var pendingChangedPaths: Set<URL> = []
}

// SessionListViewModel 中精细化处理
private func scheduleDirectoryRefresh() {
    fileEventAggregationTask?.cancel()
    fileEventAggregationTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms 聚合

        // 1. 获取变更的文件路径
        let changedPaths = await directoryMonitor.getChangedPaths()

        // 2. 判断是否为选中会话
        let selectedURLs = selection.compactMap { id in
            allSessions.first(where: { $0.id == id })?.fileURL
        }

        let affectsSelection = !Set(changedPaths).isDisjoint(with: Set(selectedURLs))

        // 3. 针对性刷新
        if affectsSelection {
            // 仅刷新选中会话
            await refreshSelectedSessions(sessionIds: selection, force: true)
        } else {
            // 刷新当前 scope（保持现有行为）
            scheduleFilterRefresh(force: true)
        }
    }
}
```

#### 1.3 SQLite 查询优化

**目标**：为 Tasks 模式的项目/日期组合查询添加复合索引。

**实现设计**：

```sql
-- 新增复合索引（在 SessionIndexSQLiteStore 的 schema 中）
CREATE INDEX IF NOT EXISTS idx_sessions_project_updated
    ON sessions(project, last_updated_at DESC)

CREATE INDEX IF NOT EXISTS idx_sessions_project_started
    ON sessions(project, started_at DESC)

-- 优化查询：按项目 + 日期范围快速检索
SELECT session_id, file_path, file_mtime, file_size
FROM sessions
WHERE project IN (?, ?, ?)
  AND last_updated_at BETWEEN ? AND ?
ORDER BY last_updated_at DESC
```

**性能提升**：
- 从 O(n) 全表扫描降低到 O(log n) 索引查找
- 内存占用降低（无需加载全部记录）
- 支持大规模会话场景（>10,000 sessions）

---

### 二、Timeline 优化

#### 2.1 折叠预览缓存系统

**目标**：缓存每个对话回合折叠时的预览信息，实现"先显示预览，后加载详情"。

**数据模型**：

```swift
// 轻量级预览结构
struct ConversationTurnPreview: Identifiable, Hashable, Sendable {
    let id: String  // 与 ConversationTurn 相同的稳定 ID
    let timestamp: Date
    let turnIndex: Int

    // 预览文本（折叠时显示）
    let userPreview: String?        // 用户消息前 100 字符
    let outputsPreview: String?     // 助手回复前 100 字符
    let outputCount: Int            // 输出事件数量

    // 元数据
    let hasToolCalls: Bool
    let hasThinking: Bool
}

// SQLite 新表
CREATE TABLE IF NOT EXISTS timeline_previews (
    session_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    turn_index INTEGER NOT NULL,
    timestamp REAL NOT NULL,
    user_preview TEXT,
    outputs_preview TEXT,
    output_count INTEGER NOT NULL,
    has_tool_calls INTEGER NOT NULL,
    has_thinking INTEGER NOT NULL,
    file_mtime REAL NOT NULL,
    file_size INTEGER,
    PRIMARY KEY (session_id, turn_id),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
)

CREATE INDEX IF NOT EXISTS idx_timeline_previews_session
    ON timeline_previews(session_id, turn_index)
```

**加载流程**：

```swift
// SessionDetailView 状态管理
@State private var previewTurns: [ConversationTurnPreview] = []  // 快速预览
@State private var fullTurns: [ConversationTurn] = []            // 完整数据
@State private var loadingStage: LoadingStage = .preview

enum LoadingStage {
    case preview      // 仅显示预览
    case loading      // 加载中
    case full         // 完整加载
}

private func initialLoadAndMonitor() async {
    // 阶段 1: 立即从 SQLite 加载预览（<10ms）
    let previews = await viewModel.loadTimelinePreviews(for: summary)
    await MainActor.run {
        previewTurns = previews
        loadingStage = .preview
    }

    // 阶段 2: 后台加载完整数据
    loadingStage = .loading
    let full = await loadFullTimeline()

    // 阶段 3: 替换为完整数据
    await MainActor.run {
        fullTurns = full
        allTurns = full
        loadingStage = .full
    }

    // 阶段 4: 更新预览缓存（如果文件有变化）
    await updatePreviewCacheIfNeeded(turns: full)

    // 阶段 5: 设置文件监控
    setupFileMonitor()
}
```

**UI 渲染**：

```swift
var body: some View {
    ScrollView {
        LazyVStack {
            ForEach(displayTurns) { turn in
                if loadingStage == .preview {
                    // 显示轻量级预览卡片
                    ConversationTurnPreviewCard(preview: turn)
                } else {
                    // 显示完整卡片（支持展开）
                    ConversationTurnRow(turn: turn, expanded: expandedTurnIDs.contains(turn.id))
                }
            }
        }
    }
    .overlay {
        if loadingStage == .loading {
            ProgressView("Loading full timeline...")
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(8)
        }
    }
}
```

**性能收益**：
- 初始渲染时间从 500ms 降低到 <50ms（大型会话）
- 用户感知延迟显著降低（立即看到内容）
- 网络同步场景友好（远程会话）

#### 2.2 增量更新机制

**目标**：文件变化时只重新解析新增部分，避免完整重新加载。

**追加检测算法**：

```swift
actor IncrementalTimelineLoader {
    private var loadState: [String: FileLoadState] = [:]

    struct FileLoadState {
        let fileSize: UInt64
        let eventCount: Int
        let lastTurnID: String?
    }

    func loadIncremental(
        url: URL,
        previousState: FileLoadState?
    ) throws -> IncrementalLoadResult {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let currentSize = attrs[.size] as? UInt64 else {
            throw TimelineError.invalidFileSize
        }

        // 判断是否为追加
        guard let prev = previousState, currentSize > prev.fileSize else {
            // 文件缩小或首次加载 → 完整加载
            let events = try decodeEvents(url: url)
            let turns = group(events: events)
            return .full(turns, state: FileLoadState(
                fileSize: currentSize,
                eventCount: events.count,
                lastTurnID: turns.last?.id
            ))
        }

        // 增量加载：只读取新增部分
        let newBytes = currentSize - prev.fileSize
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: prev.fileSize)
        let appendedData = handle.readData(ofLength: Int(newBytes))

        // 解析新增事件
        let newEvents = try decodeEvents(data: appendedData)

        // 重新分组最后几个回合（可能跨越边界）
        // 策略：取最后 3 个已有回合 + 新事件，重新分组
        return .incremental(
            newEvents: newEvents,
            affectedTurnIDs: Set([prev.lastTurnID].compactMap { $0 }),
            newState: FileLoadState(
                fileSize: currentSize,
                eventCount: prev.eventCount + newEvents.count,
                lastTurnID: nil  // 需要重新分组后才知道
            )
        )
    }
}

enum IncrementalLoadResult {
    case full([ConversationTurn], state: FileLoadState)
    case incremental(newEvents: [TimelineEvent], affectedTurnIDs: Set<String>, newState: FileLoadState)
}
```

**UI 增量更新**：

```swift
private func reloadConversation() async {
    let result = try? await incrementalLoader.loadIncremental(
        url: summary.fileURL,
        previousState: currentLoadState
    )

    switch result {
    case .full(let turns, let state):
        // 完整替换
        allTurns = turns
        currentLoadState = state
        applyFilterAndSort()

    case .incremental(let newEvents, let affectedIDs, let state):
        // 增量更新
        let loader = SessionTimelineLoader()

        // 1. 保留不受影响的回合
        let unaffected = allTurns.filter { !affectedIDs.contains($0.id) }

        // 2. 重新分组受影响的回合 + 新事件
        let affectedEvents = allTurns
            .filter { affectedIDs.contains($0.id) }
            .flatMap { [$0.userMessage].compactMap { $0 } + $0.outputs }
        let regrouped = loader.group(events: affectedEvents + newEvents)

        // 3. 合并
        allTurns = unaffected + regrouped
        currentLoadState = state

        // 4. 仅对新/变更的回合应用过滤
        let newTurnIDs = Set(regrouped.map(\.id))
        updateFilteredTurns(affectedIDs: newTurnIDs)

        // 5. 高亮新增内容（可选）
        highlightNewTurns(newTurnIDs)
    }
}

// 高亮新内容（视觉反馈）
@State private var newlyAddedTurnIDs: Set<String> = []

private func highlightNewTurns(_ ids: Set<String>) {
    newlyAddedTurnIDs = ids
    Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2秒后移除高亮
        newlyAddedTurnIDs.removeAll()
    }
}
```

**视觉指示**：

```swift
ConversationTurnRow(turn: turn)
    .overlay(alignment: .trailing) {
        if newlyAddedTurnIDs.contains(turn.id) {
            Label("New", systemImage: "sparkles")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(4)
                .background(.thinMaterial)
                .cornerRadius(4)
                .transition(.scale.combined(with: .opacity))
        }
    }
```

**性能收益**：
- 活跃会话（正在进行的对话）更新时间从 500ms 降低到 <50ms
- 避免滚动位置重置（保持用户阅读状态）
- 降低 CPU 占用（减少解析和渲染）

#### 2.3 异步预加载策略

**目标**：结合预览缓存和增量更新，实现最优的加载体验。

**多级缓存架构**：

```
Level 1: SQLite timeline_previews (持久化)
         ↓ 10ms
Level 2: 内存预览缓存 (NSCache)
         ↓ 1ms
Level 3: 完整数据 (按需加载)
         ↓ 100-500ms
```

**智能预加载**：

```swift
actor TimelinePreloadManager {
    private var preloadQueue: [SessionSummary.ID] = []
    private var preloadedSessions: [SessionSummary.ID: [ConversationTurn]] = [:]
    private let maxCacheSize = 5

    func schedulePreload(for sessionIds: [SessionSummary.ID]) {
        // 预测用户可能查看的会话（例如列表中上下相邻的）
        preloadQueue = Array(sessionIds.prefix(maxCacheSize))
        Task {
            await performPreload()
        }
    }

    private func performPreload() async {
        for sessionId in preloadQueue {
            guard preloadedSessions[sessionId] == nil else { continue }
            // 后台低优先级加载
            if let turns = await loadTimeline(sessionId: sessionId) {
                preloadedSessions[sessionId] = turns

                // LRU 清理
                if preloadedSessions.count > maxCacheSize {
                    let oldest = preloadedSessions.keys.first!
                    preloadedSessions.removeValue(forKey: oldest)
                }
            }
        }
    }

    func getCached(for sessionId: SessionSummary.ID) -> [ConversationTurn]? {
        preloadedSessions[sessionId]
    }
}
```

---

### 三、架构增强

#### 3.1 缓存失效策略

**文件变更检测**：
- 使用 `mtime + fileSize` 二元组判断缓存有效性
- 变更触发时：
  1. 删除对应的 timeline_previews 记录
  2. 重新解析文件并更新缓存
  3. 通知 UI 刷新

**缓存清理接口**：

```swift
// 在 Settings 中提供清理选项
func clearTimelineCache() async {
    await sqliteStore.exec("DELETE FROM timeline_previews")
    // 保留 sessions 表（Overview 仍需要）
}

func rebuildTimelineCache(for sessionIds: [String]? = nil) async {
    // 重新解析指定会话（或全部）并构建预览缓存
}
```

#### 3.2 错误处理与降级

**缓存损坏降级**：

```swift
func loadTimelinePreviews(for summary: SessionSummary) async -> [ConversationTurnPreview] {
    do {
        return try await sqliteStore.fetchTimelinePreviews(sessionId: summary.id)
    } catch {
        logger.warning("Failed to load timeline previews: \(error). Falling back to full load.")
        // 降级到完整加载
        let full = await loadFullTimeline(for: summary)
        // 异步更新缓存
        Task {
            await rebuildPreviewCache(for: summary, from: full)
        }
        return full.map { $0.toPreview() }
    }
}
```

**解析错误处理**：

```swift
private func decodeEvents(data: Data) throws -> [TimelineEvent] {
    var events: [TimelineEvent] = []
    var failedLines = 0

    for line in data.split(separator: 0x0A) {
        do {
            let row = try decoder.decode(SessionRow.self, from: Data(line))
            if let event = makeEvent(from: row) {
                events.append(event)
            }
        } catch {
            failedLines += 1
            if failedLines > 10 {
                // 连续失败超过阈值，认为文件损坏
                throw TimelineError.corruptedFile
            }
        }
    }

    return events
}
```

#### 3.3 性能监控与日志

**关键指标追踪**：

```swift
struct TimelineLoadMetrics {
    let sessionId: String
    let loadStrategy: String  // "preview", "full", "incremental"
    let duration: TimeInterval
    let turnCount: Int
    let fileSize: UInt64
    let cacheHit: Bool
}

private func logMetrics(_ metrics: TimelineLoadMetrics) {
    diagLogger.log("""
        Timeline load: \
        sessionId=\(metrics.sessionId) \
        strategy=\(metrics.loadStrategy) \
        duration=\(metrics.duration, format: .fixed(precision: 3))s \
        turns=\(metrics.turnCount) \
        fileSize=\(metrics.fileSize) \
        cacheHit=\(metrics.cacheHit)
        """)
}
```

---

## 实施计划

### 阶段 1: Tasks 模式优化（优先级：高）

**任务清单**：

1. **单会话增量刷新**
   - [ ] 在 SessionListViewModel 添加 `refreshSelectedSessions()` 方法
   - [ ] 实现选中状态变化的防抖触发
   - [ ] 扩展 SessionIndexer 支持 `reindexFiles([URL])`
   - [ ] 测试：选中会话后文件变更仅刷新该会话

2. **文件监控精细化**
   - [ ] 扩展 DirectoryMonitor 返回变更文件路径
   - [ ] 在 SessionListViewModel 判断变更是否影响选中会话
   - [ ] 实现针对性刷新逻辑
   - [ ] 测试：非选中会话变更不触发完整刷新

3. **SQLite 查询优化**
   - [ ] 添加复合索引（project + updated_at/started_at）
   - [ ] 测试：大规模场景（>10K sessions）查询性能
   - [ ] 验证内存占用降低

**验收标准**：
- 选中单个会话时，刷新耗时 < 50ms（vs 现状 200-500ms）
- 文件变更仅触发受影响会话的刷新
- 大规模场景（10K+ sessions）内存占用 < 500MB

---

### 阶段 2: Timeline 预览缓存（优先级：高）

**任务清单**：

1. **数据模型与存储**
   - [ ] 定义 `ConversationTurnPreview` 结构
   - [ ] 在 SessionIndexSQLiteStore 添加 `timeline_previews` 表
   - [ ] 实现 `fetchTimelinePreviews()` 和 `upsertTimelinePreviews()` 方法
   - [ ] 实现缓存失效检测（mtime 匹配）

2. **加载流程改造**
   - [ ] SessionDetailView 添加 `previewTurns` 状态
   - [ ] 实现三阶段加载（preview → loading → full）
   - [ ] 创建 `ConversationTurnPreviewCard` 轻量级组件
   - [ ] 后台异步加载完整数据并更新缓存

3. **UI 反馈**
   - [ ] 添加加载阶段指示器
   - [ ] 预览卡片的骨架屏设计
   - [ ] 平滑过渡动画（preview → full）

**验收标准**：
- 初始渲染时间 < 50ms（大型会话 1000+ turns）
- 用户感知无延迟（立即看到预览）
- 缓存命中率 > 90%（正常使用场景）

---

### 阶段 3: Timeline 增量更新（优先级：中）

**任务清单**：

1. **增量加载器**
   - [ ] 创建 `IncrementalTimelineLoader` actor
   - [ ] 实现追加检测算法（fileSize 比较）
   - [ ] 实现增量解析（从 offset 读取）
   - [ ] 处理边界回合重新分组

2. **UI 增量更新**
   - [ ] SessionDetailView 集成增量加载
   - [ ] 实现受影响回合的局部更新
   - [ ] 保持滚动位置和 UI 状态
   - [ ] 添加新内容高亮指示器

3. **测试与优化**
   - [ ] 模拟活跃会话（持续追加）
   - [ ] 验证边界情况（回合跨越边界）
   - [ ] 性能对比（增量 vs 完整加载）

**验收标准**：
- 活跃会话更新时间 < 50ms（vs 现状 500ms）
- 滚动位置保持不变
- 新内容视觉提示明确

---

### 阶段 4: 预加载与性能调优（优先级：低）

**任务清单**：

1. **智能预加载**
   - [ ] 创建 `TimelinePreloadManager`
   - [ ] 实现相邻会话预加载策略
   - [ ] LRU 缓存管理
   - [ ] 低优先级后台任务

2. **性能监控**
   - [ ] 添加 Timeline 加载指标
   - [ ] 日志记录（策略、耗时、缓存命中）
   - [ ] 性能分析工具集成

3. **用户控制**
   - [ ] Settings 中添加缓存清理选项
   - [ ] 缓存大小/策略配置
   - [ ] 诊断信息展示

**验收标准**：
- 预加载命中率 > 50%（连续浏览场景）
- 提供完善的诊断和控制选项

---

## 性能目标总结

| 场景 | 现状 | 目标 | 提升 |
|-----|------|------|------|
| Tasks 选中会话刷新 | 200-500ms | <50ms | **4-10x** |
| Timeline 初始加载（大型） | 500ms | <50ms | **10x** |
| Timeline 增量更新 | 500ms | <50ms | **10x** |
| 大规模查询内存占用 | 1GB+ | <500MB | **2x+** |
| 缓存命中率 | 0% | >90% | **新增** |

---

## 风险与缓解

### 风险 1: 缓存一致性问题

**场景**：文件在外部被修改，但 mtime 未更新（例如 `touch -r` 命令）

**缓解**：
- 提供手动"清理缓存"选项
- 添加文件 size 二次校验
- 定期后台验证缓存完整性

### 风险 2: 增量更新边界情况

**场景**：文件追加导致回合跨越边界，增量分组出错

**缓解**：
- 保守策略：重新分组最后 3-5 个回合
- 完整性校验：比对 turn count 是否合理
- 降级机制：检测异常时回退到完整加载

### 风险 3: SQLite 迁移

**场景**：新增 `timeline_previews` 表需要数据库迁移

**缓解**：
- 使用 `IF NOT EXISTS` 创建表
- 版本号管理（schemaVersion = 2）
- 向后兼容：旧版本忽略新表

---

## 附录

### A. 数据库 Schema 完整定义

```sql
-- 现有 sessions 表保持不变

-- 新增 timeline_previews 表
CREATE TABLE IF NOT EXISTS timeline_previews (
    session_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    turn_index INTEGER NOT NULL,
    timestamp REAL NOT NULL,
    user_preview TEXT,
    outputs_preview TEXT,
    output_count INTEGER NOT NULL DEFAULT 0,
    has_tool_calls INTEGER NOT NULL DEFAULT 0,
    has_thinking INTEGER NOT NULL DEFAULT 0,
    file_mtime REAL NOT NULL,
    file_size INTEGER,
    created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
    PRIMARY KEY (session_id, turn_id)
);

CREATE INDEX IF NOT EXISTS idx_timeline_previews_session
    ON timeline_previews(session_id, turn_index);

CREATE INDEX IF NOT EXISTS idx_timeline_previews_mtime
    ON timeline_previews(file_mtime);

-- 新增复合索引
CREATE INDEX IF NOT EXISTS idx_sessions_project_updated
    ON sessions(project, last_updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_project_started
    ON sessions(project, started_at DESC);
```

### B. 关键 API 接口

```swift
// SessionListViewModel
func refreshSelectedSessions(sessionIds: Set<String>, force: Bool = false) async

// SessionIndexer
func reindexFiles(_ urls: [URL]) async throws -> [SessionSummary]

// SessionIndexSQLiteStore
func fetchTimelinePreviews(sessionId: String) throws -> [ConversationTurnPreview]
func upsertTimelinePreviews(_ previews: [ConversationTurnPreview], sessionId: String) throws

// IncrementalTimelineLoader
func loadIncremental(url: URL, previousState: FileLoadState?) throws -> IncrementalLoadResult

// TimelinePreloadManager
func schedulePreload(for sessionIds: [SessionSummary.ID])
func getCached(for sessionId: SessionSummary.ID) -> [ConversationTurn]?
```

---

**文档版本**: 1.0
**创建日期**: 2025-12-05
**作者**: Claude (Sonnet 4.5)
**基于**: `overview-rework-plan.md` 的缓存索引系统
