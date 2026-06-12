#!/bin/bash

# 检查是否提供了数据库名
if [ -z "$1" ]; then
    echo "使用方法: bash fix_postgres_data.sh <您的数据库名>"
    echo "例如: bash fix_postgres_data.sh postgres"
    echo "如果您不知道数据库名，通常是您的项目名或默认的 postgres"
    exit 1
fi

DB_NAME=$1

echo "==========================================="
echo "准备修复 PostgreSQL 数据库: $DB_NAME"
echo "正在为您执行：数据统计校准 & 主键序列修复"
echo "==========================================="

SQL_SCRIPT=$(cat << 'EOF'

-- 1. 重置所有帖子的评论数（排除被软删除的回复）
UPDATE posts 
SET reply_count = (SELECT COUNT(*) FROM replies WHERE replies.post_id = posts.id AND replies.status = 'normal');

-- 2. 重置所有帖子的点赞数（排除回复的赞）
UPDATE posts 
SET like_count = (SELECT COUNT(*) FROM likes WHERE likes.target_id = posts.id AND likes.target_type = 'post');

-- 3. 重置所有用户的总获赞数（仅累加该用户发出的帖子所得的点赞）
UPDATE users 
SET total_likes_received = (SELECT COALESCE(COUNT(*), 0) FROM likes WHERE target_type = 'post' AND target_id IN (SELECT id FROM posts WHERE author_id = users.id));

-- 4. 修复所有表的主键自增序列 (解决 500 创建失败的问题)
DO $$
DECLARE
    r record;
    seq_name text;
BEGIN
    FOR r IN SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    LOOP
        BEGIN
            EXECUTE 'SELECT pg_get_serial_sequence(''' || r.table_name || ''', ''id'')' INTO seq_name;
            IF seq_name IS NOT NULL THEN
                EXECUTE 'SELECT setval(''' || seq_name || ''', COALESCE((SELECT MAX(id) FROM ' || quote_ident(r.table_name) || '), 1), (SELECT MAX(id) IS NOT NULL FROM ' || quote_ident(r.table_name) || '))';
            END IF;
        EXCEPTION WHEN OTHERS THEN
        END;
    END LOOP;
END;
$$;
EOF
)

# 尝试作为 postgres 用户执行
sudo -u postgres psql -d "$DB_NAME" -c "$SQL_SCRIPT"

if [ $? -eq 0 ]; then
    echo "==========================================="
    echo "✅ 恭喜！数据校准与序列修复已成功完成！"
    echo "现在 App 应该可以正常发表评论、发帖子了。"
    echo "==========================================="
else
    echo "==========================================="
    echo "❌ 执行遇到了一点问题。"
    echo "请确认："
    echo "1. 数据库名称 '$DB_NAME' 是否拼写正确？"
    echo "2. 您当前登录的账号是否有权限执行 sudo -u postgres ？"
    echo "==========================================="
fi
