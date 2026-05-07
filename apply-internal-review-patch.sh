#!/usr/bin/env bash
set -euo pipefail

# generate-internal-review-patch.sh で作成したパッチを test/ リポジトリへ適用する。
# 引数省略時は patches/ 配下で最も新しいパッチを使う。
# 衝突時は test/ で手動解決し、git add → git commit する (パッチファイルは保持される)。
#
# usage:
#   apply-internal-review-patch.sh                      # patches/ の最新を適用
#   apply-internal-review-patch.sh path/to/xxx.patch    # 指定したパッチを適用

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal-review.env
source "${SCRIPT_DIR}/internal-review.env"

# --- パッチファイルの解決 ---
if [[ $# -ge 1 ]]; then
  PATCH_FILE="$1"
else
  [[ -d "$PATCH_DIR" ]] || { echo "error: patch dir not found: $PATCH_DIR" >&2; exit 1; }
  PATCH_FILE="$(ls -1t "$PATCH_DIR"/*.patch 2>/dev/null | head -n1 || true)"
  [[ -n "$PATCH_FILE" ]] || { echo "error: no patches found in $PATCH_DIR" >&2; exit 1; }
  echo "using latest patch: $PATCH_FILE"
fi

[[ -f "$PATCH_FILE" ]]       || { echo "error: patch not found: $PATCH_FILE" >&2; exit 1; }
[[ -d "$TARGET_REPO/.git" ]] || { echo "error: not a git repo: $TARGET_REPO" >&2; exit 1; }

# cd 後でも参照できるように絶対パスへ正規化
PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"

cd "$TARGET_REPO"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: $TARGET_REPO has uncommitted changes. commit or stash first." >&2
  exit 1
fi

ORIGINAL_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)"

# --- 3-way マージで適用 ---
echo "==> apply patch with git apply --3way"
echo "  patch: $PATCH_FILE"
if git apply --3way "$PATCH_FILE"; then
  git add -A
  git commit --quiet -m "$COMMIT_MSG"
  echo ""
  echo "done."
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
