# 主题包投稿存储、商城开关与审核运维

正式部署统一使用 [DEPLOY.md](../../DEPLOY.md)，本文件不构成生产操作授权。接口与错误码见 [API](../../server/API.md#主题商城投稿与审核)，格式与对比度契约见 [主题包格式契约](../design/theme-pack-contract.md)。

## 存储与迁移

启动 `AutoMigrate` 新增 `theme_packs` 表，并为 `reports` 增加 `target_key` 列以承载主题版本族 UUID 举报对象。每次投稿落盘至 `UPLOAD_DIR/.theme-packs/<id>/`：

- `package.sltheme`：重编码去除图片元数据并写入规范 `manifest.json` 后的不可变主题包；
- `preview_light.jpg`、`preview_dark.jpg`：JPEG（质量 88）规范化预览图；
- `manifest.json`：供审核端读取比对的规范化描述副本。

投稿处理在 `UPLOAD_DIR/.theme-packs/.stage-<uuid>` 暂存目录内完成，计算一次规范包 SHA-256 后原子 `rename` 到正式目录，再在同一数据库事务中写入 `theme_packs`；事务回滚立即删除目标目录。该子目录与数据库必须在同一备份批次中保全，且禁止通过 Nginx 静态别名、CDN 或对象存储直接暴露 `/uploads/.theme-packs/*`。

## 网关与反向代理

`nginx/docker.conf` 与 `web/deploy/nginx.conf` 须同步保留以下两条路由规则：

- `/api/themes/submissions`：单独设置 `client_max_body_size 49m`（承载最大 48MB `.sltheme` 文件及 multipart 表单头），高于通用 `/api/` 的请求体上限；其余接口体积上限保持不变。
- `/theme/`：转发到 Go 服务（校验 UUID 后 `302` 跳转至 `/web/theme/:id`），避免被静态站点根路径兜底吞没。
- 公开版本包与预览图接口（`GET /api/themes/:familyId/versions/:version/package` 与 `/preview/:mode`）返回 `Cache-Control: public, no-cache` 并携带 `ETag` 与 `Range` 支持：正常状态下客户端缓存经 `If-None-Match` 命中 `304`，一旦作品被作者撤回或管理员下架，带 `If-None-Match` 的再验证请求也立即返回 `404`。

## 商城开关

`system_configs` 表中的 `theme_store_enabled` 控制在线商城可用性（未配置时默认开启；设为 `false`、`0` 或 `off` 时关闭）：

- 关闭后，公开目录（`GET /api/themes`）、详情（`GET /api/themes/:familyId`）、作者作品（`GET /api/users/:id/themes`）和新投稿（`POST /api/themes/submissions`）返回 `503 theme_store_disabled`；客户端商城入口收到关闭状态时不开放浏览与投稿，本机主题导入、应用、混搭导出和主题工坊不受影响。
- 已发布版本的不可变下载接口（`GET /api/themes/:familyId/versions/:version/package` 与 `/preview/:mode`）在开关关闭期间继续按版本状态服务已缓存目录的客户端续传。

## 审核、撤回与下架

- **根记录并发锁**：`ID == FamilyID` 的首版记录作为版本族根锁。发布新版本、审核、撤回和下架均先 `SELECT … FOR UPDATE` 锁住根记录，保证同一 `family_id` 最多只有一条 `approved` 记录，且高版本审核通过时自动将旧 `approved` 和低版本 `pending` 置为 `superseded`。管理员不能审核本人投稿。
- **撤回**：作者撤回 `pending` 版本仅影响该版本；撤回 `approved` 作品会将整个版本族置为 `withdrawn`，所有历史版本 URL 立即返回 `404`。
- **下架**：管理员调用 `POST /api/admin/themes/:familyId/remove` 或通过 `target_type=theme` 举报治理确认违规后，整个版本族置为 `removed` 并记录 `reasonCode` 与审计日志，目录、详情、所有版本包与预览图立即返回 `404`。用户已安装在本机的副本不会被远程擦除。
- **孤儿清理**：启动和每小时执行 `CleanupOrphans`，仅清理超过 24 小时的 `.stage-*` 目录及无有效非 `withdrawn` 数据库记录的目录；数据库不可用时中止清理并记录 `theme pack maintenance unavailable`。

## 回退

1. 先将 `system_configs.theme_store_enabled` 设为 `false`，停止新投稿与目录入口。
2. 客户端回退到旧版本时，旧版本忽略 `theme_appearance_v1`、`theme_previous_v1`，继续读取原有手动外观偏好 key（主题系统从不覆写原有手动 key），已迁移到 `themes/user/` 的自选壁纸按绝对路径继续可读；桌面小部件若存有 `appTheme`，旧版按跟随系统回退。
3. 服务端二进制先于客户端回退前须确认已关闭商城入口；保留 `theme_packs` 表与 `.theme-packs/` 私有卷，不执行删表或物理逆迁移。
