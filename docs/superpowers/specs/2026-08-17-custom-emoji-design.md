# 自定义表情包设计说明

**状态：** 已确认，待实施计划

**目标：** 在聊天表情面板中增加账号级云同步的自定义表情功能，首期支持 JPG、PNG、GIF，并支持长按聊天图片加入表情包。

## 1. 已确认范围

- 入口位于聊天表情面板的心形“收藏”页。
- 收藏页第一个网格格子固定为“＋ 添加图片”。
- 收藏按登录账号管理，跨私聊会话、跨设备同步。
- 首期支持 JPG、JPEG、PNG、GIF；首期不支持 WebP、视频和批量导入。
- GIF 保存原始动态文件，网格使用服务端生成的静态首帧缩略图。
- 点击收藏图片先进入输入栏预览，点击发送后发送图片消息。
- 新增收藏排在已有自定义表情之前；不支持拖拽排序。
- 长按收藏表情删除，删除后提供可撤销 Snackbar。
- 长按聊天图片显示“添加到表情包”；同一资源按文件哈希去重。
- 删除收藏关系不立即删除文件，只有在没有其他消息或资源引用时才允许清理文件。

## 2. 非目标

本次不实现：

- 用户自定义表情分组、命名和搜索。
- 拖拽排序。
- 用户之间分享表情包。
- 视频转 GIF 或视频表情。
- WebP 支持。
- 批量选择和批量上传。

## 3. 交互设计

### 3.1 收藏页

`AppEmojiPanel` 的收藏页始终把添加格放在第一个位置：

```text
[＋ 添加图片] [最新收藏] [其他收藏] ...
```

没有收藏时显示添加格和空状态说明；有收藏时保留添加格，新增内容插入其后第一位。内置表情和自定义图片共用收藏网格，自定义图片的可访问名称默认使用“收藏图片”。

网格单元的命中区域不小于 44×44 logical px。自定义 GIF 使用静态缩略图，避免面板同时解码大量动画；输入栏预览和发送消息使用原始 GIF。

### 3.2 从相册添加

流程：

1. 点击第一个添加格。
2. 打开系统图片选择器。
3. 校验文件格式、文件大小和图片尺寸。
4. 调用现有 `/api/upload` 上传文件。
5. 调用收藏接口创建用户表情资源和收藏关系。
6. 成功后将新内容插入收藏列表第一位。

默认限制：账号最多 80 个收藏项（内置表情和自定义表情合计），单个自定义文件不超过 10 MB，账号自定义表情资源总容量不超过 200 MB。限制由服务端配置控制，客户端只提供提前提示，服务端负责最终校验。

### 3.3 长按聊天图片

聊天图片或 GIF 长按打开现有消息操作 BottomSheet，新增操作项“添加到表情包”。服务端接收消息 ID，重新校验当前用户对消息文件的访问权限，再为当前用户创建独立的用户表情资源引用。客户端不直接提交任意图片 URL 或文件路径。

如果资源已经被当前用户收藏，菜单显示“取消收藏”或“已在表情包中”，不会重复创建资源。

### 3.4 发送和删除

点击自定义表情后，输入栏显示动态预览和移除按钮；发送时复用收藏资源的 `file_id`，不下载后重新上传。发送状态沿用聊天已有的 `sending / failed / retry` 状态。

长按收藏单元执行删除收藏关系，并立即从本地列表移除；Snackbar 提供“撤销”。撤销使用已缓存的资源 ID 和类型重新创建收藏关系。删除失败时恢复原列表位置并提示失败原因。

## 4. 服务端架构

### 4.1 数据模型

新增 `server/internal/models/emoji_favorite.go`，定义两个模型：

`UserEmojiAsset` 表示用户拥有的自定义图片资源：

- `ID`
- `UserID`
- `FileID`
- `ThumbnailPath`
- `MimeType`
- `IsAnimated`
- `Width`
- `Height`
- `CreatedAt`
- `UpdatedAt`

`UserEmojiFavorite` 表示用户收藏列表中的一项：

- `ID`
- `UserID`
- `Kind`：`builtin` 或 `custom`
- `StickerID`：内置表情 ID，可空
- `AssetID`：自定义资源 ID，可空
- `SortOrder`
- `CreatedAt`
- `UpdatedAt`

服务层保证同一用户不能重复收藏同一内置表情或同一自定义资源。文件仍复用现有 `models.File` 与 `FileUploadGrant`，通过引用计数避免过早删除。

### 4.2 HTTP 接口

新增 `server/internal/handlers/emoji_favorite.go` 和对应 service：

```text
GET    /api/emoji/favorites
POST   /api/emoji/favorites
POST   /api/emoji/favorites/from-message
DELETE /api/emoji/favorites/:id
```

请求约定：

- `POST /favorites` 接受 `kind=builtin, sticker_id` 或 `kind=custom, file_id`。
- `POST /favorites/from-message` 只接受 `message_id`，服务端自行解析文件并校验权限。
- `DELETE` 只删除当前用户自己的收藏关系。
- 返回项包含收藏 ID、类型、文件 ID、原图 URL、缩略图 URL、MIME 类型、动态标记和排序位置。

不新增排序接口，因为本期没有拖拽排序；新收藏由服务端分配最小排序值并排在最前。

### 4.3 GIF 缩略图

现有上传处理器允许 GIF，但现有图片变体逻辑不会为 GIF 生成缩略图。需要扩展上传/表情资源服务：

1. 使用 `image/gif` 解码 GIF 的第一帧。
2. 按最长边 480px 生成 PNG 首帧缩略图。
3. 将缩略图路径写入 `UserEmojiAsset.ThumbnailPath`。
4. 缩略图生成失败时拒绝创建收藏资源并返回可读错误。

原始 GIF 保留原 MIME 类型和文件内容，接收方仍通过原始文件发送和播放。

### 4.4 权限和文件生命周期

- 所有收藏接口使用现有认证中间件。
- 服务端按用户 ID 查询收藏，禁止通过修改路径访问其他用户资源。
- 从消息收藏时重新检查消息参与者关系和文件访问权限。
- 创建自定义资源时增加文件引用；删除收藏时减少引用。
- 只有消息、用户表情资源和其他业务引用全部为零时，清理任务才可以删除文件。
- 原始文件路径不直接作为客户端写入参数，客户端使用服务端返回的资源 ID。

## 5. 客户端架构

### 5.1 数据层

扩展 `client/lib/services/emoji_favorite_service.dart` 的收藏项模型，新增：

- 服务端收藏 ID
- 自定义资源 ID
- `fileId`
- 原图 URL
- 缩略图 URL
- MIME 类型
- `isAnimated`
- 排序位置

新增 `client/lib/services/emoji_favorite_repository.dart` 封装 Dio 请求。`EmojiFavoriteService` 负责内存缓存、通知 UI、乐观更新和失败回滚。

本地缓存键按账号隔离：

```text
emoji_favorites_cache_v2_<user_id>
```

登录用户切换或退出时不能继续展示上一个账号的收藏。旧的 `emoji_favorites_v1` 数据在首次同步时迁移：内置表情通过 `sticker_id` 上传收藏关系；已有图片 URL 只有在服务端能通过文件哈希映射到当前用户授权的文件时才迁移，否则丢弃并记录诊断日志，避免把无法证明归属的 URL 写入云端收藏。

### 5.2 表情面板

修改 `client/lib/widgets/emoji/app_emoji_panel.dart`：

- 增加 `onAddImage` 回调。
- 收藏页首格渲染添加按钮。
- 收藏网格使用服务端缩略图。
- GIF 单元不播放原始动画。
- 长按收藏项触发删除回调。
- 空、加载、错误和离线缓存状态都可见。
- 为添加、删除、发送和失败状态提供语义标签。

### 5.3 聊天详情和消息发送

修改 `client/lib/screens/chat_detail_screen.dart`：

- 添加系统图片选择器入口。
- 上传并创建收藏资源。
- 长按聊天图片时调用 `from-message` 接口。
- 发送收藏图片时把资源的 `fileId` 交给消息发送层。

修改 `client/lib/providers/message_provider.dart`：

- 增加复用已有 `fileId` 的图片消息发送方法。
- 保留现有本地图片上传路径。
- 收藏图片发送失败时允许重试，不重新创建收藏资源。

## 6. 状态矩阵

必须覆盖以下状态：

```text
收藏页：loading / loaded / empty / offline-cache / error
上传：idle / picking / uploading / creating / success / failed
收藏：idle / adding / added / removing / removed / undo / failed
发送：preview / sending / sent / failed / retry
GIF：thumbnail-loading / thumbnail-ready / thumbnail-error
界面：keyboard / emoji / media / reduced-motion / dark / large-text
```

动画遵循现有 `AppMotion`：面板切换使用 `tab`，上传和删除使用即时状态反馈，不用装饰性位移动画。`MediaQuery.disableAnimationsOf(context)` 为真时保留颜色、透明度反馈，移除位移和缩放。

## 7. 测试与验收

### 服务端测试

- 账号只能读取自己的收藏。
- 同一文件哈希不会重复创建收藏资源。
- 同一用户不能重复收藏同一文件。
- 从消息收藏会检查权限。
- GIF 能生成首帧缩略图。
- 缩略图失败不会产生半条收藏记录。
- 删除收藏只减少引用，不删除仍被消息使用的文件。
- 达到 80 个收藏项、单文件 10 MB、总容量 200 MB 时返回明确错误。

### Flutter 单元测试

- 收藏模型 JSON 序列化和反序列化。
- 旧 `emoji_favorites_v1` 到新缓存格式的迁移。
- 账号缓存隔离。
- 乐观添加、删除、失败回滚和撤销。
- GIF、自定义资源和内置 sticker 的去重键。

### Flutter Widget/Interaction 测试

- 空收藏页第一个格子存在添加按钮。
- 新收藏排在第一个添加格之后的第一项。
- 点击 GIF 显示动态预览，不直接发送。
- 长按聊天图片显示添加操作。
- 已收藏图片显示取消收藏。
- 长按收藏项删除并可撤销。
- 上传失败、同步失败和发送失败可恢复。
- 44×44 命中区、tooltip 和语义标签存在。

### Golden / Design QA

按仓库基线验证：

- light 360×800
- light 390×844
- dark 360×800
- large-text 360×800，文字缩放 1.3
- 1.5 倍字号 overflow 压力测试
- 空状态、已有收藏、GIF 缩略图、删除撤销状态

完成标准：P0=0、P1=0；若有 P2 必须逐项说明。Windows 只用于回归检查，canonical Golden 不在 Windows 上更新。

## 8. 迁移和发布顺序

1. 先发布服务端模型、接口和 GIF 缩略图能力。
2. 客户端保留旧本地收藏读取，完成一次性迁移和账号隔离缓存。
3. 打开云端同步开关，验证新增、删除、长按添加和 GIF 发送。
4. 服务端稳定后再清理旧本地 URL-only 收藏逻辑。
5. 不修改 `docs/design/` 冻结决策；UI 继续复用现有 token、圆角、动效和无障碍规范。
