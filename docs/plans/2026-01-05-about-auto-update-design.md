# About 自动更新设计（GitHub Releases + 手动安装）

**目标**
- 在 Settings › About 页面增加自动更新能力：自动检查、提示新版本、用户确认后下载并引导手动安装。

**范围（In）**
- 更新源：GitHub Releases（`loocor/CodMate`）
- 资产：分架构 DMG（`codmate-arm64.dmg` / `codmate-x86_64.dmg`）
- 触发：应用启动“按自然日最多一次” + About 页面进入自动检查 + 手动刷新
- 仅展示正式发布（忽略 Draft/Prerelease）
- 下载完成后打开 DMG，并提示用户拖拽覆盖安装（不做自动替换）

**范围（Out）**
- Sparkle 自动安装（需要 Developer ID + Notarization）
- App Store 构建的更新（App Store 规则禁止自更新）

**关键决策**
- 采用 GitHub Releases `latest` API；版本比较基于 `CFBundleShortVersionString`。
- 更新检查与下载通过新的 `UpdateService` 统一管理，About 页面使用 `UpdateViewModel`。
- 更新信息缓存到 `UserDefaults`（最后检查日期、最新版本、最新资产 URL）。

**核心流程**
1. 启动/进入 About 触发检查
2. 请求 GitHub Releases `latest`
3. 解析版本、筛选资产（按架构）
4. 比对版本号
5. 有新版本 → UI 展示“下载并安装”
6. 用户确认 → 下载到 `~/Downloads` → 自动打开 DMG → 展示安装提示

**错误处理**
- 网络/解析/限流/资产缺失/文件写入失败均反馈到 About UI，可手动重试。
- App Store 构建直接禁用检查并显示说明。

**测试策略（最小集）**
- 版本解析/比较与资产选择的纯函数单元测试
- 模拟 GitHub JSON 的合成测试（不依赖外网）
- 手动冷回归：About 页面检查、下载、打开 DMG

