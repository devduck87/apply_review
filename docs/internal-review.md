# 内部レビュー用パッチ運用スクリプト

`01_after/` に置かれた「内部レビュー済みのファイル群」を、ターゲットの git リポジトリ (`git-practice-sample/`) に取り込むための一連のシェルスクリプトについて解説する。

## 全体像

```
01_after/   ─┐
             │  ① generate (パッチ作成)
             ▼
patches/*.patch
             │  ② apply   (パッチ適用)
             ▼
git-practice-sample/  ← BASE_COMMIT 起点に 3-way マージで取り込み
```

`01_after/` は **BASE_COMMIT からの差分があるファイルだけ** を置く前提。BASE_COMMIT の作業ツリーに上書きすることで「内部レビュー済みスナップショット」を作り、そこから format-patch でパッチを生成する。

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| [internal-review.env](../internal-review.env) | `SOURCE_DIR` / `TARGET_REPO` / `BASE_COMMIT` / `PATCH_DIR` / `COMMIT_MSG` の共通設定。両スクリプトから `source` される |
| [generate-internal-review-patch.sh](../generate-internal-review-patch.sh) | `01_after/` の内容からパッチを作って `patches/` に保存する (生成のみ) |
| [apply-internal-review-patch.sh](../apply-internal-review-patch.sh) | `patches/` のパッチを `git-practice-sample/` に 3-way マージで適用してコミットする (適用のみ) |
| [apply-internal-review.sh](../apply-internal-review.sh) | 上記2つを1本にまとめた旧スクリプト。生成と適用を一括で行う |

### 共通設定 (`internal-review.env`)

| 変数 | 値 (デフォルト) | 意味 |
| --- | --- | --- |
| `SOURCE_DIR` | `${SCRIPT_DIR}/01_after` | レビュー済みファイルを置くディレクトリ |
| `TARGET_REPO` | `${SCRIPT_DIR}/git-practice-sample` | パッチを適用する git リポジトリ |
| `BASE_COMMIT` | `6bca53c1...` | 起点となるコミット。`01_after/` はこのコミットからの差分 |
| `PATCH_DIR` | `${SCRIPT_DIR}/patches` | 生成パッチの保存先 |
| `COMMIT_MSG` | `internal review: snapshot from 01_after` | スナップショット/取り込み時のコミットメッセージ |

`SCRIPT_DIR` は呼び出し側スクリプトで先に設定される必要がある (`source` 前に定義済み)。

## 使い方

### 1. パッチを生成する

```bash
./generate-internal-review-patch.sh
```

実行すると `patches/0001-internal-review-snapshot-from-01_after.patch` のようなパッチファイルが作られる。`TARGET_REPO` の HEAD は元のブランチに戻り、作業ツリーは元の状態のまま。

### 2. パッチを適用する

```bash
# patches/ で最新のパッチを適用
./apply-internal-review-patch.sh

# パッチを明示指定
./apply-internal-review-patch.sh patches/0001-internal-review-snapshot-from-01_after.patch
```

成功すると `TARGET_REPO` の現在のブランチに新しいコミットが1つ積まれる。コミットの author は適用環境の `git config user.name` / `user.email` になる (パッチ内の author 情報は引き継がない)。

### 一括実行 (旧スクリプト)

```bash
./apply-internal-review.sh
```

生成 → 適用までを1本でこなす。手っ取り早く流したい場合に使う。役割分離されていないため、生成だけ・適用だけ走らせたいときは新しい2本を使う。

## 内部処理の流れ

### `generate-internal-review-patch.sh`

1. `internal-review.env` を読み込む
2. 事前チェック
   - `SOURCE_DIR` / `TARGET_REPO/.git` の存在
   - `TARGET_REPO` に未コミットの変更がないこと
   - `BASE_COMMIT` が `TARGET_REPO` に存在すること
3. `BASE_COMMIT` から temp ブランチ `internal-review/YYYYMMDD-HHMMSS` を切る
4. `01_after/` の中身を `cp -a` で作業ツリーに上書き → `git add -A` → `git commit`
   - 差分がなければ no-op で温存して終了
5. `git format-patch <BASE_COMMIT>` でパッチを生成し `patches/` に保存
6. 元のブランチに戻り、temp ブランチを削除
7. パッチパスを表示して完了

途中で失敗した場合は `trap on_error ERR` により元のブランチへ戻し、temp ブランチも削除する。

### `apply-internal-review-patch.sh`

1. `internal-review.env` を読み込む
2. パッチファイルを解決
   - 引数があればそれを使用
   - 引数なしなら `patches/*.patch` の中で **更新時刻が最も新しいもの** を選ぶ (`ls -1t | head -n1`)
3. パッチパスを絶対パスへ正規化 (`cd $TARGET_REPO` 後でも参照できるように)
4. 事前チェック
   - パッチファイルの存在
   - `TARGET_REPO/.git` の存在
   - `TARGET_REPO` に未コミットの変更がないこと
5. `git apply --3way <patch>` で作業ツリーに適用
6. 成功したら `git add -A && git commit -m "$COMMIT_MSG"`
7. 失敗 (コンフリクト) したら手動解決の手順を案内して `exit 1`。**パッチファイルは消さずに残す** ので再適用や調査に使える

### `apply-internal-review.sh` (旧)

`generate-internal-review-patch.sh` のステップ 1〜6 を行ったあと、続けて `apply-internal-review-patch.sh` のステップ 5〜7 を実行する一体型。共通設定は `internal-review.env` ではなくスクリプト内に直接書かれている。

## なぜ `git apply --3way` なのか

過去には `git am` を使っていたが、適用時のコミット author をパッチ内のものではなく **適用者の git config** に揃えたかったため `git apply --3way` + 手動 commit に切り替えた (コミット履歴 [3221db1](#) 参照)。

3-way マージにすることで、`TARGET_REPO` 側が `BASE_COMMIT` から進んでいてもコンテキストが一致する範囲は自動でマージされる。ぶつかった箇所だけコンフリクトマーカーが出る。

## コンフリクトしたら

`apply-internal-review-patch.sh` がコンフリクトで止まった場合、`TARGET_REPO` (= `git-practice-sample/`) で次を行う:

```bash
cd git-practice-sample
# <<<<<<< / ======= / >>>>>>> マーカーを手で解決
git add <解決したファイル>
git commit -m "internal review: snapshot from 01_after"
```

パッチファイル (`patches/xxx.patch`) はそのまま残っているので、解決をやり直したいときは `git reset --hard` で戻してから再適用できる。

## 想定外の状態と対処

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `error: ... has uncommitted changes` | `TARGET_REPO` に未コミット変更がある | 先に commit / stash する |
| `error: base commit ... not found` | `BASE_COMMIT` が `TARGET_REPO` に存在しない | `internal-review.env` の `BASE_COMMIT` を実在するコミットに修正 |
| `no diff between ... and 01_after. nothing to do.` | `01_after/` が `BASE_COMMIT` と同一 | レビュー済み内容を `01_after/` に反映してから再実行 |
| `error: no patches found in patches/` | `patches/` が空 | 先に `generate-internal-review-patch.sh` を流す |
