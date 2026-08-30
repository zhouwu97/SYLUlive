#!/usr/bin/env bash
# 图片管线上线验收脚本（发布门禁，只读，不修改任何数据或文件）。
#
# 本脚本是 fail-closed 门禁：PUBLIC_URL/PRIVATE_URL 缺失、变体轮询超时、
# 数据库统计不可用、pending 未下降、failed 超阈值、公开图缺变体任务，
# 任一命中都以非零退出。任一项失败都不要对外发布。
#
# 用法：
#   BASE_URL=https://example.com \
#   PUBLIC_URL=https://example.com/uploads/ab/<hash>.jpg \
#   PRIVATE_URL=https://example.com/uploads/cd/<private-hash>.jpg \
#     bash scripts/image_pipeline_verify.sh
#
# 可选环境变量：
#   VARIANT_WAIT_SECONDS  变体最长等待秒数（默认 120，每 5s 轮询；0 表示只查一次）
#   FAILED_MAX            image_variants.status='failed' 允许上限（默认 0）
#   PSQL_CMD              覆盖默认 docker compose psql，例如
#                         PSQL_CMD="psql -h 127.0.0.1 -U postgres -d shenliyuan"
#
# 依赖：curl。数据库统计依赖仓库根目录的 docker compose，或显式提供 PSQL_CMD。
# 建议在低流量窗口执行：运行期间新上传会创建新 pending 任务，可能让"pending 下降"检查失败。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASE_URL="${BASE_URL:-http://127.0.0.1}"
PUBLIC_URL="${PUBLIC_URL:-}"
PRIVATE_URL="${PRIVATE_URL:-}"
VARIANT_WAIT_SECONDS="${VARIANT_WAIT_SECONDS:-120}"
FAILED_MAX="${FAILED_MAX:-0}"
POLL_INTERVAL=5

failures=0
DB_OK=1
DB_OUT=""

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

if [ -z "$PUBLIC_URL" ] || [ -z "$PRIVATE_URL" ]; then
  printf 'FATAL  PUBLIC_URL 与 PRIVATE_URL 均为必填（一张公开图、一张无凭证不可访问的私有图）\n'
  printf '用法: BASE_URL=... PUBLIC_URL=... PRIVATE_URL=... bash scripts/image_pipeline_verify.sh\n'
  exit 2
fi

header_of() {
  local url="$1" header="$2"
  curl -sS -o /dev/null -D - --max-time 20 "$url" \
    | tr -d '\r' | awk -v h="${header}:" 'tolower($1) == tolower(h) { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
}

status_of() {
  local url="$1"; shift
  curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" "$url"
}

wait_for_200() {
  local url="$1" waited=0 code
  while :; do
    code="$(status_of "$url")"
    if [ "$code" = "200" ]; then return 0; fi
    if [ "$waited" -ge "$VARIANT_WAIT_SECONDS" ]; then
      printf '      最后状态码=%s url=%s\n' "$code" "$url"
      return 1
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
}

# db_scalar SQL：结果写入全局 DB_OUT，失败置 DB_OK=0（fail-closed）。
# 必须直接调用（如 `if db_scalar ...`），不能用 $(...) 包裹——子 shell 里的
# DB_OK 修改不会传播回主 shell，守卫会全部失效。
db_scalar() {
  DB_OUT=""
  local sql="$1" out rc
  if [ "$DB_OK" -ne 1 ]; then return 1; fi
  if [ -n "${PSQL_CMD:-}" ]; then
    read -r -a psql_argv <<< "$PSQL_CMD"
    out="$("${psql_argv[@]}" -At -c "$sql" 2>/dev/null)"
  else
    out="$(docker compose exec -T postgres psql -U postgres -d shenliyuan -At -c "$sql" 2>/dev/null)"
  fi
  rc=$?
  if [ $rc -ne 0 ]; then
    DB_OK=0
    return 1
  fi
  DB_OUT="$out"
  return 0
}

echo "== 0. pending 基线与数据库连通性 =="
pending0=""
if db_scalar "SELECT count(*) FROM image_variants WHERE status = 'pending'"; then
  pending0="$DB_OUT"
  info "数据库可用，pending 基线=${pending0}"
else
  fail "数据库统计不可用（docker compose 或 PSQL_CMD）；统计不达标不允许开启开关"
fi

echo
echo "== 1. 公开图片：状态码与缓存头 =="
public_status="$(status_of "$PUBLIC_URL")"
cache_control="$(header_of "$PUBLIC_URL" "Cache-Control")"
info "status=$public_status cache-control='${cache_control}'"
[ "$public_status" = "200" ] && pass "公开图片可访问" || fail "公开图片状态码应为 200，实际 $public_status"
case "$cache_control" in
  *"max-age=86400"*) pass "公开图片下发了有界 TTL（24h）" ;;
  *) fail "公开图片 Cache-Control 应包含 max-age=86400，实际 '${cache_control}'" ;;
esac
case "$cache_control" in
  *immutable*) fail "公开上传不得下发 immutable（access_scope 可动态撤回）" ;;
  *) pass "未下发 immutable" ;;
esac

echo
echo "== 2. 变体档位：thumb/medium 必须在 ${VARIANT_WAIT_SECONDS}s 内就绪 =="
for variant in _v1_thumb _v1_medium; do
  variant_url="${PUBLIC_URL%.*}${variant}.${PUBLIC_URL##*.}"
  if wait_for_200 "$variant_url"; then
    pass "变体就绪 ${variant}"
  else
    fail "变体 ${variant} 在 ${VARIANT_WAIT_SECONDS}s 内未就绪（worker 未运行或生成失败）"
  fi
done

echo
echo "== 3. 安全边界：私有图、路径穿越、internal 直连 =="
private_code="$(status_of "$PRIVATE_URL")"
[ "$private_code" = "404" ] && pass "无凭证访问私有图片被拒绝（404）" || fail "私有图片应返回 404，实际 $private_code"

traversal_code="$(status_of "${BASE_URL}/uploads/../../etc/passwd" --path-as-is)"
[ "$traversal_code" = "404" ] && pass "路径穿越被拒绝（404）" || fail "路径穿越应返回 404，实际 $traversal_code"

internal_code="$(status_of "${BASE_URL}/_internal/uploads/nonexistent.jpg")"
[ "$internal_code" = "404" ] && pass "internal 位置不可直接访问（404）" || fail "internal 直连应返回 404，实际 $internal_code"

echo
echo "== 4. 大图 viewer 抽样 =="
if [ "$DB_OK" -ne 1 ]; then
  info "跳过 viewer 抽样：数据库不可用（已计入失败）"
else
  if db_scalar "SELECT f.path FROM files f
      WHERE f.access_scope = 'public' AND f.mime_type IN ('image/jpeg','image/png')
        AND GREATEST(f.width, f.height) > 1280
      ORDER BY f.id DESC LIMIT 1"; then
    if [ -z "$DB_OUT" ]; then
      pass "无长边 >1280 的公开大图样本，viewer 抽样跳过（历史图宽高缺失时先跑 backfill_image_metadata）"
    else
      sample_url="${BASE_URL}${DB_OUT}"
      viewer_url="${sample_url%.*}_v1_viewer.${sample_url##*.}"
      info "样本 viewer_url=${viewer_url}"
      if wait_for_200 "$viewer_url"; then
        pass "大图 viewer 就绪（200）"
      else
        fail "大图 viewer 在 ${VARIANT_WAIT_SECONDS}s 内未就绪"
      fi
    fi
  else
    info "跳过 viewer 抽样：数据库已不可用（已计入失败）"
  fi
fi

echo
echo "== 5. 变体任务收敛统计 =="
if [ "$DB_OK" -ne 1 ]; then
  info "跳过收敛统计：数据库不可用（已计入失败）"
else
  pending1=""
  failed=""
  ready=""
  unsupported=""
  missing=""
  db_scalar "SELECT count(*) FROM image_variants WHERE status = 'pending'" && pending1="$DB_OUT"
  db_scalar "SELECT count(*) FROM image_variants WHERE status = 'failed'" && failed="$DB_OUT"
  db_scalar "SELECT count(*) FROM image_variants WHERE status = 'ready'" && ready="$DB_OUT"
  db_scalar "SELECT count(*) FROM image_variants WHERE status = 'unsupported'" && unsupported="$DB_OUT"
  db_scalar "SELECT count(*) FROM files f
      WHERE f.access_scope = 'public' AND f.mime_type LIKE 'image/%'
        AND NOT EXISTS (SELECT 1 FROM image_variants v WHERE v.file_id = f.id)" && missing="$DB_OUT"
  if [ "$DB_OK" -ne 1 ]; then
    fail "数据库统计执行失败"
  else
    info "pending=${pending1} ready=${ready} failed=${failed} unsupported=${unsupported} public_without_any_variant=${missing}"
    if [ "$pending0" = "0" ] && [ "$pending1" = "0" ]; then
      pass "无 pending 积压"
    elif [ "$pending1" -lt "$pending0" ]; then
      pass "pending 收敛中（${pending0} -> ${pending1}）"
    else
      fail "pending 未下降（${pending0} -> ${pending1}）：worker 未运行、停滞，或运行期间新任务创建快于处理（请在低流量窗口复跑）"
    fi
    if [ "$failed" -le "$FAILED_MAX" ]; then
      pass "failed=${failed} 未超过阈值 ${FAILED_MAX}"
    else
      fail "failed=${failed} 超过阈值 ${FAILED_MAX}"
    fi
    if [ "$missing" -eq 0 ]; then
      pass "公开图片均已建立变体任务记录"
    else
      fail "public_without_any_variant=${missing}：存在未建任务的公开图片，先跑 backfill_image_metadata 并重启 Go"
    fi
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "验收通过：无阻塞项。"
  exit 0
fi
echo "验收未通过：${failures} 项阻塞，按 DEPLOY.md 回退开关后再排查。"
exit 1
