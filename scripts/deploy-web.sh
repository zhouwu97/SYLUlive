#!/usr/bin/env bash
# 一键发布 React Web（/web/）：本机构建 → 打包 → 上传 → 服务器 deploy/deploy-web 切换。
#
# 用法（仓库根目录）：
#   scripts/deploy-web.sh                 发布当前 HEAD
#   scripts/deploy-web.sh rollback        切回上一版本
#   scripts/deploy-web.sh status          查看线上版本
# 环境变量：DEPLOY_HOST（默认 ubuntu@101.36.125.129），SKIP_TESTS=1 跳过 check/test。
set -Eeuo pipefail

HOST=${DEPLOY_HOST:-ubuntu@101.36.125.129}
SSH=(ssh -o BatchMode=yes "$HOST")
cd "$(git rev-parse --show-toplevel)"

remote() {
	scp -q -o BatchMode=yes deploy/deploy-web "$HOST:/tmp/deploy-web"
	"${SSH[@]}" "sudo bash /tmp/deploy-web $*; rc=\$?; rm -f /tmp/deploy-web; exit \$rc"
}

case "${1:-}" in
	rollback | status) remote "$1"; exit ;;
	"") ;;
	*) echo "用法: scripts/deploy-web.sh [rollback|status]" >&2; exit 2 ;;
esac

# 产物必须对应一个确定的提交，Web 源码有未提交改动时拒绝发布。
if [[ -n "$(git status --porcelain -- web browser-extension packages pnpm-lock.yaml)" ]]; then
	echo "web/、browser-extension/ 或 packages/ 有未提交改动，先提交再发布" >&2
	exit 1
fi
SHA=$(git rev-parse HEAD)

pnpm install --frozen-lockfile
if [[ "${SKIP_TESTS:-}" != 1 ]]; then
	pnpm -r check
	pnpm test
fi
pnpm --filter @sylulive/web build

ARCHIVE=$(mktemp -t "web-${SHA:0:12}-XXXX.tar.gz")
trap 'rm -f "$ARCHIVE"' EXIT
tar -czf "$ARCHIVE" -C web/dist --transform 's,^\.,web,' .
echo "发布 $SHA（$(du -h "$ARCHIVE" | cut -f1)）到 $HOST"

scp -q -o BatchMode=yes "$ARCHIVE" "$HOST:/tmp/web-$SHA.tar.gz"
rc=0
remote "$SHA /tmp/web-$SHA.tar.gz" || rc=$?
"${SSH[@]}" "rm -f /tmp/web-$SHA.tar.gz" || true
exit $rc
