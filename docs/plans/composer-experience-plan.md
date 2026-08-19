# SYLUlive Composer 发帖体验执行计划（轨道 C）

**仓库：** `zhouwu97/SYLUlive`
**正式执行基线：** `MCP`
**基线提交：** `7bdf3a3ac29c1592edf567ce5efd503d31def76e`
**计划类型：** 发帖创作体验（标题 / 草稿 / 图片 / 上传状态）
**命名约定：** 本轨道全部使用 `C-N`，禁止使用 `UX-N`。

---

# 0. 定位

三条并行轨中的 **轨道 C**，负责发帖创作体验，不碰 Feed。

## 合并门

```text
UX-2 merge → C-1 / C-2 / C-3 可以开始
```

原因：C 后期可能改 `PostProvider.uploadImage()`，而 UX-2 正在动 `post_provider.dart`。
UX-2 合入后，C 可以和 UX-3 ~ UX-7 并行。

## 硬规则

执行 UX 计划文末「21. Parallel Track Conflict Rule」全部条款：

```text
- UX-2 合入前禁止修改 post_provider.dart
- Composer 不得修改 Feed Card / Home Feed
- 每创建一个新 branch，必须从最新 origin/MCP 创建
```

## 主要涉及文件（UX 计划不碰）

```text
client/lib/screens/publish/water_post_composer.dart
client/lib/services/post_draft_service.dart（如不存在则新建）
client/lib/screens/publish/widgets/publish_image_grid.dart
client/lib/providers/post_provider.dart（仅 C-3，且必须在 UX-2 合入后）
```

---

# 1. C-1：标题可选 + 草稿

branch：

```text
compose/draft-and-optional-title
```

## 目标

当前客户端仍然强制标题。改为：

```text
正文 required
标题 optional
```

同时上自动草稿。

## 范围

主要只动：

```text
water_post_composer.dart
post_draft_service.dart
```

## 要求

- 标题为空时允许发布，正文必填校验保留。
- 自动草稿：输入变化后防抖保存，重新进入 composer 恢复草稿。
- 草稿存储复用现有本地持久化方案，不新建数据库。
- 发布成功 / 放弃草稿时清理。
- 这批不碰 Feed。

---

# 2. C-2：图片模型统一 + 拖拽

branch：

```text
compose/image-ordering
```

## 目标

将：

```text
_existingImages
_selectedImages
```

统一为：

```text
List<PublishImageItem>
```

支持拖拽排序，最终顺序直接生成 `file_ids`。

## 范围

```text
client/lib/screens/publish/water_post_composer.dart
client/lib/screens/publish/widgets/publish_image_grid.dart
```

## 要求

- 已上传图片与待上传图片统一模型管理，消除两套列表并存。
- 拖拽排序遵循现有手势约定，不引入新依赖。
- 排序结果就是最终 `file_ids` 顺序。
- 不碰 Feed Card / Home Feed。

---

# 3. C-3：上传进度 / retry

branch：

```text
compose/upload-state
```

## 目标

此时才改 `PostProvider.uploadImage`。

## 要求

```text
2~3 张有限并发
per-image progress
per-image retry
失败不清空其它图片
```

## 范围

```text
client/lib/providers/post_provider.dart（UX-2 合入后）
water_post_composer.dart
publish_image_grid.dart
```

## 注意

- `post_provider.dart` 的修改必须等 UX-2 合入，并 rebase 最新 MCP 后进行。
- 上传状态机不得与 Feed 状态耦合。
- 失败重试只重试失败项，已成功图片状态保留。

---

# 4. 分支依赖

```text
UX-2 merge MCP
   ├── C-1 compose/draft-and-optional-title
   ├── C-2 compose/image-ordering
   └── C-3 compose/upload-state

C-2 依赖 C-1 的 composer 结构稳定后可并行，最终都基于最新 MCP 合并。
```

> 三条 C branch 互相独立创建，均从最新 `origin/MCP` 出发，
> 禁止基于另一条 C branch 的半成品串联。
