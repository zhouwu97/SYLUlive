# 自定义表情包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在聊天表情面板的心形收藏页加入账号级云同步的自定义 JPG/JPEG、PNG、GIF 表情，支持压缩、50 MB 配额、长按聊天图片收藏、长按删除撤销，并使用已有 `file_id` 发送。

**Architecture:** 服务端新增用户表情资源与收藏关系，复用现有 `models.File`、上传授权和引用计数；图片在服务端规范化压缩，GIF 另生成静态首帧缩略图，事务内校验 80 项和 50 MB 配额。客户端把旧 URL-only 本地收藏迁移为账号隔离的云端资源缓存，`AppEmojiPanel` 只负责展示和交互，`ChatDetailScreen` 负责选择/收藏/发送编排，`MessageProvider` 负责复用 `file_id`。

**Tech Stack:** Go 1.25、Gin、GORM、SQLite/Postgres、标准 `image`/`image/gif`/`image/jpeg`/`image/png`、Flutter/Dart、Dio、`image_picker`、现有 Provider 和设计 token。

---

## 文件地图

| 文件 | 职责 |
| --- | --- |
| `server/internal/models/emoji_favorite.go` | `UserEmojiAsset`、`UserEmojiFavorite` 及唯一索引/枚举 |
| `server/internal/services/emoji_image_service.go` | JPG/PNG/GIF 压缩、尺寸限制、GIF 首帧缩略图 |
| `server/internal/services/emoji_favorite_service.go` | 配额、去重、权限、收藏事务和文件引用计数 |
| `server/internal/handlers/emoji_favorite.go` | 四个 HTTP 接口和错误映射 |
| `server/cmd/main.go` | AutoMigrate、服务构造和 `/api/emoji/favorites` 路由注册 |
| `server/internal/services/emoji_*_test.go`、`server/internal/handlers/emoji_favorite_test.go` | 服务端单元/接口测试 |
| `client/lib/services/emoji_favorite_repository.dart` | Dio 云端 API 适配和响应解析 |
| `client/lib/services/emoji_favorite_service.dart` | 账号隔离缓存、迁移、乐观更新/回滚/撤销 |
| `client/lib/widgets/emoji/app_emoji_panel.dart` | 添加格、缩略图、状态、删除手势和语义 |
| `client/lib/screens/chat_detail_screen.dart` | 图片选择、自定义表情预览、长按消息收藏和 Snackbar 撤销 |
| `client/lib/providers/message_provider.dart` | `file_id` 直发、失败重试和原有本地图片上传兼容 |
| `client/test/services/emoji_favorite_*_test.dart`、`client/test/widgets/emoji/app_emoji_panel_test.dart`、`client/test/chat_detail_screen_test.dart`、`client/test/message_provider_test.dart` | Dart 单元、Widget、交互和回归测试 |

### Task 1: 服务端模型、配置和文件引用契约

**Files:**
- Create: `server/internal/models/emoji_favorite.go`
- Create: `server/internal/models/emoji_favorite_test.go`
- Modify: `server/cmd/main.go:190-270`
- Modify: `server/internal/models/file.go:28-37`（仅在现有引用计数语义不足时补充中文注释，不改变字段）

- [ ] **Step 1: Write the failing model test**

在 `server/internal/models/emoji_favorite_test.go` 写入以下行为测试，先验证表结构和唯一约束：

```go
func TestEmojiFavoriteModelsPreventDuplicateUserAssetAndFavorite(t *testing.T) {
    db, err := gorm.Open(sqlite.Open("file:emoji_models?mode=memory&cache=shared"), &gorm.Config{})
    require.NoError(t, err)
    require.NoError(t, db.AutoMigrate(&UserEmojiAsset{}, &UserEmojiFavorite{}))

    asset := UserEmojiAsset{UserID: 7, FileID: 11, MimeType: "image/gif", IsAnimated: true}
    require.NoError(t, db.Create(&asset).Error)
    require.Error(t, db.Create(&UserEmojiAsset{UserID: 7, FileID: 11}).Error)

    favorite := UserEmojiFavorite{UserID: 7, Kind: EmojiFavoriteKindCustom, AssetID: &asset.ID}
    require.NoError(t, db.Create(&favorite).Error)
    require.Error(t, db.Create(&UserEmojiFavorite{UserID: 7, Kind: EmojiFavoriteKindCustom, AssetID: &asset.ID}).Error)
}
```

- [ ] **Step 2: Run the model test and observe the expected failure**

Run `cd server; go test ./internal/models -run TestEmojiFavoriteModelsPreventDuplicateUserAssetAndFavorite -v`.
Expected: FAIL because the two model types and unique indexes do not exist.

- [ ] **Step 3: Implement the model contract**

在 `emoji_favorite.go` 定义：

```go
const (
    EmojiFavoriteKindBuiltin = "builtin"
    EmojiFavoriteKindCustom  = "custom"
)

type UserEmojiAsset struct {
    ID uint `gorm:"primaryKey"`
    UserID uint `gorm:"not null;uniqueIndex:idx_user_emoji_asset_file"`
    FileID uint `gorm:"not null;uniqueIndex:idx_user_emoji_asset_file"`
    ThumbnailPath string `gorm:"size:500"`
    MimeType string `gorm:"size:100;not null"`
    IsAnimated bool `gorm:"not null;default:false"`
    Width int `gorm:"not null"`
    Height int `gorm:"not null"`
    CreatedAt time.Time
    UpdatedAt time.Time
}

type UserEmojiFavorite struct {
    ID uint `gorm:"primaryKey"`
    UserID uint `gorm:"not null;uniqueIndex:idx_user_emoji_favorite_builtin"`
    Kind string `gorm:"size:16;not null"`
    StickerID *string `gorm:"size:100;uniqueIndex:idx_user_emoji_favorite_builtin"`
    AssetID *uint `gorm:"uniqueIndex:idx_user_emoji_favorite_custom"`
    SortOrder int64 `gorm:"not null;index"`
    CreatedAt time.Time
    UpdatedAt time.Time
}
```

使用复合索引确保同一用户只能拥有同一 `file_id` 资源和同一内置 sticker；服务层额外校验 `Kind` 与对应外键非空关系，避免 NULL 唯一索引绕过约束。将两个模型加入 `db.AutoMigrate`，不修改既有设计 ADR。

- [ ] **Step 4: Run the model and existing file-reference tests**

Run `cd server; go test ./internal/models ./internal/services -run 'Emoji|FileReference' -v`。
Expected: PASS，既有 `models.File.RefCount` 和 `FileUploadGrant` 行为不变。

- [ ] **Step 5: Commit the model contract**

```bash
git add server/internal/models/emoji_favorite.go server/internal/models/emoji_favorite_test.go server/cmd/main.go server/internal/models/file.go
git commit -m "feat: add custom emoji persistence models"
```

### Task 2: 图片/GIF 服务端规范化压缩

**Files:**
- Create: `server/internal/services/emoji_image_service.go`
- Create: `server/internal/services/emoji_image_service_test.go`
- Modify: `server/internal/handlers/upload.go:95-178`（仅复用 GIF 缩略图能力，不改变普通上传返回协议）

- [ ] **Step 1: Write failing compression tests**

覆盖静态透明 PNG、无透明 PNG、JPEG 和多帧 GIF：

```go
func TestNormalizeEmojiKeepsTransparentPngAndBoundsStaticImage(t *testing.T) { /* 1600x800 RGBA -> <=512 longest edge, image/png, alpha retained */ }
func TestNormalizeEmojiConvertsOpaquePngToJpeg(t *testing.T) { /* RGB PNG -> image/jpeg, quality 82 */ }
func TestNormalizeEmojiReencodesGifWithFramesAndDelays(t *testing.T) { /* two frames, delay [5, 12], longest edge <=512 */ }
func TestBuildEmojiThumbnailUsesFirstGifFrame(t *testing.T) { /* output PNG <=480, first frame color/size matches */ }
func TestNormalizeEmojiRejectsOverTenMegabytes(t *testing.T) { /* compressed output >10MB returns ErrEmojiFileTooLarge */ }
```

测试必须通过 `image.DecodeConfig`、`gif.GIF.Delay` 和像素 alpha 检查真实输出，不能只断言函数返回 nil。

- [ ] **Step 2: Run the compression tests and confirm they fail**

Run `cd server; go test ./internal/services -run 'TestNormalizeEmoji|TestBuildEmojiThumbnail' -v`。
Expected: FAIL because the normalizer and typed errors are absent。

- [ ] **Step 3: Implement deterministic normalization**

在 `emoji_image_service.go` 固定导出契约：

```go
const (
    EmojiMaxDimension = 512
    EmojiThumbDimension = 480
    EmojiMaxCompressedBytes int64 = 10 * 1024 * 1024
)

type NormalizedEmoji struct {
    Bytes []byte
    MimeType string
    Width int
    Height int
    IsAnimated bool
    Thumbnail []byte
}

func NormalizeEmoji(src []byte, mimeType string) (NormalizedEmoji, error)
func BuildEmojiThumbnail(normalized NormalizedEmoji) ([]byte, error)
```

静态图最长边缩放到 512；JPEG 使用质量 82；有 alpha 的 PNG 保留 PNG 并使用最高压缩；无 alpha PNG 转 JPEG。GIF 使用 `gif.DecodeAll`，逐帧按相同比例缩放，保留 `Delay`、`Disposal` 和帧顺序，再以 `gif.EncodeAll` 输出；从压缩 GIF 第一帧生成最长边 480 的 PNG 缩略图。所有输出先写内存，再检查 10 MB，超过时返回可比较的 `ErrEmojiFileTooLarge`。

- [ ] **Step 4: Extend GIF variant handling without regressing public uploads**

把 `ensureImageVariant` 的 GIF 分支改为读取 GIF 第一帧并输出 PNG 或 GIF 变体所需的格式，保留已有 `source_thumb`/`source_medium` 缓存命中语义；新增测试确认重复请求不重写文件，普通 JPG/PNG 测试继续通过。

- [ ] **Step 5: Run focused and full server tests**

Run `cd server; go test ./internal/services ./internal/handlers -run 'Emoji|EnsureImageVariant|ImageVariant' -v`，再运行 `go test ./...`。
Expected: PASS，无新增 data race 或 MIME 回归。

- [ ] **Step 6: Commit compression service**

```bash
git add server/internal/services/emoji_image_service.go server/internal/services/emoji_image_service_test.go server/internal/handlers/upload.go server/internal/handlers/upload_variant_test.go
git commit -m "feat: normalize custom emoji images and gifs"
```

### Task 3: 收藏服务、50 MB 配额和文件生命周期

**Files:**
- Create: `server/internal/services/emoji_favorite_service.go`
- Create: `server/internal/services/emoji_favorite_service_test.go`
- Modify: `server/internal/services/file_reference_service.go`（复用或补充原子增减引用函数）

- [ ] **Step 1: Write failing service tests**

测试服务层的事务行为和用户边界：

```go
func TestCreateCustomEmojiDeduplicatesByUserAndFileHash(t *testing.T) { /* second create returns existing asset/favorite */ }
func TestCreateCustomEmojiRejectsCountAndQuota(t *testing.T) { /* 80 items -> ErrEmojiFavoriteLimit; 50MB -> ErrEmojiQuotaExceeded */ }
func TestCreateFromMessageChecksParticipantAndFileOwnership(t *testing.T) { /* foreign conversation/file -> ErrEmojiMessageForbidden */ }
func TestDeleteFavoriteDecrementsRefButKeepsReferencedFile(t *testing.T) { /* RefCount remains >0 when message reference exists */ }
func TestDeleteThenCreateReclaimsCompressedBytes(t *testing.T) { /* deleting last asset allows next 50MB allocation */ }
```

- [ ] **Step 2: Run tests to verify the missing behavior**

Run `cd server; go test ./internal/services -run 'TestCreateCustomEmoji|TestDeleteFavorite' -v`。
Expected: FAIL because service methods and typed errors are absent。

- [ ] **Step 3: Implement service API and typed errors**

实现以下明确方法：

```go
const (
    MaxEmojiFavoriteCount = 80
    MaxEmojiQuotaBytes int64 = 50 * 1024 * 1024
)

var (
    ErrEmojiFavoriteLimit = errors.New("emoji favorite limit exceeded")
    ErrEmojiQuotaExceeded = errors.New("emoji quota exceeded")
    ErrEmojiDuplicate = errors.New("emoji already favorited")
    ErrEmojiMessageForbidden = errors.New("message image is not accessible")
)

type EmojiFavoriteService struct { DB *gorm.DB; UploadDir string }
func (s *EmojiFavoriteService) List(ctx context.Context, userID uint) ([]EmojiFavoriteView, error)
func (s *EmojiFavoriteService) CreateBuiltin(ctx context.Context, userID uint, stickerID string) (EmojiFavoriteView, error)
func (s *EmojiFavoriteService) CreateCustom(ctx context.Context, userID uint, fileID uint) (EmojiFavoriteView, error)
func (s *EmojiFavoriteService) CreateFromMessage(ctx context.Context, userID uint, messageID uint) (EmojiFavoriteView, error)
func (s *EmojiFavoriteService) Delete(ctx context.Context, userID uint, favoriteID uint) error
```

所有创建/删除操作在同一 GORM transaction 内：锁定当前用户的自定义资源汇总，按 `models.File.Size` 累计压缩文件大小；限制 80 项（内置 + 自定义）和 50 MB（仅自定义压缩文件）。创建前校验 `FileUploadGrant`、MIME、磁盘存在性和 hash 去重；`CreateFromMessage` 通过消息参与者/文件归属校验，不接受 URL。新增资源增加 `RefCount`，删除收藏关系减少引用；仅当消息、资源等所有引用为零时交给现有清理逻辑删除物理文件。服务返回 `compressed_size`、`quota_used`、`quota_limit`。

- [ ] **Step 4: Run focused service tests, then all Go tests**

Run `cd server; go test ./internal/services -run 'Emoji|FileReference' -v`，再运行 `go test ./...`。
Expected: PASS，两个并发创建不会突破配额或重复计数。

- [ ] **Step 5: Commit service and lifecycle changes**

```bash
git add server/internal/services/emoji_favorite_service.go server/internal/services/emoji_favorite_service_test.go server/internal/services/file_reference_service.go
git commit -m "feat: enforce custom emoji quota and references"
```

### Task 4: 收藏 HTTP API 与路由

**Files:**
- Create: `server/internal/handlers/emoji_favorite.go`
- Create: `server/internal/handlers/emoji_favorite_test.go`
- Modify: `server/cmd/main.go:1040-1080`（构造 handler/service）和 `server/cmd/main.go:1076-1185`（认证路由）

- [ ] **Step 1: Write failing handler tests**

使用现有 Gin 测试和认证上下文，先固定协议：

```go
func TestListEmojiFavoritesOnlyReturnsCurrentUser(t *testing.T) { /* GET -> 200, no foreign rows */ }
func TestCreateFromMessageAcceptsMessageIDOnly(t *testing.T) { /* POST {"message_id": 42}; URL/path fields ignored */ }
func TestDeleteEmojiFavoriteIsUserScoped(t *testing.T) { /* foreign id -> 404/403 and row remains */ }
func TestQuotaErrorHasStableCode(t *testing.T) { /* 409, {"code":"emoji_quota_exceeded","quota_used":...,"quota_limit":52428800} */ }
```

- [ ] **Step 2: Run handler tests and observe failure**

Run `cd server; go test ./internal/handlers -run 'EmojiFavorite' -v`。
Expected: FAIL because routes and handlers are not registered。

- [ ] **Step 3: Implement response DTO and four handlers**

`GET /api/emoji/favorites` 返回 `{items, quota_used, quota_limit, favorite_limit}`；`POST /api/emoji/favorites` 只接受 `kind=builtin, sticker_id` 或 `kind=custom, file_id`；`POST /api/emoji/favorites/from-message` 只接受 `message_id`；`DELETE /api/emoji/favorites/:id` 只删除当前用户记录。统一将错误映射为 `400` 格式错误、`403` 权限错误、`404` 不存在、`409` 重复/数量/配额，响应字段包含 `id/kind/sticker_id/asset_id/file_id/url/thumbnail_url/mime_type/is_animated/sort_order/compressed_size/quota_used`。

- [ ] **Step 4: Register migration, service and authenticated routes**

在 `main.go` 的 `AutoMigrate` 加入两个模型；在认证 `/api` group 下注册：

```go
emojiFavorites := auth.Group("/emoji/favorites")
emojiFavorites.GET("", emojiFavoriteHandler.List)
emojiFavorites.POST("", emojiFavoriteHandler.Create)
emojiFavorites.POST("/from-message", emojiFavoriteHandler.CreateFromMessage)
emojiFavorites.DELETE("/:id", emojiFavoriteHandler.Delete)
```

确保 handler 使用现有 `AuthMiddleware(db, cfg.JWTSecret)`，不新增未认证的文件读取路径。

- [ ] **Step 5: Run API and full server verification**

Run `cd server; go test ./internal/handlers -run 'EmojiFavorite|UploadVariant' -v`，再运行 `go test ./...`。

- [ ] **Step 6: Commit API surface**

```bash
git add server/internal/handlers/emoji_favorite.go server/internal/handlers/emoji_favorite_test.go server/cmd/main.go
git commit -m "feat: expose custom emoji favorite APIs"
```

### Task 5: Flutter 云端 repository、模型和账号隔离缓存

**Files:**
- Create: `client/lib/services/emoji_favorite_repository.dart`
- Create: `client/test/services/emoji_favorite_repository_test.dart`
- Modify: `client/lib/services/emoji_favorite_service.dart`
- Modify: `client/test/emoji_favorite_service_test.dart`

- [ ] **Step 1: Write failing Dart model and repository tests**

先固定响应解析和请求契约：

```dart
test('parses custom animated item and quota fields', () {
  final item = EmojiFavoriteItem.fromApiJson({
    'id': 9, 'kind': 'custom', 'asset_id': 12, 'file_id': 33,
    'url': '/uploads/a.gif', 'thumbnail_url': '/uploads/a_thumb.png',
    'mime_type': 'image/gif', 'is_animated': true,
    'compressed_size': 1024, 'quota_used': 1024,
  });
  expect(item.fileId, 33);
  expect(item.thumbnailUrl, '/uploads/a_thumb.png');
  expect(item.isAnimated, isTrue);
});

test('repository posts message id instead of image URL', () async { /* Dio adapter asserts path and body == {'message_id': 42} */ });
```

- [ ] **Step 2: Run tests and verify they fail**

Run `cd client; flutter test test/services/emoji_favorite_repository_test.dart test/emoji_favorite_service_test.dart`。
Expected: FAIL because API fields, repository and account cache are absent。

- [ ] **Step 3: Implement repository and expanded item model**

`EmojiFavoriteRepository` 接受 `Dio`，提供 `fetchFavorites/createBuiltin/createCustom/createFromMessage/delete`；Dio 错误转换为带 `code/quotaUsed/quotaLimit` 的 `EmojiFavoriteException`。`EmojiFavoriteItem` 增加服务端 favorite ID、asset ID、file ID、原图/缩略图 URL、MIME、动画标志、排序和压缩大小，同时保留旧构造器供评论/帖子入口编译。

- [ ] **Step 4: Implement account-isolated cache and v1 migration**

把缓存键固定为 `emoji_favorites_cache_v2_<user_id>`，`EmojiFavoriteService` 注入 `userId`、repository 和 preferences loader；登录切换/退出清空内存缓存并停止旧账号的通知。首次同步时将 v1 sticker 通过 `createBuiltin` 迁移；v1 图片只在 repository 能按授权文件 hash 映射时迁移，否则丢弃并写入现有诊断日志。网络失败时展示并标记 offline cache，首次无缓存时进入 error。

- [ ] **Step 5: Test optimistic add/delete/undo and migration**

补充测试：

```dart
test('failed optimistic delete restores original index', () async { /* repository throws; list order unchanged */ });
test('undo recreates favorite with cached asset id', () async { /* delete then undo -> POST custom file_id */ });
test('user cache keys cannot leak across account switch', () async { /* user 7 item absent after switch to user 8 */ });
test('v1 URL-only image without authorized hash is discarded', () async { /* no POST with arbitrary URL */ });
```

Run `cd client; flutter test test/services/emoji_favorite_repository_test.dart test/emoji_favorite_service_test.dart`，Expected: PASS。

- [ ] **Step 6: Commit client data layer**

```bash
git add client/lib/services/emoji_favorite_repository.dart client/lib/services/emoji_favorite_service.dart client/test/services/emoji_favorite_repository_test.dart client/test/emoji_favorite_service_test.dart
git commit -m "feat: sync emoji favorites per account"
```

### Task 6: 表情面板添加格、缩略图和删除撤销 UI

**Files:**
- Modify: `client/lib/widgets/emoji/app_emoji_panel.dart`
- Modify: `client/test/widgets/emoji/app_emoji_panel_test.dart`
- Create: `client/test/widgets/emoji/app_emoji_panel_golden_test.dart`
- Check: `docs/design/DESIGN_SYSTEM.md`, `docs/design/MOTION.md`, `docs/design/ACCESSIBILITY.md`, `docs/design/DESIGN_QA.md` and relevant `docs/design/adr/*`

- [ ] **Step 1: Write failing widget tests for the state matrix**

新增测试断言：

```dart
testWidgets('favorite page always puts add image cell first', (tester) async { /* key emoji-add-image at index 0 */ });
testWidgets('custom gif uses thumbnail and reports animated semantics', (tester) async { /* no GIF animation widget in grid; tap calls selected item */ });
testWidgets('long press removal exposes undo action', (tester) async { /* delete callback then SnackBar action 撤销 */ });
testWidgets('quota error shows used and remaining capacity', (tester) async { /* 50MB error text remains readable at 1.3 text scale */ });
```

- [ ] **Step 2: Run widget tests to confirm failure**

Run `cd client; flutter test test/widgets/emoji/app_emoji_panel_test.dart test/widgets/emoji/app_emoji_panel_golden_test.dart`。
Expected: FAIL because the add cell, thumbnail fields, callbacks and undo state do not exist。

- [ ] **Step 3: Implement panel behavior using existing tokens**

给 `AppEmojiPanel` 增加 `onAddImage`、`onFavoriteRemoved`、`onFavoriteUndo`、`uploadState` 和 quota 参数；收藏页即使为空也渲染 `[＋ 添加图片]`，之后才渲染自定义/内置收藏，新增项顺序由服务端列表保证。自定义 GIF 网格只读 `thumbnailUrl`，静态图片同样优先缩略图；点击仍调用选择回调进入输入栏，不直接发送。长按调用删除回调并显示可撤销 Snackbar；命中区域保持至少 44×44 logical px，添加/删除/处理中/错误提供 `Semantics`、tooltip 和可读状态。

- [ ] **Step 4: Add golden and accessibility coverage**

生成/验证 light 360×800、light 390×844、dark 360×800、large-text 360×800（1.3）下的空收藏、已有 GIF、删除撤销状态；`MediaQuery.disableAnimationsOf(context)` 时仅保留透明度/颜色反馈。Windows 不更新 canonical golden，只做 overflow 和 `tester.takeException()` 回归。

- [ ] **Step 5: Run focused Flutter verification**

Run `cd client; flutter analyze lib/widgets/emoji/app_emoji_panel.dart; flutter test test/widgets/emoji/app_emoji_panel_test.dart test/widgets/emoji/app_emoji_panel_golden_test.dart`。

- [ ] **Step 6: Commit panel UI**

```bash
git add client/lib/widgets/emoji/app_emoji_panel.dart client/test/widgets/emoji/app_emoji_panel_test.dart client/test/widgets/emoji/app_emoji_panel_golden_test.dart
git commit -m "feat: add custom emoji panel interactions"
```

### Task 7: 聊天选择、长按收藏、预览发送和 `file_id` 复用

**Files:**
- Modify: `client/lib/screens/chat_detail_screen.dart`
- Modify: `client/lib/providers/message_provider.dart`
- Modify: `client/test/chat_detail_screen_test.dart`
- Modify: `client/test/message_provider_test.dart`

- [ ] **Step 1: Write failing provider and chat interaction tests**

固定直发和长按协议：

```dart
test('sendFavoriteImage posts existing file id without uploading bytes', () async { /* Dio records no /upload and POST /messages has file_id */ });
testWidgets('long press image exposes add to emoji action', (tester) async { /* sheet contains 添加到表情包; repository receives message_id */ });
testWidgets('favorite selection previews before send', (tester) async { /* selected GIF preview and remove control; no send until send button */ });
testWidgets('duplicate message image shows already favorited state', (tester) async { /* sheet title 已在表情包中/取消收藏 */ });
```

- [ ] **Step 2: Run tests and observe expected failures**

Run `cd client; flutter test test/message_provider_test.dart test/chat_detail_screen_test.dart`。
Expected: FAIL because `sendFavoriteImage` and `from-message` wiring are absent。

- [ ] **Step 3: Add `file_id` direct-send path to `MessageProvider`**

增加：

```dart
Future<Message?> sendFavoriteImageMessage(int targetUserId, EmojiFavoriteItem favorite, {int? senderId})
```

它用 `sendMessage(..., fileId: favorite.fileId, localImagePath: null)` 创建 pending 消息，直接进入已有 `sending/failed/retry` 状态；只保留 `sendImageMessage(XFile)` 的原有上传路径。重试时如果 pending 已有 `fileId`，禁止再次调用 `/upload`。

- [ ] **Step 4: Wire `ChatDetailScreen` and panel callbacks**

在 `AppEmojiPanel` 的 `onAddImage` 中调用 `ImagePicker.pickImage(source: gallery)`，接受 JPG/JPEG/PNG/GIF，显示 `picking/compressing/uploading/creating` 状态，调用 `/upload` 后再调用 `POST /api/emoji/favorites`，处理 `emoji_quota_exceeded` 和单文件超限文案，并刷新 quota。点击自定义项只设置预览；发送按钮调用 provider 的 `sendFavoriteImageMessage`，GIF 使用压缩后的 `file_id`。预览可移除且不删除收藏。

在 `_showMessageActions` 中对图片/GIF 优先显示“添加到表情包”；调用 `POST /api/emoji/favorites/from-message` 传 `message_id`，服务端拒绝时提示权限错误；已收藏资源显示“已在表情包中/取消收藏”。内置 sticker 继续走现有 builtin 收藏兼容分支。

- [ ] **Step 5: Implement deletion undo and lifecycle cleanup**

长按收藏项执行乐观移除；Snackbar 的“撤销”使用缓存 favorite/asset/file ID 调用 create custom，失败时恢复原索引并提示。切换账号或退出聊天时移除服务监听，避免上一个账号的收藏继续渲染。

- [ ] **Step 6: Run focused, full, and analyze checks**

Run `cd client; flutter analyze lib/screens/chat_detail_screen.dart lib/providers/message_provider.dart lib/services/emoji_favorite_service.dart; flutter test test/message_provider_test.dart test/chat_detail_screen_test.dart test/emoji_favorite_service_test.dart test/widgets/emoji/app_emoji_panel_test.dart`。
Expected: PASS，且发送收藏图片的 Dio 记录中没有额外上传请求。

- [ ] **Step 7: Commit chat integration**

```bash
git add client/lib/screens/chat_detail_screen.dart client/lib/providers/message_provider.dart client/test/chat_detail_screen_test.dart client/test/message_provider_test.dart
git commit -m "feat: add custom emoji chat workflows"
```

### Task 8: 端到端回归、设计 QA 和发布开关

**Files:**
- Modify: `client/test/goldens/...` only for approved canonical baselines outside Windows
- Create: `server/internal/handlers/emoji_favorite_e2e_test.go`（使用现有 SQLite/Gin 测试 harness）
- Modify: `docs/superpowers/specs/2026-08-17-custom-emoji-design.md` only to link the completed plan/status; do not change `docs/design/`

- [ ] **Step 1: Add end-to-end acceptance tests**

覆盖完整链路：上传透明 PNG/GIF -> 压缩 -> 创建资源 -> 列表首位 -> 发送同一 `file_id` -> 删除收藏 -> 引用仍在时文件保留 -> 最后引用删除后释放配额；并覆盖两个账号不能互读、消息参与者权限和重复 hash 去重。

- [ ] **Step 2: Run repository verification**

在 `server` 运行 `go test ./...`；在 `client` 运行 `flutter analyze` 和相关全量 `flutter test`。对 UI 运行设计 QA：light/dark/large-text、1.5 倍字号 overflow、键盘/表情/媒体/reduced-motion 状态；失败时按 P0/P1/P2/P3 记录并修复，完成标准为 P0=0、P1=0。

- [ ] **Step 3: Check migration and rollout order**

验证服务端先发布模型/API/GIF 缩略图，再发布客户端 v2 cache 迁移和功能开关；旧 `emoji_favorites_v1` 仅在可证明文件归属时迁移。确认清理任务按压缩后的 `models.File.Size` 回收空间，未压缩原文件不会残留。

- [ ] **Step 4: Final checks and commit**

运行 `git diff --check`，并检查计划中没有未完成标记、模糊步骤或未定义类型；检查所有接口字段、Dart/Go 类型和错误码一致后提交：

```bash
git add -f docs/superpowers/plans/2026-08-17-custom-emoji.md server/internal/handlers/emoji_favorite_e2e_test.go
git add client/test/goldens
git commit -m "docs: add custom emoji implementation plan"
```

## 自检结果

- 规格覆盖：入口/添加格、JPG/PNG/GIF、服务端压缩、50 MB 配额、80 项上限、长按聊天图片、hash 去重、云同步、账号隔离、GIF 首帧缩略图、`file_id` 发送、长按删除撤销、引用计数、错误/离线/无障碍/Golden/发布顺序均有对应任务。
- 完整性扫描：计划不使用未完成标记、模糊步骤或未定义类型作为实现步骤；每个任务给出真实路径、类型/方法契约、失败测试和命令。
- 类型一致性：服务端统一使用 `UserEmojiAsset`、`UserEmojiFavorite`、`EmojiFavoriteService`、`EmojiFavoriteView`；客户端统一使用 `EmojiFavoriteItem`、`EmojiFavoriteRepository`、`EmojiFavoriteService`，API 字段统一为 `file_id`、`thumbnail_url`、`is_animated`、`compressed_size`、`quota_used`。
