-- 私信图片元数据：为 files 表补充规范宽高，客户端借此按真实比例渲染私信图片。
-- 该脚本可重复执行；应用启动期也会经由 GORM AutoMigrate 增量补齐同名字段。
-- 历史数据 width/height 为 0，客户端回退到 intrinsic 布局；由 backfill 命令回填。

ALTER TABLE files
    ADD COLUMN IF NOT EXISTS width  INTEGER NOT NULL DEFAULT 0;

ALTER TABLE files
    ADD COLUMN IF NOT EXISTS height INTEGER NOT NULL DEFAULT 0;
