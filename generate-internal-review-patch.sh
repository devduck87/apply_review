#!/usr/bin/env bash
set -euo pipefail

# 01_after/ の内部レビュー済み内容から、BASE_COMMIT 起点のパッチを生成する。
# 適用は apply-internal-review-patch.sh で別途行う。
#
# 流れ:
#   1) BASE_COMMIT から temp ブランチを切る
#   2) 01_after の変更ファイルを上書きしてスナップショットコミット
#   3) format-patch でパッチを生成 (patches/ に保存)
#   4) 元のブランチに戻り、temp ブランチを削除

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal-review.env
source "${SCRIPT_DIR}/internal-review.env"

TEMP_BRANCH="internal-review/$(date +%Y%m%d-%H%M%S)"

# --- 事前チェック ---
[[ -d "$SOURCE_DIR" ]]       || { echo "error: source not found: $SOURCE_DIR" >&2; exit 1; }
[[ -d "$TARGET_REPO/.git" ]] || { echo "error: not a git repo: $TARGET_REPO" >&2; exit 1; }

cd "$TARGET_REPO"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: $TARGET_REPO has uncommitted changes. commit or stash first." >&2
  exit 1
fi

git cat-file -e "${BASE_COMMIT}^{commit}" 2>/dev/null \
  || { echo "error: base commit $BASE_COMMIT not found in $TARGET_REPO" >&2; exit 1; }

ORIGINAL_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)"
echo "original HEAD: $ORIGINAL_BRANCH"

on_error() {
  local rc=$?
  echo "error during patch creation, rolling back..." >&2
  git checkout -f "$ORIGINAL_BRANCH" 2>/dev/null || true
  git branch -D "$TEMP_BRANCH" 2>/dev/null || true
  exit "$rc"
}

# --- 1) temp ブランチ作成 ---
echo "==> create temp branch $TEMP_BRANCH from ${BASE_COMMIT:0:7}"
git checkout --quiet -b "$TEMP_BRANCH" "$BASE_COMMIT"
trap on_error ERR

# --- 2) 01_after の変更ファイルを作業ツリーに上書きしてコミット ---
echo "==> overlay changed files from $SOURCE_DIR onto working tree"
cp -a "$SOURCE_DIR"/. ./
git add -A

if git diff --cached --quiet; then
  echo "no diff between ${BASE_COMMIT:0:7} and 01_after. nothing to do."
  trap - ERR
  git checkout --quiet "$ORIGINAL_BRANCH"
  git branch -D "$TEMP_BRANCH" >/dev/null
  exit 0
fi

git commit --quiet -m "$COMMIT_MSG"

# --- 3) パッチ生成 ---
mkdir -p "$PATCH_DIR"
echo "==> generate patch into $PATCH_DIR"
PATCH_FILE="$(git format-patch "$BASE_COMMIT" -o "$PATCH_DIR" | tail -n1)"

# --- 4) 元のブランチに戻り、temp ブランチを削除 ---
git checkout --quiet "$ORIGINAL_BRANCH"
git branch -D "$TEMP_BRANCH" >/dev/null
trap - ERR

echo ""
echo "done."
echo "  patch: $PATCH_FILE"
echo ""
echo "to apply, run one of:"
echo "  $(dirname "$0")/apply-internal-review-patch.sh"
echo "  $(dirname "$0")/apply-internal-review-patch.sh \"$PATCH_FILE\""
