#!/usr/bin/env bash
# Batch 7.1 Grade Detail Differential 验证脚本
#
# 使用方式：
#   export JIAOWU_USERNAME=学号
#   export JIAOWU_PASSWORD=密码
#   bash run_differential.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."

# 检查环境变量
if [ -z "${JIAOWU_USERNAME:-}" ] || [ -z "${JIAOWU_PASSWORD:-}" ]; then
    echo "错误: 缺少环境变量 JIAOWU_USERNAME 或 JIAOWU_PASSWORD" >&2
    exit 1
fi

echo "========================================" >&2
echo "Batch 7.1 Grade Detail Differential" >&2
echo "========================================" >&2
echo "" >&2

# 创建临时目录
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

PYTHON_RESULT="$TEMP_DIR/python_result.json"
DART_RESULT="$TEMP_DIR/dart_result.json"

# 运行 Python 查询
echo ">>> 运行 Python 端查询..." >&2
cd "$PROJECT_ROOT"
python3 tools/differential/python_query.py > "$PYTHON_RESULT" 2>&1 &
PYTHON_PID=$!

# 运行 Dart 查询
echo ">>> 运行 Dart 端查询..." >&2
dart run tools/differential/dart_query.dart > "$DART_RESULT" 2>&1 &
DART_PID=$!

# 等待两个查询完成
echo ">>> 等待查询完成..." >&2
wait $PYTHON_PID || {
    echo "错误: Python 查询失败" >&2
    exit 1
}
wait $DART_PID || {
    echo "错误: Dart 查询失败" >&2
    exit 1
}

echo "" >&2
echo ">>> Python 和 Dart 查询完成" >&2
echo "" >&2

# 运行比较
echo ">>> 运行 Differential 比较..." >&2
python3 tools/differential/compare.py "$PYTHON_RESULT" "$DART_RESULT"
