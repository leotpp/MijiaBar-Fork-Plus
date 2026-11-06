#!/bin/bash
set -euo pipefail

mode="${1:---check}"
if [[ $# -gt 1 || ( "$mode" != --check && "$mode" != --merge ) ]]; then
  echo '用法：scripts/sync-upstream.sh [--check|--merge]' >&2
  exit 2
fi
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
if ! git fetch origin refs/heads/main:refs/remotes/origin/main; then
  echo '错误：无法拉取上游 origin/main，请检查网络及现有 origin 地址。' >&2
  exit 1
fi
read -r local_ahead upstream_ahead <<< "$(git rev-list --left-right --count HEAD...origin/main)"
echo "上游领先 $upstream_ahead 个 / 本地领先 $local_ahead 个"
if [[ "$upstream_ahead" -eq 0 ]]; then
  echo '没有新的上游提交。'
else
  git log --oneline HEAD..origin/main
fi
[[ "$mode" == --merge ]] || exit 0
if [[ -n "$(git status --porcelain)" || -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
  echo '错误：请先处理工作树改动或尚未完成的合并，再执行 --merge。' >&2
  exit 1
fi
if ! git merge --no-ff --no-edit origin/main; then
  echo '合并未完成；如有冲突，请用 git status 查看并手动解决后提交，或执行 git merge --abort。脚本不会自动解决冲突或提交冲突结果。' >&2
  exit 1
fi
