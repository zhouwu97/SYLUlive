<div align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Go-1.21+-00ADD8?logo=go" alt="Go">
  <img src="https://img.shields.io/badge/PostgreSQL-14+-336791?logo=postgresql" alt="Postgres">
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License">
</div>

# 沈理校园 (SYLUlive)

沈理校园是一个专为校内学生打造的现代化、前后端分离的综合性校园应用。涵盖教务服务、校园社交、生活信息等全方位场景。

## 🌟 核心功能特性

### 📚 教务与工具助手
- **智能课表与桌面小部件**：支持一键同步官方课表，独创 **“按学期沙盒独立缓存”**，保证数据永不串台。支持精美的 Android 桌面小部件直观展示今日课程。
- **AI 智能识别导入**：首创接入外部大模型（Kimi/豆包等）解析非标课表（如全院实验大表），支持**按班级过滤**、**精准冲突检测（共存/置底/覆盖）**，实现自定义课程自由。
- **融智云考题库提取**：直击痛点，快捷提取题库资源。
- **成绩与考试查询**：无缝绑定教务系统，历史成绩、学分统计一目了然。

### 💬 校园互动社区
- **水贴广场**：匿名/实名发帖、图片上传及本地高并发缓存、多级评论、点赞与举报。
- **校园集市与曝光台**：闲置物品流转、避坑指南曝光、按标签与关键词全栈搜索。
- **教师与学科评价体系**：建立属于学生自己的“避坑/推荐榜单”，覆盖学科榜与专业榜。

### 🛡️ 现代化社区治理
- **分布式管理员体系**：首创“邀请制”版主上任机制与“公投制”管理员罢免链路。
- **全链路公告与通知**：系统级重要公告触达、未读红点提示，支持上课前“静音提醒”。
- **超级管理员面板**：全局最高权限的安全风控管理。

---

## 📂 仓库结构

```text
E:\AI\xynewui
├── client/               📱 Flutter 客户端
├── server/               ⚙️ Go 后端
├── python-edu-service/   🐍 教务相关 Python 服务
├── nginx/                🌐 反向代理配置
├── deploy.sh             🚀 服务器部署脚本
├── DEPLOY.md             📄 部署与运维文档
├── server/API.md         🔗 接口文档
├── docker-compose.yml    🐳 容器编排
└── shenliyuan.service    守护进程服务文件
```

---

## 📢 最新版本更新说明

### v1.4.36 (最新版本)
- **雨课堂图片选项全面适配**：端云结合重构了图片提取机制，不仅支持常规图片标签，更能精准提取暴露在 JSON 中的独立图片选项。现在 AI 可完美识别并回答纯图片选项的题目。
- **自动答题智能降级匹配**：重写了网页端注入 JS 脚本的物理点击逻辑。在纯图片选项无文字的情况下，能智能降级比对题号字母（A/B/C/D）进行精准命中。
- **UI 体验修复**：修复了在部分手机（如荣耀）特殊分辨率及全面屏手势下，应用被强行开启兼容模式导致的整体拉伸变形；彻底修复了**底部悬浮导航栏高度溢出导致的课表空白与“我”版块无线上滑Bug**。

---

## 🚀 本地开发指南

### 1. 启动后端

后端使用 Go 语言开发。
```bash
cd server
go run ./cmd/main.go
```
> 服务默认将启动在 `http://localhost:8080`。

### 2. 启动客户端

客户端使用 Flutter 框架。
```bash
cd client
flutter pub get
flutter run
```
> **提示**：如果你需要联调本地的后端服务，请前往 `client/lib/config/api_constants.dart`，将其中的 `baseUrl` 替换为你本机的局域网 IP 地址。

### 3. 可选：启动教务 Python 服务

提供特定的教务网爬取和认证支持。
```bash
cd python-edu-service
python main.py
```

---

## 📖 文档体系

- **部署与运维指南** 👉 [DEPLOY.md](./DEPLOY.md) (线上服务器运维、CI/CD部署流)
- **后端 API 接口概览** 👉 [server/API.md](./server/API.md) (RESTful API 设计说明)

---

## 🏗️ 提交与检查

在提交代码前，建议运行以下命令以确保质量：

**客户端:**
```bash
cd client
flutter analyze
flutter build apk --debug
```

**服务端:**
```bash
cd server
go test ./...
go build ./...
```

---

## 🙏 致谢

本项目的开发参考了以下优秀的开源项目，感谢他们的开源精神！

- [syluinfo - atopos31](https://github.com/atopos31/syluinfo) - 教务系统接入参考
- [融智云考 - luokehan](https://github.com/luokehan/yongzhiyunkao) - 题库提取功能参考

<p align="center">
  <i>Make campus life better.</i>
</p>
