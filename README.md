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

## 仓库结构

```text
E:\AI\xiaoyuan
├── client/               Flutter 客户端
├── server/               Go 后端
├── python-edu-service/   教务相关 Python 服务
├── nginx/                反向代理配置
├── deploy.sh             服务器部署脚本
├── DEPLOY.md             部署与验收文档
├── docker-compose.yml    容器编排
└── shenliyuan.service    systemd 服务文件
```

## 技术栈

### 客户端

- Flutter 3.x
- Provider
- Dio
- cached_network_image
- flutter_local_notifications

### 服务端

- Go 1.21+
- Gin
- GORM
- PostgreSQL / SQLite
- JWT

## 当前功能状态

### 已实现

**核心教务**
- 教务账号绑定与 Token 态维持
- 课表智能网格渲染（单双周、重叠课程盖压处理）
- 官方课表获取与本地按学期独立缓存
- Android 桌面今日课表小组件 (Home Widget)
- 自定义课程手动添加、编辑、删除
- 强大的 AI 课表解析与冲突检测导入（支持班级隔离过滤）
- 成绩查询与题库提取

**社区与治理**
- 用户注册 / 登录 / 修改资料
- 水贴发帖、图片上传、评论、点赞、举报
- 帖子图片大容量缓存到本地磁盘
- 集市发帖、曝光台、商品搜索
- 教师评价、学科榜、专业榜
- 公告发布与未读弹窗
- 管理员邀请链路与罢免投票链路
- 超级管理员面板与全局管控

**系统基建**
- 课程上课前自动静音与弹窗提醒
- 绕过缓存机制的 App 内版本更新检查与直链分发

### 仍在演进

- 客户端全量 lint 清理
- 更细的榜单统计与服务端聚合
- 更多前端自动化测试

## 📢 最新版本更新说明

**✨ 全新功能与重磅升级**
- **动态热度推荐算法上线**：首页「综合」版块引入全新“重力衰减”智能推荐算法。根据点赞、评论和围观热度智能推流，优质老帖有更多曝光机会，新鲜帖子也不会被埋没！
- **防错位阅读体验**：重构底层滑动翻页架构。采用 Go 内存快照游标分页，滑动查看帖子时大盘热度洗牌也不会刷到重复旧帖。
- **超级管理员面板升级**：新增“抽奖活动”防刷风控管理能力，随时查看并踢出异常参与账号。
- **AI 助手自由度 Max**：大模型 API 接口全面开放自定义配置，支持一键点击刷新扫描可用模型列表。

**🌟 v1.3.35 平板与大屏适配升级**
- **平板体验史诗级强化**：为大屏设备（Pad、桌面端）深度重构了 UI 布局，彻底解决大屏下界面拉伸、变形、留白过多的问题。
- **动态排版与自适应**：课表新增基于实际剩余空间的自动计算机制，修复了平板下卡片偏移的问题；且根据屏幕宽度动态放大卡片字体与留白，阅读更加舒适！
- **透明毛玻璃侧边栏**：关闭悬浮底栏时，平板端专用的左侧导航栏（NavigationRail）现已支持半透明毛玻璃效果，桌面壁纸完美透出，颜值拉满！
- **响应式交互与动画**：首页底栏切换加入平滑过渡动画；集市帖子在不同屏幕尺寸下均能正确展示层级，且精准修复了返回键显示与大屏分屏逻辑冲突的问题。

**🛠️ 体验优化与细节修复**
- **集市浏览更爽快**：修复了校园集市列表“按价格排序”偶发失效的问题，统一各模块网格视图宽度（一行三个）。
- **上传体验规范化**：修改头像和发布帖子图片限制最大不超过 10MB，避免超大原图导致卡顿与流量消耗。

## 本地开发

### 1. 启动后端

```bash
cd server
go run ./cmd/main.go
```

默认会启动在 `http://localhost:8080`。

### 2. 启动客户端

```bash
cd client
flutter pub get
flutter run
```

客户端 API 地址配置在：

- [E:\AI\xiaoyuan\client\lib\config\api_constants.dart](E:\AI\xiaoyuan\client\lib\config\api_constants.dart)

如果你本地联调本地后端，需要先把 `baseUrl` 改成你本机可访问地址。

### 3. 可选：启动教务 Python 服务

如果你需要联调教务相关能力，再启动：

```bash
cd python-edu-service
python main.py
```

## 常用检查命令

### 客户端

```bash
cd client
flutter analyze
flutter test
flutter build apk --debug
```

### 服务端

```bash
cd server
go test ./...
go build ./...
```

## 部署

服务器部署、重建、验收、排障请直接看：

- [E:\AI\xiaoyuan\DEPLOY.md](E:\AI\xiaoyuan\DEPLOY.md)

不要只看 README 里的摘要命令做线上运维，当前项目的部署基线已经单独沉淀在 `DEPLOY.md`。

## 当前部署原则

线上以 `/opt/shenliyuan` 为唯一部署目录，部署与排查顺序固定为：

```text
commit -> 编译 -> 进程 -> token
```

这个规则的完整背景和操作步骤也在 `DEPLOY.md` 里。

## 权限链路基线

当前已经验证通过的两条核心链路：

1. 超级管理员邀请普通用户 -> 用户同意后直接成为管理员
2. 管理员发起罢免 -> 过半投票 -> 目标降级为普通用户

如果你改动了权限逻辑，发布前至少回归这两条链路。

## GitHub 打包 iOS

仓库已经补了 GitHub Actions 工作流：

- [E:\AI\xiaoyuan\.github\workflows\ios.yml](E:\AI\xiaoyuan\.github\workflows\ios.yml)

以及导出配置：

- [E:\AI\xiaoyuan\client\ios\ExportOptions.plist](E:\AI\xiaoyuan\client\ios\ExportOptions.plist)

### 前置条件

你必须先准备好：

1. Apple Developer 账号
2. 正式的 iOS Bundle ID
3. iOS Distribution 证书 `.p12`
4. Provisioning Profile `.mobileprovision`
5. `p12` 密码

注意：当前项目里的 iOS 包名还是默认值：

- `com.example.shenliyuan`

正式打包前应先把它改成你自己的 Bundle ID。

### GitHub Secrets

在 GitHub 仓库设置里添加这些 Secrets：

- `IOS_P12_BASE64`
- `IOS_P12_PASSWORD`
- `IOS_MOBILEPROVISION_BASE64`
- `IOS_TEAM_ID`
- `IOS_BUNDLE_ID`

建议生成方式：

```bash
base64 -i dist.p12 | pbcopy
base64 -i dist.mobileprovision | pbcopy
```

Windows 可以用：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("dist.p12"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("dist.mobileprovision"))
```

### 触发方式

工作流会在两种情况下触发：

1. 手动触发 `workflow_dispatch`
2. push 到 `fwqtest`

### 构建产物

工作流成功后会在 GitHub Actions 的 Artifacts 中上传：

- `shenliyuan-ios-ipa`

你可以直接下载生成的 `.ipa`。

### 当前工作流做的事情

1. 拉代码
2. 安装 Flutter
3. 执行 `flutter pub get`
4. 解码证书和描述文件
5. 临时导入 macOS keychain
6. 构建 Flutter iOS 工程
7. 用 `xcodebuild archive + exportArchive` 导出 IPA
8. 上传 IPA artifact

### 当前限制

- 这套流程负责“自动打包”
- 不负责替你申请苹果签名资产
- 不负责自动上传 TestFlight

如果后面你要加 TestFlight 自动上传，可以在现有工作流基础上继续补 App Store Connect API Key 步骤。

## 开发说明

### 帖子与集市

- 帖子列表与详情接口在 `server/internal/handlers/post.go`
- 客户端帖子状态在 `client/lib/providers/post_provider.dart`
- 集市页在 `client/lib/screens/market_screen.dart`

### 教师评价与榜单

- 教师接口在 `server/internal/handlers/teacher.go`
- 客户端榜单页在 `client/lib/screens/teacher_rate_screen.dart`

### 权限与管理

- 登录与 token 逻辑在 `server/internal/handlers/auth.go`
- 邀请逻辑在 `server/internal/handlers/invitation.go`
- 超级管理员逻辑在 `server/internal/handlers/super_admin.go`

## 已知事实

- 当前客户端支持标准 emoji 输入和展示
- Apple 风格 emoji 是否显示，取决于操作系统字体，不是应用能强制决定
- Android 课程提醒支持静音通知和实时提醒优先尝试
- iOS 当前走普通静音通知，不做灵动岛

## 提交前建议

至少跑一遍：

```bash
cd client
flutter analyze
flutter build apk --debug

cd ../server
go test ./...
go build ./...
```

然后再根据改动范围做人工回归，尤其是：

- 登录态
- 公告
- 集市
- 发帖详情
- 教师评分
- 管理员权限流转

---

## 🙏 致谢

本项目的开发参考了以下开源项目：

- [syluinfo - atopos31](https://github.com/atopos31/syluinfo) - 教务系统接入参考
- [融智云考 - luokehan](https://github.com/luokehan/yongzhiyunkao) - 题库提取功能参考

感谢以上学长的开源精神！
