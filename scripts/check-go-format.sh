#!/usr/bin/env bash
# 只检查「本次变更引入的 Go 文件」是否 gofmt 干净。
#
# 为什么不整仓 gofmt -l：仓库里有大量历史未格式化文件，全仓检查会把本次改动
# 淹没在既有噪声里，而 `gofmt -w` 会重排上千文件、污染 diff。
# 为什么单独成脚本：范围推导（push / pull_request / 手动触发 / 新分支 /
# force push 导致 before 不是祖先）本身容易写错，写成脚本才能在本机复跑验证。
#
# 输入全部来自环境变量，由 workflow 显式注入 GitHub 上下文：
#   EVENT_NAME   GitHub 事件名（push / pull_request / workflow_dispatch …）
#   COMMIT_SHA   本次构建的提交（默认 HEAD）
#   EVENT_BEFORE push 事件里的起始提交（新分支时为全零或缺失）
#   PR_BASE_SHA  pull_request 事件里的 base 提交
set -euo pipefail

COMMIT_SHA="${COMMIT_SHA:-HEAD}"
ZERO_SHA="0000000000000000000000000000000000000000"

# --diff-filter=d 丢掉已删除文件：gofmt 读不到它们会直接报错退出。
# -z + 数组传参保证带空格的路径不会被二次切分。
changed_go_files() {
  case "${EVENT_NAME:-}" in
    pull_request)
      if [ -z "${PR_BASE_SHA:-}" ]; then
        echo "pull_request 事件缺少 PR_BASE_SHA，拒绝把范围猜成全仓库" >&2
        return 1
      fi
      git diff -z --name-only --diff-filter=d "${PR_BASE_SHA}...${COMMIT_SHA}" -- '*.go'
      ;;
    push)
      local before="${EVENT_BEFORE:-}"
      if [ -n "$before" ] && [ "$before" != "$ZERO_SHA" ] &&
        git cat-file -e "${before}^{commit}" 2>/dev/null &&
        git merge-base --is-ancestor "$before" "$COMMIT_SHA" 2>/dev/null; then
        git diff -z --name-only --diff-filter=d "$before" "$COMMIT_SHA" -- '*.go'
      else
        # 新分支、force push 或 before 不可达：只能看被推上来的这批提交本身，
        # 逐个取第一个提交的父级会漏条，这里退化为「本次 HEAD 单提交的变更」。
        # --root 只对没有父提交的提交生效（仓库首个提交），否则它会静默查出 0 个文件。
        git diff-tree --root --no-commit-id --name-only -r -z --diff-filter=d "$COMMIT_SHA" -- '*.go'
      fi
      ;;
    *)
      git diff-tree --root --no-commit-id --name-only -r -z --diff-filter=d "$COMMIT_SHA" -- '*.go'
      ;;
  esac
}

# 范围推导失败必须让门禁红，而不是「没文件可查」地绿：先落到临时文件再读，
# 这样 `changed_go_files` 的非零退出（缺 PR_BASE_SHA、git diff 报错）能传到脚本。
file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT
changed_go_files >"$file_list"

files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done <"$file_list"

if [ "${#files[@]}" -eq 0 ]; then
  echo "本次变更没有需要格式检查的 Go 文件。"
  exit 0
fi

printf '待检查 %d 个变更 Go 文件：\n' "${#files[@]}"
printf '  %s\n' "${files[@]}"

# 同样不能吞掉 gofmt 自身的失败：读不到文件时「没有输出」不等于「格式没问题」。
gofmt_out="$(mktemp)"
if ! gofmt -l "${files[@]}" >"$gofmt_out"; then
  rm -f "$gofmt_out"
  echo "gofmt 执行失败（上面的文件里可能有读不到的路径）。" >&2
  exit 1
fi

unformatted=()
while IFS= read -r file; do
  [ -n "$file" ] && unformatted+=("$file")
done <"$gofmt_out"
rm -f "$gofmt_out"

if [ "${#unformatted[@]}" -eq 0 ]; then
  echo "格式检查通过。"
  exit 0
fi

printf 'gofmt 需要重排以下 %d 个文件：\n' "${#unformatted[@]}"
printf '  %s\n' "${unformatted[@]}"
gofmt -d "${unformatted[@]}"
echo "请对这些文件执行 gofmt（不要整仓 gofmt -w，那会重排历史未格式化文件）。"
exit 1
