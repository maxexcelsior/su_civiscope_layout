# Civiscope Layout

<div align="center">

**专为城市规划师设计的 SketchUp 体块管理插件**

[![Version](https://img.shields.io/badge/version-0.1.6--beta-blue.svg)](https://github.com/MaxExcelsior/su_civiscope_layout)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![SketchUp](https://img.shields.io/badge/SketchUp-2024+-orange.svg)](https://www.sketchup.com/)

[功能特性](#features) • [安装](#installation) • [使用方法](#usage) • [开发](#development) • [贡献](#contributing)

</div>

<img width="1586" height="1053" alt="image" src="https://github.com/user-attachments/assets/981a8182-5872-4fe1-b595-cfc7aaa93528" />

---

## 📖 简介

**Civiscope Layout** 是一款面向城市规划师的 SketchUp 插件，专注于 CIM（City Information Modeling）体块管理与规划指标统计。告别手动计算容积率、建筑密度等指标的繁琐工作，让规划师专注于设计本身。

### ✨ 核心价值

- 🎯 **自动化统计** - 一键计算容积率、建筑密度、绿地率等规划指标
- 🏗️ **体块管理** - 智能管理建筑体块和地块，支持分类、着色、属性编辑
- 📐 **用地红线** - 自动提取并重建用地红线，支持限高盒可视化
- 🎨 **可视化渲染** - 按功能类型自动着色，直观展示规划方案

---

## 🚀 功能特性 `<a name="features"></a>`

### 1. 统计中心

- **实时统计** - 自动计算建筑总面积、容积率、建筑密度等指标
- **分类统计** - 按建筑功能（办公、商业、居住等）分类统计
- **用地统计** - 支持建设用地、绿地、水域等地块类型统计
- **数据导出** - 支持导出统计数据（开发中）

### 2. 体块管理

- **属性编辑** - 快速设置建筑功能、层高、类型等属性
- **批量操作** - 支持批量修改选中体块的属性
- **智能识别** - 自动识别 CIM 体块并提取属性

### 3. 用地红线工具

- **红线重建** - 从 CIM 地块自动提取外轮廓边线
- **限高检测** - 可视化显示建筑限高范围
- **坐标对齐** - 自动处理坐标变换，确保红线位置准确

### 4. 偏好设置

- **自定义分类** - 支持自定义建筑功能和用地类型
- **颜色映射** - 可自定义各类用地和建筑的颜色
- **界面配置** - 可调整对话框尺寸和布局

### 5. 开发者工具

- **热重载** - 支持代码热重载，加速开发调试
- **日志系统** - 完整的日志记录，便于问题追踪
- **模块化架构** - 清晰的代码结构，易于扩展

---

## 📥 安装 `<a name="installation"></a>`

### 方法一：手动安装（推荐）

1. **下载插件**

   ```bash
   git clone https://github.com/MaxExcelsior/su_civiscope_layout.git
   ```

   或从 [Releases](https://github.com/MaxExcelsior/su_civiscope_layout/releases) 页面下载最新版本
2. **复制到 SketchUp 插件目录**

   **Windows:**

   ```
   C:\Users\<用户名>\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\
   ```

   **macOS:**

   ```
   ~/Library/Application Support/SketchUp 2024/SketchUp/Plugins/
   ```
3. **重启 SketchUp**

   工具栏中将出现 "Civiscope Layout Tools" 工具条

### 方法二：使用扩展程序管理器

1、下载 [Releases](https://github.com/MaxExcelsior/su_civiscope_layout/releases) 页面的su_civiscope_layout.rbz 文件

2、SU菜单栏 → 扩展程序 → 扩展程序管理器 → 安装扩展程序 → 选择 su_civiscope_layout.rbz 打开 → 启用

---

## 📚 使用方法 `<a name="usage"></a>`

### 快速开始

1. **打开统计中心**

   - 点击工具栏中的 📊 图标
   - 或通过菜单 `Extensions > Civiscope Layout > 统计中心`
2. **选择体块**

   - 使用选择工具选中建筑体块或地块
   - 统计面板将自动更新数据
3. **编辑属性**

   - 双击体块进入编辑模式
   - 在统计面板中修改功能、层高等属性

### 工具栏功能

| 图标 | 功能     | 说明                     |
| ---- | -------- | ------------------------ |
| 📊   | 统计中心 | 查看和编辑体块统计数据   |
| ⚙️ | 偏好设置 | 配置全局属性和分类       |
| 📋   | 导出结果 | 导出统计数据（开发中）   |
| ℹ️ | 关于     | 查看插件信息和联系方式   |
| 🔄   | 重载代码 | 开发调试用，重新加载插件 |

### 右键菜单

在 CIM 地块或边线组上右键，可使用以下功能：

- **重建用地红线** - 提取外轮廓并创建新的边线组

---

## 🛠️ 开发指南 `<a name="development"></a>`

### 项目结构

```
su_civiscope_layout/
├── main.rb                 # 主入口文件
├── settings.rb             # 配置管理
├── settings.json           # 用户配置存储
├── CHANGELOG.md            # 更新日志
├── README.md               # 说明文档
├── logic/                  # 核心逻辑
│   ├── bldg_manager.rb     # 建筑管理
│   ├── site_manager.rb     # 地块管理
│   └── stats_engine.rb     # 统计引擎
├── ui/                     # 用户界面
│   ├── stats_dialog.rb     # 统计对话框
│   ├── picker_tool.rb      # 选择工具
│   ├── context_menu.rb     # 右键菜单
│   └── *.html              # HTML 界面
├── observers/              # 观察者
│   ├── observer_manager.rb # 观察者管理
│   ├── model_watcher.rb    # 模型观察
│   ├── selection_watcher.rb# 选择观察
│   └── entity_watcher.rb   # 实体观察
├── render/                 # 渲染模块
│   └── height_overlay.rb   # 限高盒渲染
├── utils/                  # 工具类
│   ├── logger.rb           # 日志系统
│   ├── attr_helper.rb      # 属性辅助
│   └── geom_helper.rb      # 几何辅助
├── icon/                   # 图标资源
└── assets/                 # 其他资源
```

### 开发环境

1. **克隆仓库**

   ```bash
   git clone https://github.com/MaxExcelsior/su_civiscope_layout.git
   cd su_civiscope_layout
   ```
2. **链接到 SketchUp 插件目录**

   **Windows (PowerShell 管理员模式):**

   ```powershell
   New-Item -ItemType Junction -Path "$env:APPDATA\SketchUp\SketchUp 2024\SketchUp\Plugins\su_civiscope_layout" -Target "$(Get-Location)"
   ```

   **macOS/Linux:**

   ```bash
   ln -s $(pwd) ~/Library/Application\ Support/SketchUp\ 2024/SketchUp/Plugins/su_civiscope_layout
   ```
3. **开发调试**

   - 修改代码后，点击工具栏中的 🔄 图标重载
   - 或在 Ruby 控制台执行：`CiviscopeLayout::Core.reload`

### 调试技巧

```ruby
# 在 Ruby 控制台中
CiviscopeLayout::Core.reload  # 热重载

# 查看日志
CiviscopeLayout::Logger.info("调试信息")
```

---

## 🤝 贡献指南 `<a name="contributing"></a>`

欢迎所有形式的贡献！无论是报告 Bug、提出新功能建议，还是提交代码改进。

### 如何贡献

1. **Fork 本仓库**

   点击右上角 Fork 按钮
2. **创建特性分支**

   ```bash
   git checkout -b feature/amazing-feature
   ```
3. **提交更改**

   ```bash
   git commit -m 'Add some amazing feature'
   ```
4. **推送到分支**

   ```bash
   git push origin feature/amazing-feature
   ```
5. **提交 Pull Request**

   在 GitHub 上创建 Pull Request，描述您的更改

### 代码规范

- 遵循 [Ruby Style Guide](https://rubystyle.guide/)
- 使用 2 空格缩进
- 添加必要的注释和文档
- 更新 CHANGELOG.md

### 报告问题

如果您发现了 Bug 或有功能建议，请 [创建 Issue](https://github.com/MaxExcelsior/su_civiscope_layout/issues/new)，并包含：

- SketchUp 版本
- 操作系统版本
- 问题描述和复现步骤
- 预期行为和实际行为
- 截图（如有）

---

## 📝 更新日志

查看 [CHANGELOG.md](CHANGELOG.md) 了解版本更新历史。

### 最新版本：v0.1.6-beta (2026-06-16)

**新增功能：**

- ✨ 屋顶构筑物 UI 重构 — 自动/手动模式切换、刷新按钮一键生成
- ✨ 建筑编号叠加层 — `TX-建筑编号` 图层，智能高度定位
- ✨ 地块编号叠加层增强 — 限高标注/固定值双模式互斥切换
- ✨ 统计面板卡片重组 — 强排信息、控规指标独立卡片
- ✨ 设置面板重组 — 标签页顺序调整、显示设置合并、X/Y位置参数
- ✨ 多选建筑批量功能修改

**优化改进：**

- 🔧 布局标准化 — 统一字体/字重、中文单位、功能/类型同行
- 🔧 热重载卡死修复 — 清理状态、调整加载顺序、重置模块变量
- 🔧 居住建筑屋顶规则 — <100m 无屋顶，≥100m 自动 5m 高 3m 缩进
- 🔧 Scale 工具屋顶构筑物缩进修正（avg_xy_scale）
- 🔧 修复 refreshUI → onToggleMode 无限回调循环
- 🔧 分层线群组归入 `000-分层线` SU 图层
- 🔧 移除调试日志输出，优化性能

---

## 📄 许可证

本项目采用 [MIT 许可证](LICENSE) 开源。

```
MIT License

Copyright (c) 2026 MaxExcelsior

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 📮 联系方式

<div align="center">

***联系作者：MaxExcelsior***

<img src="su_civiscope_layout/assets/个人微信.png" width="300">

<br><br>

***公众号：城析万相 Civiscope***

<img src="su_civiscope_layout/assets/公众号二维码.jpg" width="300">

<br><br>

***小红书：城析万相***

<img src="su_civiscope_layout/assets/城析万相小红书二维码.png" width="300">

<br><br>

***请我喝杯咖啡***

<img src="su_civiscope_layout/assets/个人收款码.jpg" width="300">

</div>

---

<div align="center">

**如果这个项目对您有帮助，请给一个 ⭐️ Star 支持一下！**

Made with ❤️ by MaxExcelsior

</div>
