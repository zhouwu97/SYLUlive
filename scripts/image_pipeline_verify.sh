#!/usr/bin/env bash
# 图片管线上线验收脚本（只做只读检查，不修改任何数据或文件）。
#
# 用途：在开启 IMAGE_VARIANT_WORKER_ENABLED / UPLOAD_USE_ACCEL_REDIRECT 之后，
# 验证状态收敛与安全边界仍然成立。任一项失败都不要对外发布。
#
# 前置：需要两个 URL —— 一张公开图片和一张私有（待审核/撤回）图片的完整地址。
#
# 用法：
#   BASE_URL=https://example.com \
#   PUBLIC_URL=https://example.com/uploads/ab/<hash>.jpg \
#   PRIVATE_URL=https://example.com/uploads/cd/<private-hash>.jpg \
#     bash scripts/image_pipeline_verify.sh
#
# 依赖：curl。可选依赖：docker compose（用于输出变体任务统计）。

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
PUBLIC_URL="${PUBLIC_URL:-}"
PRIVATE_URL="${PRIVATE_URL:-}"

failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

header_of() {
  local url="$1" header="$2"
  curl -sS -o /dev/null -D - --max-time 20 "$url" \
    | tr -d '\r' | awk -v h="${header}:" 'tolower($1) == tolower(h) { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
}

status_of() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1"
}

echo "== 1. 公开图片：状态码与缓存头 =="
if [ -n "$PUBLIC_URL" ]; then
  public_status="$(status_of "$PUBLIC_URL")"
  cache_control="$(header_of "$PUBLIC_URL" "Cache-Control")"
  content_type="$(header_of "$PUBLIC_URL" "Content-Type")"
  info "status=$public_status cache-control='${cache_control}' content-type='${content_type}'"

  [ "$public_status" = "200" ] && pass "公开图片可访问" || fail "公开图片状态码应为 200，实际 $public_status"
  case "$cache_control" in
    *"max-age=86400"*) pass "公开图片下发了有界 TTL（24h）" ;;
    *) fail "公开图片 Cache-Control 应包含 max-age=86400，实际 '${cache_control}'" ;;
  esac
  case "$cache_control" in
    *immutable*) fail "公开上传不得下发 immutable（access_scope 可动态撤回）" ;;
    *) pass "未下发 immutable" ;;
  esac
else
  info "未提供 PUBLIC_URL，跳过公开图片检查（建议提供后重跑）"
fi

echo
echo "== 2. 变体档位：thumb/medium 可用 =="
if [ -n "$PUBLIC_URL" ]; then
  for variant in _v1_thumb _v1_medium; do
    variant_url="${PUBLIC_URL%.*}${variant}.${PUBLIC_URL##*.}"
    code="$(status_of "$variant_url")"
    if [ "$code" = "200" ]; then
      pass "变体可用 ${variant}（200）"
    else
      # 变体尚未生成时回退原图，属于补偿过程中的临时状态，不是阻塞项。
      info "变体 ${variant} 尚未就绪（$code），客户端会回退原图；请稍后复查 image_variants 统计"
    fi
  done
else
  info "未提供 PUBLIC_URL，跳过变体检查"
fi

echo
echo "== 3. 安全边界：私有图、路径穿越、internal 直连 =="
if [ -n "$PRIVATE_URL" ]; then
  code="$(status_of "$PRIVATE_URL")"
  private_cache="$(header_of "$PRIVATE_URL" "Cache-Control")"
  info "private status=$code cache-control='${private_cache}'"
  [ "$code" = "404" ] && pass "无凭证访问私有图片被拒绝（404）" || fail "私有图片应返回 404，实际 $code"
else
  info "未提供 PRIVATE_URL，跳过私有图片检查"
fi

traversal_code="$(status_of "${BASE_URL}/uploads/../../etc/passwd")"
[ "$traversal_code" = "404" ] && pass "路径穿越被拒绝（404）" || fail "路径穿越应返回 404，实际 $traversal_code"

internal_code="$(status_of "${BASE_URL}/_internal/uploads/nonexistent.jpg")"
[ "$internal_code" = "404" ] && pass "internal 位置不可直接访问（404）" || fail "internal 直连应返回 404，实际 $internal_code"

echo
echo "== 4. 变体任务统计（需要 docker compose） =="
if command -v docker >/dev/null 2>&1; then
  docker compose exec -T postgres \
    psql -U postgres -d shenliyuan -c \
    "SELECT status, count(*) FROM image_variants GROUP BY status ORDER BY count(*) DESC;" \
    || info "无法执行 psql，可手动执行 scripts/image_pipeline_stats.sql"
else
  info "未检测到 docker，手动执行：docker compose exec -T postgres psql -U postgres -d shenliyuan -f - < scripts/image_pipeline_stats.sql"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "验收通过：无阻塞项。"
else
  echo "验收未通过：${failures} 项阻塞，按 DEPLOY.md 回退开关后再排查。"
fi
exit "$failures"
