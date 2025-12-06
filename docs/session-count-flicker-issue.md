# Session 计数闪变问题 - 完整诊断报告

## 问题现象

### 主要症状
1. **计数闪变**: 按下 Cmd+R 刷新时，sessions list 中部分 session item 的底部计数（tools、thinking、messages）会闪变到另一个数值再变回原数值
2. **计数错误**: 部分 session item 显示的计数明显错误
   - 例如：标记1处显示 1 条消息，但标记2处（会话详情）实际有 41 条消息
   - 例如：某个会话显示 74 个工具调用，但实际文件中有 190 个

### 具体案例
**问题文件**: `/Users/loocor/.codex/sessions/2025/12/05/rollout-2025-12-05T10-49-56-019aec6a-8825-7e33-9790-d220bfb1a4b5.jsonl`

**验证命令**:
```bash
grep '"type":"response_item"' file.jsonl | jq 'select(.payload.type | contains("tool_call") or contains("function_call"))' | wc -l
# 结果: 190 (实际工具调用数)
```

**UI 显示**:
- 静止时显示: 74 个工具调用
- 刷新时闪变: 74 → 190 → 74

### 影响范围
- 最初：所有 codex session item 的 toolsCall 计数都闪变
- 修复后：部分小文件不再闪变（估计文件较小无差异），但大文件仍然有问题

## 架构分析

### 解析策略
CodMate 使用两种解析策略：

#### 1. Fast Parse (buildSummaryFast)
- **位置**: `SessionIndexer.swift:901-947`
- **逻辑**: 只读文件前 **64 行**
- **用途**: 快速获取基本元数据（id, startedAt, cwd 等）
- **限制**: 对于大文件，计数不完整

```swift
private func buildSummaryFast(for url: URL, builder: inout SessionSummaryBuilder) throws -> SessionSummary? {
  let fastLineLimit = 64  // 只读64行！
  for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
    if lineCount >= fastLineLimit, builder.hasEssentialMetadata {
      break  // 在64行处停止
    }
    let row = try decoder.decode(SessionRow.self, from: Data(slice))
    builder.observe(row)
    lineCount += 1
  }
  // ... 如果无法构建完整 summary，fallback 到 buildSummaryFull
  if let result = builder.build(for: url) { return result }
  return try buildSummaryFull(for: url, builder: &builder)
}
```

#### 2. Full Parse (buildSummaryFull)
- **位置**: `SessionIndexer.swift:954-976`
- **逻辑**: 读取整个文件，统计所有事件
- **用途**: 获取准确的完整计数
- **成本**: 较慢，消耗更多资源

### 刷新流程

```
用户按 Cmd+R
  ↓
SessionListViewModel.refreshSessions() (line 686)
  ↓
loadProviders() with cachePolicy: .refresh (line 751)
  ↓
SessionIndexer.refreshSessions() (line 40)
  ↓
buildSummaryFast() (line 264) ← 问题点：使用 fast parse！
  ↓
sqliteStore.upsert() (line 272)
  ↓
dedupProviderSessions() (line 1011)
  ↓
preferSession() (line 1024) ← 去重逻辑选择哪个版本
  ↓
smartMergeAllSessions() (line 2485) ← 合并新旧数据
  ↓
UI 更新
```

## 根本原因分析

### 核心问题
**SessionIndexer.swift:264** 在 `refreshSessions` 中使用 `buildSummaryFast`：
```swift
guard let summary = try await self.buildSummaryFast(for: url, builder: &builder)
else { return .success(nil) }
```

这导致：
1. 刷新时生成的 summary 只包含前64行的数据（不完整）
2. 这个不完整的数据被标记为 `parse_level: "metadata"` 或之前错误标记为 `"full"`
3. 保存到 SQLite 缓存
4. 与已有的完整数据去重时，可能选择了不完整的版本

### 去重逻辑问题
**SessionListViewModel.swift:1024** 的 `preferSession` 方法需要在多个版本间选择：
- 来自缓存的完整数据（190 tools）
- 来自刷新的不完整数据（74 tools）

原始逻辑主要依赖时间戳和文件大小，没有充分考虑数据完整性。

### 合并逻辑问题
**SessionListViewModel.swift:2485** 的 `smartMergeAllSessions` 尝试检测数据变化，但：
- 如果文件未变化但计数减少，应保留旧数据
- 但实际执行中仍可能被不完整数据覆盖

## 已尝试的修复

### 修复 1: 添加 parse_level 字段到 SQLite
**文件**: `services/SessionIndexSQLiteStore.swift:570-573`

```sql
ALTER TABLE sessions ADD COLUMN parse_level TEXT DEFAULT 'metadata';
ALTER TABLE sessions ADD COLUMN parsed_at REAL;
CREATE INDEX IF NOT EXISTS idx_sessions_parse_level ON sessions(parse_level);
```

**目的**: 跟踪每条记录的解析级别（metadata/full/enriched）

### 修复 2: 正确标记 parse_level
**文件**: `services/SessionIndexer.swift:279`

```swift
try await self.sqliteStore.upsert(
  summary: summary,
  project: nil,
  fileModificationTime: modificationDate,
  fileSize: fileSize.flatMap { UInt64($0) },
  tokenBreakdown: nil,
  parseError: nil,
  parseLevel: "metadata")  // 明确标记为 metadata
```

**文件**: `services/SessionIndexer.swift:1026` (enriched parse)
```swift
parseLevel: "enriched"  // 完整解析 + activeDuration 计算
```

### 修复 3: 增强 preferSession 去重逻辑
**文件**: `models/SessionListViewModel.swift:1032-1044`

```swift
// 如果文件大小匹配（同一文件），优先选择计数更多的版本
if ls > 0 && ls == rs {
  let lhsTotal = lhs.userMessageCount + lhs.assistantMessageCount + lhs.toolInvocationCount
  let rhsTotal = rhs.userMessageCount + rhs.assistantMessageCount + rhs.toolInvocationCount
  if lhsTotal != rhsTotal {
    return lhsTotal > rhsTotal ? lhs : rhs  // 优先选择数据更丰富的版本
  }
  // 如果计数相等，也检查 lineCount 作为完整性指标
  if lhs.lineCount != rhs.lineCount {
    return lhs.lineCount > rhs.lineCount ? lhs : rhs
  }
}
```

**关键改进**: 放宽了条件，只要文件大小匹配就比较计数，不再要求时间戳完全相等。

### 修复 4: 数据迁移清理错误记录
**文件**: `services/SessionIndexSQLiteStore.swift:575-581`

```sql
-- 修复错误标记的 parse_level='full' 记录
-- 启发式规则：如果 lineCount < 100 且标记为 'full'，很可能是 fast parse 的结果
UPDATE sessions SET parse_level = 'metadata' WHERE parse_level = 'full' AND line_count < 100;

-- 重置所有没有 parsed_at 时间戳的 'full' 记录
UPDATE sessions SET parse_level = 'metadata' WHERE parse_level = 'full' AND parsed_at IS NULL;
```

### 修复 5: 增强 smartMergeAllSessions
**文件**: `models/SessionListViewModel.swift:2485-2545`

```swift
// 检测快速解析（计数减少但文件未变）
let fileUnchanged = fileSizeMatches && lastUpdatedMatches
let anyCountDecreased = (
  newSession.userMessageCount < oldSession.userMessageCount ||
  newSession.assistantMessageCount < oldSession.assistantMessageCount ||
  newSession.toolInvocationCount < oldSession.toolInvocationCount
)

if fileUnchanged && anyCountDecreased {
  // 文件未变但计数减少 - 这是快速解析，保留旧的丰富数据
  mergedSessions.append(oldSession)
} else if /* 计数完全匹配 */ {
  mergedSessions.append(oldSession)  // 无变化，保留引用
} else {
  mergedSessions.append(newSession)  // 内容确实变化了
  hasAnyChanges = true
}
```

## 问题依然存在

### 可能的原因

#### 1. **数据流向问题**
`refreshSessions` 流程中可能有多个地方产生不同解析级别的数据：
- Cache path (cachePolicy: .cacheOnly) - line 749
- Refresh path (cachePolicy: .refresh) - line 751

这两个路径的数据可能混合在一起，导致去重逻辑失效。

#### 2. **去重时机问题**
```swift
let cachedResults = await loadProviders(providers, context: cacheContext)
var sessions = dedupProviderSessions(cachedResults)  // 第一次去重
let refreshedResults = await loadProviders(providers, context: refreshContext)
sessions = dedupProviderSessions(sessions + refreshedResults)  // 第二次去重
```

两次去重可能导致数据被错误选择。

#### 3. **SessionSummary 缺少 parseLevel 字段**
`SessionSummary` 结构体本身没有 `parseLevel` 字段，只在 SQLite 中跟踪。这意味着：
- 内存中的 `SessionSummary` 对象无法判断自己的解析级别
- `preferSession` 只能通过启发式规则（计数、lineCount）推断

#### 4. **Provider 层可能有缓存**
`loadProviders` 调用各个 provider 的 `load()` 方法，这些 provider 内部可能有自己的缓存机制，返回了旧的不完整数据。

#### 5. **buildSummaryFast 的 fallback 逻辑**
```swift
if let result = builder.build(for: url) { return result }
return try buildSummaryFull(for: url, builder: &builder)
```

`buildSummaryFast` 在无法构建 summary 时会 fallback 到 `buildSummaryFull`，但：
- Fallback 条件是什么？
- 是否有些文件触发了 fallback（得到完整计数），有些没有（不完整计数）？

## 调试建议

### 1. 添加日志跟踪
在关键点添加日志，跟踪数据流向：

```swift
// SessionIndexer.swift:264 (buildSummaryFast 调用处)
logger.debug("buildSummaryFast for \(url.lastPathComponent): tools=\(summary.toolInvocationCount) lines=\(summary.lineCount)")

// SessionListViewModel.swift:1024 (preferSession)
logger.debug("preferSession: lhs.tools=\(lhs.toolInvocationCount) lines=\(lhs.lineCount) vs rhs.tools=\(rhs.toolInvocationCount) lines=\(rhs.lineCount) → chose=\(result.toolInvocationCount)")

// SessionListViewModel.swift:2485 (smartMergeAllSessions)
logger.debug("smartMerge: old.tools=\(oldSession.toolInvocationCount) new.tools=\(newSession.toolInvocationCount) → kept=\(chosen.toolInvocationCount)")
```

### 2. 检查 SQLite 数据
直接查询数据库，查看那个问题文件的记录：

```sql
SELECT
  session_id,
  tool_invocation_count,
  line_count,
  parse_level,
  parsed_at,
  file_size_bytes,
  last_updated_at
FROM sessions
WHERE session_id = '019aec6a-8825-7e33-9790-d220bfb1a4b5'
ORDER BY parsed_at DESC;
```

### 3. 检查 buildSummaryFast 是否真的被调用
在 `SessionIndexer.swift:264` 设置断点或添加日志，确认刷新时确实走的是 fast parse。

### 4. 检查是否有多个相同 session 的记录
```swift
// 在 dedupProviderSessions 前后打印计数
logger.debug("Before dedup: \(sessions.count) sessions")
let deduped = dedupProviderSessions(sessions)
logger.debug("After dedup: \(deduped.count) sessions")
// 看是否有大量重复
```

### 5. 强制使用 buildSummaryFull
作为测试，临时修改 `SessionIndexer.swift:264`：
```swift
// 临时：强制使用 full parse
guard let summary = try buildSummaryFull(for: url, builder: &builder)
else { return .success(nil) }
```

看是否解决问题。如果解决了，说明问题确实在 fast vs full parse；如果没解决，说明还有其他原因。

## 关键文件路径

- **SessionIndexer.swift**: `/Volumes/External/GitHub/CodMate/services/SessionIndexer.swift`
  - Line 264: refreshSessions 中的 parse 调用
  - Line 901-947: buildSummaryFast 实现
  - Line 954-976: buildSummaryFull 实现

- **SessionListViewModel.swift**: `/Volumes/External/GitHub/CodMate/models/SessionListViewModel.swift`
  - Line 686: refreshSessions 入口
  - Line 749-752: cache + refresh 双路径加载
  - Line 1011-1050: dedupProviderSessions + preferSession
  - Line 2485-2545: smartMergeAllSessions

- **SessionIndexSQLiteStore.swift**: `/Volumes/External/GitHub/CodMate/services/SessionIndexSQLiteStore.swift`
  - Line 246-254: upsert 方法签名
  - Line 570-581: parse_level schema 和数据迁移

- **SessionSummary.swift**: `/Volumes/External/GitHub/CodMate/models/SessionSummary.swift`
  - SessionSummary 结构体定义（缺少 parseLevel 字段）

- **SessionEvent.swift**: `/Volumes/External/GitHub/CodMate/models/SessionEvent.swift`
  - Line 229-391: SessionSummaryBuilder 实现
  - observe() 方法累计各种计数

## 编译状态

✅ 最新代码编译成功，无错误，只有5个关于未使用 try? 结果的警告（可忽略）

## 当前 Git 状态

```
Changes not staged for commit:
  modified:   models/SessionListViewModel.swift
  modified:   services/SessionIndexSQLiteStore.swift
  modified:   services/SessionIndexer.swift
```

## 下一步建议

1. **添加详细日志**: 在上述关键点添加日志，重现问题时观察数据流
2. **检查 SQLite 数据**: 直接查看数据库中问题 session 的记录
3. **临时强制 full parse**: 验证是否是 fast/full parse 选择的问题
4. **考虑架构变更**: 可能需要在 SessionSummary 中添加 parseLevel 字段，让去重逻辑更可靠
5. **检查 Provider 缓存**: 各个 provider 的 load() 方法可能有自己的缓存策略

---

**生成时间**: 2025-12-05 14:05
**问题状态**: 未解决
**下一位诊断者**: 请从日志跟踪和 SQLite 数据检查开始
