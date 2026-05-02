#!/usr/bin/env bash
set -euo pipefail

# 01_after/ の内部レビュー済み内容を test/ リポジトリに取り込む。
# 01_after/ には変更のあったファイルのみを置く想定 (BASE_COMMIT 以降の差分のみ)。
#
# 流れ:
#   1) BASE_COMMIT から temp ブランチを切る
#   2) BASE_COMMIT の作業ツリーに 01_after の変更ファイルを上書きし、内部レビュー済みスナップショットとしてコミット
#   3) format-patch でパッチを生成 (patches/ に保存。後日の再適用や保管用)
#   4) 元のブランチに戻り、temp ブランチを削除
#   5) git apply --3way でパッチを作業ツリーに適用し、現在の git config のユーザーでコミット
#      (パッチに含まれる author 情報は引き継がない)
#
# 衝突時は test/ でコンフリクトマーカーを手で解決し、git add → git commit する。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/01_after"
TARGET_REPO="${SCRIPT_DIR}/git-practice-sample"
BASE_COMMIT="6bca53c13ebca13f2aa730291c5a84887cf6f3d6"
PATCH_DIR="${SCRIPT_DIR}/patches"
TEMP_BRANCH="internal-review/$(date +%Y%m%d-%H%M%S)"
COMMIT_MSG="internal review: snapshot from 01_after"

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

# 途中失敗時のロールバック (temp ブランチ作成後〜パッチ生成前まで有効)
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
echo "patch: $PATCH_FILE"

# --- 4) 元のブランチに戻り、temp ブランチを削除 ---
git checkout --quiet "$ORIGINAL_BRANCH"
git branch -D "$TEMP_BRANCH" >/dev/null
trap - ERR  # 以降は git am の失敗をエラー扱いにしない

# --- 5) 3-way マージで適用 ---
echo "==> apply patch with git apply --3way"
if git apply --3way "$PATCH_FILE"; then
  git add -A
  git commit --quiet -m "$COMMIT_MSG"
  echo ""
  echo "done."
  echo "  patch:  $PATCH_FILE"
  echo "  commit: $(git rev-parse --short HEAD) on $ORIGINAL_BRANCH"
else
  cat >&2 <<EOF

conflict during git apply. resolve manually in $TARGET_REPO:
  # edit conflicted files (look for <<<<<<< markers)
  git add <files>
  git commit -m "$COMMIT_MSG"

patch file is preserved at: $PATCH_FILE
EOF
  exit 1
fi
