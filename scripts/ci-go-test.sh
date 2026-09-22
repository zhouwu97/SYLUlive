#!/usr/bin/env bash
# 把 `go test` 的「零条匹配 / 整包无测试」从静默变绿变成红灯。
#
# 为什么需要：CI 里的 PostgreSQL 集成步骤用精选 `-run` 正则。Go 在这种调用
# 匹配不到任何测试时输出 `no tests to run` 并以 0 退出，于是「改坏一个测试名」
# 和「环境没配好」都会显示为通过。审计 R01 第 8 条要求零条匹配不得计为通过。
#
# 用法：ci-go-test.sh <最少测试条数> <go test 参数...>
#   例：ci-go-test.sh 1 ./internal/handlers -run '^TestSecurityEvent' -count=1
set -euo pipefail

MIN_TESTS="${1:-}"
shift
if ! [[ "$MIN_TESTS" =~ ^[0-9]+$ ]]; then
  echo "第一个参数必须是最少测试条数（整数），收到：'${MIN_TESTS}'" >&2
  exit 2
fi
if [ "$#" -eq 0 ]; then
  echo "缺少 go test 参数。" >&2
  exit 2
fi

json="$(mktemp)"
raw="$(mktemp)"
trap 'rm -f "$json" "$raw"' EXIT

# 保留 go test 的退出码：断言失败不能把真实测试失败洗成通过。
status=0
if go test -json "$@" >"$json" 2>"$raw"; then
  status=0
else
  status=$?
fi

# -json 每行一个事件，键顺序是 Time, Action, Package, Test；包级事件没有 Test，
# 所以用这段连续子串精确匹配测试结果行。一次 awk 扫完，避免 grep 无匹配时的
# 非零退出在 pipefail 下把正常路径打断。「no tests to run」在一个包里会出现两行
# （warning 与包摘要），所以按包名去重后计数。
summary="$(awk '
  /"Action":"pass","Package":"[^"]*","Test":/ { pass++ }
  /"Action":"fail","Package":"[^"]*","Test":/ {
    fail++
    if (match($0, /"Test":"[^"]*"/)) failed_names = failed_names " " substr($0, RSTART + 8, RLENGTH - 9)
  }
  /"Action":"skip","Package":"[^"]*","Test":/ {
    skip++
    if (match($0, /"Test":"[^"]*"/)) skipped_names = skipped_names " " substr($0, RSTART + 8, RLENGTH - 9)
  }
  /no tests to run/ {
    if (match($0, /"Package":"[^"]*"/)) {
      pkg = substr($0, RSTART + 11, RLENGTH - 12)
      if (!(pkg in seen)) { seen[pkg] = 1; empty++ }
    }
  }
  END { printf "%d %d %d %d|%s|%s", pass + 0, fail + 0, skip + 0, empty + 0, skipped_names, failed_names }
' "$json")"
counts="${summary%%|*}"
rest="${summary#*|}"
skipped_names="${rest%%|*}"
failed_names="${rest#*|}"
read -r passed failed skipped empty_packages <<<"$counts"
ran=$((passed + failed + skipped))

echo "go test 汇总：匹配 $ran 条（通过 $passed / 失败 $failed / 跳过 $skipped），无测试包 $empty_packages 个，退出码 $status"
if [ "$skipped" -gt 0 ]; then
  # 逐条列出被跳过的测试：审计要求「跳过不得计为通过」，那就得看得见跳过了什么。
  printf '跳过的测试：%s\n' "$skipped_names"
fi
if [ "$failed" -gt 0 ]; then
  printf '失败的测试：%s\n' "$failed_names"
fi

if [ "$status" -ne 0 ]; then
  # go test -json 把 t.Fatalf / panic 文本都放进各事件的 Output 字段，stderr 几乎是空的。
  # 不还原 Output 的话，CI 日志里就只剩一个退出码，红成什么样都得猜。
  echo "--- go test 输出（从 -json 的 Output 字段还原，末尾 60 行）---"
  awk '
    function unescape(s) {
      gsub(/\\\\/, "\001", s)
      gsub(/\\n/, "\n", s)
      gsub(/\\t/, "\t", s)
      gsub(/\\"/, "\"", s)
      gsub(/\001/, "\\", s)
      return s
    }
    match($0, /"Output":".*"}/) { print unescape(substr($0, RSTART + 10, RLENGTH - 12)) }
  ' "$json" | tail -60 || true
  tail -20 "$raw" || true
  exit "$status"
fi

if [ "$ran" -lt "$MIN_TESTS" ]; then
  echo "只匹配到 $ran 条测试，少于要求的 $MIN_TESTS 条——测试名或 -run 正则可能已失效。" >&2
  exit 1
fi
if [ "$empty_packages" -ne 0 ]; then
  echo "有 $empty_packages 个包报「no tests to run」，本次选择器没有覆盖到它们。" >&2
  exit 1
fi
# 全部跳过不算通过：环境缺失时集成用例应红灯，不是绿。
if [ "$ran" -gt 0 ] && [ "$skipped" -eq "$ran" ]; then
  echo "匹配的 $ran 条测试全部被跳过，未实际执行。" >&2
  exit 1
fi
echo "测试执行断言通过。"
