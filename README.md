## 🙏 致谢

本项目的开发参考了以下开源项目：

- [syluinfo - atopos31](https://github.com/atopos31/syluinfo) - 教务系统接入参考
- [融智云考 - luokehan](https://github.com/luokehan/yongzhiyunkao) - 题库提取功能参考

感谢以上学长的开源精神！

# 沈理校园

沈理校园是一个面向校内学生的前后端分离应用，当前包含：

- 水贴广场
- 校园集市与曝光台
- 课程提醒
- 教师 / 学科评价榜
- 公告系统
- 管理员邀请、投票罢免、超级管理员管理
- 教务绑定、课表与成绩查询
- 融智云考题库提取

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

- 用户注册 / 登录 / 修改资料
- 水贴发帖、图片上传、评论、点赞、举报
- 集市发帖、曝光台、商品搜索
- 帖子图片缓存到本地磁盘
- 教师评价、学科榜、专业榜
- 公告发布与未读弹窗
- 课程静音提醒
- 管理员邀请链路
- 管理员罢免投票链路
- 超级管理员面板
- 教务绑定、课表、成绩
- 题库提取

### 仍在演进

- 客户端全量 lint 清理
- 更细的榜单统计与服务端聚合
- 更多前端自动化测试

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
