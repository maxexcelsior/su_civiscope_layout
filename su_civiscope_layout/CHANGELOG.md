# 更新日志

## [0.1.4-beta] - 2026-04-09

### 新增功能 ✨
- **右键菜单功能** (`ui/context_menu.rb`)
  - 在右键菜单中注册 "CiviscopeLayout" 主菜单
  - 新增 "重建用地红线" 功能，用于重建 CIM 地块的边线组
  - 支持验证用户选择，提示用户先选择边线组
  - 提取 CIM 地块的外轮廓边线并重新打组

### 优化改进 🔧
- **边线组提取逻辑优化**
  - 只提取不被两个面共享的外轮廓边线（用地红线）
  - 避免提取内部面的边线，确保用地红线准确性

- **边线组变换处理**
  - 使用逆变换重置边线组的变换为单位矩阵
  - 确保边线组坐标轴方向与 CIM 地块一致
  - 边线组位置与 CIM 地块轮廓吻合

- **限高盒渲染优化** (`render/height_overlay.rb`)
  - 从边线组提取顶点时考虑边线组的变换
  - 新增 `sort_vertices_by_connection_with_transform` 方法
  - 根据活动路径动态调整坐标变换，支持在 CIM 地块组内外正确渲染

### 文件结构变化 📁
```
新增文件：
- ui/context_menu.rb              (右键菜单功能)

修改文件：
- main.rb                         (版本更新、加载 context_menu.rb)
- render/height_overlay.rb        (限高盒渲染优化、新增变换处理方法)
```

### 已知问题 ⚠️
- 重建用地红线后，限高盒在 CIM 地块组内外切换时可能存在渲染错位问题（待后续优化）

---

## [0.1.3-beta] - 2026-04-08

### 新增功能 ✨
- **统一观察者管理模块** (`observers/observer_manager.rb`)
  - 集中管理所有观察者实例（ModelObserver、SelectionObserver、EntityObserver）
  - 提供 `cleanup_all_observers` 方法，防止观察者重复注册和内存泄漏
  - 提供 `register_all_observers` 方法，统一注册入口

- **统一日志系统** (`utils/logger.rb`)
  - 支持 DEBUG、INFO、WARN、ERROR 四个日志级别
  - 提供快捷方法：`Logger.debug/info/warn/error`
  - 可扩展为写入日志文件
  - 便于调试和问题追踪

### 优化改进 🔧
- **完善热重载功能** (`main.rb`)
  - 重载前自动清理所有观察者，避免内存泄漏
  - 加载新增的 `observer_manager.rb` 和 `logger.rb` 模块
  - 使用 Logger 输出重载日志，替代 `puts`

- **统一配置存储**
  - 删除 `ui/stats_dialog.rb` 中重复的 `get_stats_size` 和 `save_stats_size` 方法
  - 统一使用 `settings.rb` 中的 JSON 存储版本，避免配置冲突

- **修复重载警告**
  - 为所有常量添加 `unless defined?` 保护
  - 解决热重载时 "already initialized constant" 警告

### 代码重构 📦
- **删除冗余文件**
  - 删除 `stats.rb`（仅3行重定向，功能已模块化）
  - 删除 `stats._backup.rb`（旧版备份文件，不再需要）

- **优化观察者注册**
  - `entity_watcher.rb`：`attach_observers` 方法委托给 `ObserverManager`
  - `stats_dialog.rb`：使用 `ObserverManager.register_all_observers` 统一注册

### 文件结构变化 📁
```
新增文件：
- observers/observer_manager.rb  (统一观察者管理)
- utils/logger.rb                (统一日志系统)

删除文件：
- stats.rb                       (冗余重定向)
- stats._backup.rb               (旧版备份)

修改文件：
- main.rb                        (版本更新、热重载优化、加载新模块)
- ui/stats_dialog.rb             (删除重复配置方法、使用 ObserverManager)
- observers/entity_watcher.rb    (委托给 ObserverManager)
```

### 技术债务清理 🧹
- 统一观察者生命周期管理，防止重复注册
- 集中配置存储，避免多处定义冲突
- 规范日志输出，便于调试和维护
- 代码模块化程度提升，可维护性增强

---

## [0.1.2-beta] - 2026-04-07

### 新增功能
- 初始版本发布
- 基础统计功能
- 建筑和地块管理
- 选择观察者和模型观察者