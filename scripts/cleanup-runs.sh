#!/usr/bin/env bash
#
# 删除旧的 Actions 运行记录，只保留最近 KEEP 条（默认 8）。
#
# 由 .github/workflows/build.yml 在构建前后各调用一次：
#   构建前清一轮，避免记录堆积到上百条
#   构建后再清一轮，把本次运行也算进去，最终稳定在 KEEP 条
#
# 设计原则：**永不失败**。它是构建流程的旁路，清理失败不该连累出固件，
# 所以所有错误都降级成 warning 并 exit 0。
#
# 注意：只删 status == completed 的记录。in_progress / queued 的跳过，
# 删它们会直接把正在跑的构建掐断。
#
set -uo pipefail

keep="${KEEP:-8}"
repo="${REPO:-${GITHUB_REPOSITORY:-}}"

case "$keep" in
  '' | *[!0-9]*) keep=8 ;;
esac

log() { echo "[cleanup] $*"; }

if [ -z "$repo" ]; then
  log "没拿到仓库名（REPO / GITHUB_REPOSITORY 都为空），跳过"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  log "环境里没有 gh CLI，跳过"
  exit 0
fi

ids=()
while IFS= read -r id; do
  [ -n "$id" ] && ids+=("$id")
done < <(
  gh run list --repo "$repo" --limit 500 \
    --json databaseId,status,createdAt \
    --jq 'sort_by(.createdAt) | reverse | .[] | select(.status == "completed") | .databaseId' 2>/dev/null
)

total=${#ids[@]}
if [ "$total" -eq 0 ]; then
  log "没有已完成的运行记录可清理（或取不到列表）"
  exit 0
fi

deleted=0
failed=0
for i in "${!ids[@]}"; do
  if [ "$i" -lt "$keep" ]; then
    continue
  fi
  if gh run delete "${ids[$i]}" --repo "$repo" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  else
    failed=$((failed + 1))
  fi
done

log "已完成记录 $total 条，保留 $keep 条，删除 $deleted 条，失败 $failed 条"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Actions 记录清理"
    echo ""
    echo "| 项 | 值 |"
    echo "| --- | --- |"
    echo "| 保留 | $keep |"
    echo "| 清理前已完成 | $total |"
    echo "| 已删除 | $deleted |"
    echo "| 删除失败 | $failed |"
  } >>"$GITHUB_STEP_SUMMARY"
fi

exit 0
