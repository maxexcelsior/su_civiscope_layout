# 更新日志

### 2026-07-23

## [0.1.8-beta] - 2026-07-23

### 新增功能 ✨

- **多选地块 UI 优化** (`ui/ui_stats.html`, `ui/stats_dialog.rb`, `render/site_number_overlay.rb`)

  - 标题"选择地块汇总对比"改为"选中地块及数据汇总"
  - 移除表格中每行的编号显示/隐藏按钮，改为标题右侧的批量"显示地块编号/隐藏地块编号"按钮
  - 新增 `batch_toggle_site_number` 方法，支持批量切换地块编号显示
- **Group 多 CIM 实体检测** (`logic/stats_engine.rb`)

  - 选中不含 CIM 属性但内部包含多个 CIM 地块/建筑的普通 Group 时，统计中心切换到用地标签并展示多地块汇总
  - `get_active_targets` 改为返回 Group 内所有地块而非仅第一个

### 优化改进 🔧

- **统计面板 UI 细节调整** (`ui/ui_stats.html`)

  - 多选地块表头：`性质`→`用地性质`，`面积`→`用地面积(m²)`，`计容`→`计容建筑面积(m²)`，`折减后计容`→`折减后(m²)`
  - 行标签改为显示用地性质（`site_func`）而非用地大类（`site_type`）
  - 表头和单元格文字居中对齐
  - 批量显示/隐藏按钮样式与单选按钮一致
- **修复批量显示按钮闪烁** (`render/site_number_overlay.rb`)

  - `batch_toggle_site_number` 移除 `start_operation/commit_operation` 包裹，避免 `add_text` 在操作内创建导致实体失效的问题

### 2026-07-22

## [0.1.7-beta] - 2026-07-22

### 新增功能 ✨

- **新增"公寓"建筑功能** (`main.rb`)

  - `DEFAULT_BLDG_FUNCS` 中增加"公寓"
  - `COLOR_MAP` 中增加 `#ff7f00`（橙色）
- **颜色选择器"恢复默认"** (`settings.rb`, `ui/ui_settings.html`)

  - 颜色弹窗增加"恢复默认"按钮（红色边框样式）
  - 点击后删除 `custom_colors` 记录，恢复为 `COLOR_MAP` 默认色
  - 自动更新模型中对应材质颜色
  - 仅在存在自定义颜色或 COLOR_MAP 默认色时显示该按钮

### 优化改进 🔧

- **统计中心多选地块汇总增强** (`ui/stats_dialog.rb`, `ui/ui_stats.html`)

  - 多选地块时汇总行新增"总计容建筑面积"和"总计容建筑面积（折减后）"
  - 各地块行的"折减后计容"列从 `-` 占位符改为显示实际计算值
  - 修复 `multi_reduction_enabled` 对地块类型始终为 `false` 的问题，折减功能现可正确作用于地块汇总

### 2026-06-16

## [0.1.6-beta] - 2026-06-16

### 新增功能 ✨

- **屋顶构筑物 UI 重构** (`ui/ui_stats.html`, `ui/stats_dialog.rb`)

  - 自动/手动模式切换：自动模式显示只读高度和缩进，手动模式支持用户输入自定义值
  - 刷新按钮：按当前参数一键重新生成屋顶构筑物
  - 手动→自动切换时立即触发刷新，无需再点击刷新按钮
- **建筑编号叠加层** (`render/site_number_overlay.rb`)

  - 新增 `TX-建筑编号` 图层，支持显示/隐藏建筑编号
  - 标签高度逻辑：裙楼使用自身总高度+偏移，塔楼/独立使用有效高度+偏移
  - 建筑编号标签位置偏移参数（显示设置面板）
- **地块编号叠加层增强** (`render/site_number_overlay.rb`, `settings.rb`, `ui/ui_settings.html`)

  - 两种标注模式：根据地块限高标注（+位置偏移）或根据固定值标注（+离地高度）
  - 两种模式互斥切换
  - 配置参数持久化到 `settings.json`
- **统计面板卡片重组** (`ui/ui_stats.html`)

  - 建筑强排信息独立为卡片，位于建筑参数卡片下方
  - 新增控规指标卡片（含限高检测按钮），位于基本信息和强排信息之间
  - 控规指标标题左边框颜色与基本信息统一
- **设置面板重组** (`ui/ui_settings.html`, `settings.rb`)

  - 编号设置 → 显示设置（合并地块编号+建筑编号配置）
  - 标签页顺序：建筑配置 → 用地配置 → 显示设置 → 统计配置 → 界面设置
  - 界面设置移至底部（`margin-top: auto`）
  - 统计中心窗口 X/Y 坐标位置参数（保存/恢复对话框位置）
  - 尺寸修改自动同步到 settings.json 并实时调整对话框
- **多选建筑批量功能修改** (`ui/ui_stats.html`, `ui/stats_dialog.rb`)

  - 多选建筑表格中新增功能类型下拉框（取自已注册的建筑功能列表）
  - 选中新功能后批量修改所有选中建筑的功能并刷新面板

### 优化改进 🔧

- **布局标准化** (`ui/ui_stats.html`)

  - 统一字体大小/字重（13px 基础，14px 标题）
  - 全中文单位（米/平方米）
  - 建筑功能与类型同行显示
  - 编号→建筑编号，flex 布局
- **显示参数设置 UI 优化** (`ui/ui_settings.html`)

  - 地块编号高度配置改为 checkbox + input 联动模式
  - CSS 优化：面板最小宽度 440→400px，输入框宽度 70→55px，隐藏滚动条
- **热重载卡死修复** (`main.rb`)

  - 重载前清理运行时状态（关闭对话框、取消定时器、清理观察者、清空叠加层数据）
  - 调整加载顺序：子模块优先加载，主文件最后加载
  - 重置模块实例变量，防止旧状态与新代码冲突
- **居住建筑屋顶规则** (`logic/bldg_manager.rb`)

  - 建筑总高 < 100m：不生成屋顶构筑物（高度=0，缩进=0）
  - 建筑总高 ≥ 100m：自动生成 5m 高、3m 缩进的屋顶构筑物
- **Scale 工具屋顶构筑物缩进修正** (`logic/bldg_manager.rb`)

  - 使用 `avg_xy_scale` 计算缩进，修复非均匀缩放时屋顶构筑物偏移
- **分层线图层管理** (`logic/bldg_manager.rb`)

  - 生成的建筑分层线群组统一归入 `000-分层线` SU 图层，便于统一显隐控制
- **修复 `refreshUI` → `onToggleMode` 无限回调循环** (`ui/ui_stats.html`)

  - 添加 `_rsModeBefore` 守卫变量，仅模式切换时触发刷新
  - 根因：`refreshUI` → `onToggleMode(rsMode)` → auto 模式调用 `refreshRoofStructure()` → Ruby callback → `refresh_stats_ui` → `execute_script("refreshUI")` → 循环
- **移除调试日志输出**

  - 清理 `schedule_auto_recalc`、`calc_bldg_data`、`update_floor_lines`、`auto_recalculate`、`do_apply_bldg`、`onTransactionCommit` 中的调试 `puts` 语句
  - 保留 `[DEBUG-PODIUM]` 输出便于裙楼调试

### 2026-05-13

#### 建筑密度算法重构 🏗️

- **移除原有基底面积去重算法** (`utils/geom_helper.rb`)
  - 移除 `is_bldg_nested?` 及相关的 Sutherland-Hodgman 多边形裁剪、`point_in_polygon_2d?` 等辅助方法
- **改为材质面积法** (`logic/stats_engine.rb`)
  - `calculate_site_metrics`：建筑基底面积改为统计 `Civiscope_建筑基底` 材质面积（与绿地率算法一致）
  - `sum_green_area` → `sum_material_area`：通用化为材质面积扫描方法
- **建筑基底填充工具** (`logic/site_manager.rb`, `ui/stats_dialog.rb`, `ui/ui_stats.html`)
  - 用地标签面板中"内部绿地"按钮一分为二：左 = `🌿 内部绿地`，右 = `🏗️ 建筑基底`
  - 点击建筑基底后激活材质填充工具，使用灰色 `Civiscope_建筑基底` 材质（#9e9e9e）
  - 建筑密度 = 建筑基底材质面积 / 用地面积

#### 计容面积折减系数 📐

- **统计配置标签页** (`settings.rb`, `ui/ui_settings.html`)
  - 新增"统计配置"标签页，支持启用/关闭计容面积折减
  - 默认裙楼折减区间：12m→0.95, 24m→0.90, 30m→0.85, 40m→0.80
  - 默认塔楼/独立折减区间：100m→0.95 ~ 500m→0.70（9档）
  - 高度区间上限不可修改，折减系数支持用户自定义
- **统计面板折减显示** (`ui/stats_dialog.rb`, `ui/ui_stats.html`)
  - 单选建筑：显示"计容建筑面积（折减后）"橙色行
  - 单选地块：显示"容积率（折减后）"，建筑列表增加"折减后"列
  - BP组只读视图：增加折减后计容建面和容积率
  - 多选建筑：增加"折减后"列及合计行
  - 折减仅在启用时显示，关闭后恢复原有标签文案
- **折减系数计算** (`settings.rb`)
  - `compute_reduction_factor(bldg_type, height_m)`：按建筑类型和高度查找对应系数
  - 塔楼使用真高（塔楼+裙楼），裙楼/独立使用自身高度

### 2026-05-12

#### 观察者/重算管线修复 🔧

- **Scale 工具修改后指标刷新** (`observers/model_watcher.rb`)
  - 新增 `onTransactionCommit` 回调：用户确认 Scale/Move/Rotate 编辑后自动触发挂起的重算
  - 通过 `skip_recalc` 检查防止插件自身操作误触发
- **屋顶构筑物面丢失/无限循环修复** (`logic/bldg_manager.rb`)
  - 修复 `@skip_recalc` 时序：将 `skip_recalc = true` 移到 `remove_roof_structure` 之前，防止擦除屋顶构筑物时触发 `BimEntitiesWatcher` 导致无限定时器循环
  - 跨 100m 屋顶构筑物阈值时不再出现面丢失或卡顿
- **挂起重算安全守卫** (`logic/stats_engine.rb`)
  - `auto_recalculate` 入口清理 `@pending_recalc_entity`，防止过时实体被错误重算
- **观察者安全定时器** (`observers/observer_manager.rb`)
  - 添加 `safety_timer_id`，确保异常情况下 `skip_recalc` 状态能被恢复

#### 撤销操作修复 ⏮️

- **移动建筑后撤销** (`logic/bldg_manager.rb`)
  - `calc_bldg_data` 整体包裹透明 undo operation（`start_operation(..., true, true, true)`），撤销时光标复位正确、屋顶构筑物不丢失

### 2026-05-09 ~ 05-11

#### 绘制建筑退线功能 ✨

- **核心逻辑** (`logic/building_setback.rb`) — 新增文件
  - 建筑底面边线分组（连续同向边自动合并为圆弧组）
  - 多层退线生成：低层/多层/高层三段距离体系
  - 临水/临绿快捷退线（G=临绿，E=临水）
  - 支持地区类型（一般地区/临绿/临水）对应的退线参数配置
- **交互工具** (`ui/setback_tool.rb`) — 新增文件
  - 统一边导航对话框替代逐条 `UI.inputbox`，支持"上一条"/"下一条"导航
  - 下一条自动沿用上一条输入值
  - `onDraw` 实时在边旁显示参数文字，生成退线后自动清除
  - 退线结果分层放置（`TX-建筑退线-低层`/`多层`/`高层`）
- **边参数对话框** (`ui/ui_setback.html`) — 新增文件
  - 边组信息展示（"第 3/8 条边" / "第 1-3 条边(圆弧)"）
  - 输入联动 + 默认值继承
  - 首尾导航禁用状态处理

#### 地块编号显示 🏷️

- **编号叠加层** (`render/site_number_overlay.rb`) — 新增文件
  - 地块编号显示叠加层，统一存放在 `TX-地块编号` 图层
  - 支持显示/隐藏地块编号，编号高度可配置
  - 自动清理孤立标签（orphaned labels）

### 文件结构变化 (相对 0.1.4-beta)

```
新增文件：
- logic/building_setback.rb         (建筑退线核心逻辑)
- ui/setback_tool.rb                (退线交互工具)
- ui/ui_setback.html                (边参数导航对话框)
- render/site_number_overlay.rb     (地块编号叠加层)

修改文件：
- main.rb                           (加载新模块)
- settings.rb                       (折减系数配置 + 显示参数)
- logic/bldg_manager.rb             (undo修复 + skip_recalc时序 + 分层线图层)
- logic/site_manager.rb             (建筑基底填充工具)
- logic/stats_engine.rb             (材质面积法 + sum_material_area + pending清理)
- utils/geom_helper.rb              (移除去重算法，保留核心坐标变换)
- ui/stats_dialog.rb                (折减显示 + 建筑基底回调)
- ui/ui_stats.html                  (折减UI + 建筑基底按钮)
- ui/ui_settings.html               (统计配置标签页)
- observers/model_watcher.rb        (onTransactionCommit)
- observers/observer_manager.rb     (安全定时器)
- observers/entity_watcher.rb       (重构)
```

---

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
