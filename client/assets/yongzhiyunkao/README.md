# 🎯 融智云考练习题提取工具

<div align="center">

![Version](https://img.shields.io/badge/version-5.2-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-Browser-orange.svg)

一个优雅的练习题提取和转换工具，支持从融智云考系统提取题目并转换为Markdown格式

[功能特点](#-功能特点) • [快速开始](#-快速开始) • [使用指南](#-使用指南) • [常见问题](#-常见问题)

</div>

---

## ✨ 功能特点

### 🔍 智能提取
- 🚀 **一键提取**：自动遍历所有题目，无需手动操作
- 📊 **完整信息**：题目、选项、答案、解析一个不漏
- 🎯 **灵活控制**：支持从任意题目开始提取
- ⏸️ **中断恢复**：可随时停止，已提取的数据自动保存

### 🎨 精美界面
- 💎 **现代设计**：渐变色彩，毛玻璃效果
- 📱 **响应式布局**：完美支持各种设备
- ⚡ **流畅动画**：优雅的交互体验
- 🌈 **实时反馈**：进度条和状态提示

### 📝 格式转换
- 🔄 **一键转换**：JSON自动转为Markdown
- 📑 **智能排版**：章节分组，目录生成
- ✅ **答案标记**：正确答案醒目显示
- 📊 **统计分析**：题型分布，分值统计

### 🛡️ 安全可靠
- 🔒 **本地处理**：所有数据处理都在本地完成
- 🚫 **无需服务器**：不依赖任何外部服务
- 💾 **离线使用**：下载后即可永久使用
- 🔐 **隐私保护**：您的数据永远不会上传

## 🚀 快速开始

### 方式一：油猴脚本（推荐）

1. **安装 Tampermonkey 扩展**
   - [Chrome](https://chrome.google.com/webstore/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo)
   - [Firefox](https://addons.mozilla.org/firefox/addon/tampermonkey/)
   - [Edge](https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd)

2. **安装脚本**
   - 打开 `tampermonkey_script.js`
   - 复制全部内容
   - 在 Tampermonkey 中创建新脚本并粘贴

3. **开始使用**
   - 访问练习页面
   - 点击右下角的提取按钮
   - 选择选项并开始提取

### 方式二：转换工具

1. **打开转换器**
   - 双击 `convert_to_markdown.html`
   - 或拖拽到浏览器中打开

2. **上传文件**
   - 拖拽 JSON 文件到上传区域
   - 或点击选择文件

3. **转换下载**
   - 调整转换选项
   - 点击转换并下载结果

## 📖 使用指南

### 提取题目

<details>
<summary>🎯 基本操作</summary>

1. 打开练习页面
2. 点击页面右下角的"提取题目"按钮
3. 在弹出的面板中查看当前状态
4. 点击"开始提取"
5. 等待提取完成，自动下载JSON文件

</details>

<details>
<summary>⚙️ 高级功能</summary>

- **从当前题目开始**：自动检测当前题号，无需从头开始
- **中途停止**：点击"停止提取"可随时中断
- **快捷键**：`Ctrl+Shift+E` 快速打开/关闭面板

</details>

### 转换格式

<details>
<summary>📝 转换选项</summary>

- ✅ **生成目录**：适合题目较多的情况
- ✅ **生成统计**：查看题型分布和分值
- ✅ **标记答案**：正确选项用 ✓ 标记
- ✅ **章节分组**：按章节整理题目

</details>

<details>
<summary>💾 保存方式</summary>

- **下载文件**：生成 .md 文件下载到本地
- **复制内容**：一键复制到剪贴板
- **实时预览**：转换前预览最终效果

</details>

## 📁 文件说明

```
📦 融智云考练习题提取工具
├── 📜 tampermonkey_script.js    # 油猴脚本（题目提取）
├── 📄 convert_to_markdown.html  # 转换工具（格式转换）
└── 📖 README.md                 # 说明文档
```

## 🎨 界面预览

### 提取界面
```
┌─────────────────────────────┐
│ ✨ 练习题智能提取器          │
├─────────────────────────────┤
│ 当前题目：50 / 200          │
│ 待提取：151 题              │
│ ████████░░░░░░░░ 25%       │
│                             │
│ [▶ 开始提取] [⏸ 停止提取]  │
└─────────────────────────────┘
```

### 转换界面
```
┌─────────────────────────────┐
│ 📤 上传文件                 │
│ ┌─────────────────────┐    │
│ │  📁                  │    │
│ │  拖拽文件到此处      │    │
│ └─────────────────────┘    │
│                             │
│ ⚙️ 转换选项                 │
│ ☑ 生成目录                 │
│ ☑ 生成统计信息             │
│ ☑ 标记正确答案             │
│                             │
│ [开始转换]                  │
└─────────────────────────────┘
```

## 🔧 技术栈

- **前端技术**：原生 JavaScript + HTML5 + CSS3
- **浏览器API**：File API, Blob API, Clipboard API
- **设计风格**：现代渐变设计 + 毛玻璃效果
- **兼容性**：支持所有现代浏览器

## ❓ 常见问题

<details>
<summary>控制台打不开怎么办？</summary>

使用油猴脚本可以完美解决这个问题，无需打开控制台。

</details>

<details>
<summary>提取的题目为空？</summary>

请确保：
1. 使用最新版本的脚本（v5.2+）
2. 页面完全加载后再开始提取
3. 检查浏览器控制台是否有错误信息

</details>

<details>
<summary>如何在其他网站使用？</summary>

1. 修改油猴脚本中的 `@match` 规则
2. 调整选择器以匹配目标网站的HTML结构
3. 测试并调试提取逻辑

</details>

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

### 提交 Issue
- 🐛 Bug 报告：请详细描述问题和复现步骤
- ✨ 功能建议：请说明需求场景和预期效果
- 📖 文档改进：请指出需要改进的地方

### 提交 PR
1. Fork 本仓库
2. 创建您的特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交您的更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 打开一个 Pull Request

## 📜 开源协议

本项目采用 MIT 协议 - 查看 [LICENSE](LICENSE) 文件了解详情

## 🌟 Star History

如果这个项目对您有帮助，请给个 ⭐ Star 支持一下！

---

<div align="center">

Made with ❤️ by [Your Name]

[⬆ 回到顶部](#-融智云考练习题提取工具)

</div> 