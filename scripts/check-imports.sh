#!/usr/bin/env bash
#
# check-imports.sh
#
# packages/Domain と packages/Application の import 許可リストを検査する CI ゲート。
# architecture.md 3.3（Domain の依存制約）/ 4.3（Application の依存制約）が正本。
# SwiftLint の custom_rules（.swiftlint.yml）と同じ制約を、独立した実装（grep/awk）で
# 多層防御として強制する。SwiftLint 側にバグ・設定漏れがあっても、このスクリプトが
# ネットに引っかかることを意図している。
#
# 許可リスト:
#   packages/Domain/Sources      : Foundation のみ
#   packages/Application/Sources : Foundation, Domain のみ
#
# 検出対象の import 文（属性・アクセスレベル修飾の組み合わせを含む）:
#   import X
#   @testable import X
#   @_implementationOnly import X
#   public import X / internal import X / package import X
#   private import X / fileprivate import X
#   （上記修飾の任意の組み合わせ・順序）
#
# 使い方:
#   bash scripts/check-imports.sh
#   （リポジトリルートから実行する。CI からは .github/workflows/ci.yml の
#   import-scan ジョブが同じコマンドを呼び出す）
#
# 終了コード:
#   0 = 違反なし
#   1 = 許可リスト外の import を検出、またはスキャン対象ディレクトリが存在しない
#       （後者は package 構成が変わってこのスクリプトが更新されずに「何もチェックせず
#       成功する」事故を防ぐため、fail-closed にしている）
#
# 既知の制約（spec 2026-08-01-project-foundation-fixes.md の範囲外）:
#   `import struct Foundation.Date` のようなサブモジュール指定 import（kind-qualified
#   import）は本スクリプトの対象外。現状のコードベースには存在せず、仕様書にも
#   要求されていない。万一登場した場合、モジュール名の抽出結果が "struct" 等になり
#   許可リストに一致しないため fail-closed（安全側）に倒れる＝見逃しではなく誤検知側に倒れる。

set -euo pipefail

# import 行検出用の正規表現（grep -E）。
# 修飾キーワードを0回以上・任意の順序で許容し、最終的に "import <Identifier>" にマッチする。
IMPORT_REGEX='^[[:space:]]*(@testable[[:space:]]+|@_implementationOnly[[:space:]]+|public[[:space:]]+|internal[[:space:]]+|package[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+)*import[[:space:]]+[A-Za-z_][A-Za-z0-9_]*'

overall_fail=0

# scan_scope <dir> <comma-separated allowed modules>
# 指定ディレクトリ配下の *.swift を走査し、許可リスト外の import があれば
# "file:line: forbidden import <module> (<line>)" を標準エラーに出力する。
scan_scope() {
  local dir="$1"
  local allowed_csv="$2"

  if [[ ! -d "$dir" ]]; then
    echo "check-imports: エラー: スキャン対象ディレクトリが存在しません: $dir" >&2
    echo "  packages/ の構成が変わった場合、このスクリプト（scripts/check-imports.sh）の対象ディレクトリ指定を見直してください。" >&2
    overall_fail=1
    return
  fi

  local swift_files
  swift_files=$(find "$dir" -type f -name '*.swift')
  if [[ -z "$swift_files" ]]; then
    # ディレクトリはあるが *.swift が1件もない。構成崩れの可能性があるため fail-closed にする。
    echo "check-imports: エラー: $dir 配下に *.swift が見つかりません。" >&2
    overall_fail=1
    return
  fi

  local matches
  # -H: マッチしたファイルが1件だけの場合でも "file:line:content" 形式を強制する
  #     （-H なしだと単一ファイルの場合に grep がファイル名を省略し、後段の
  #     file:line:content パースが壊れて誤ったファイル名・行番号を報告する）。
  # grep が「マッチなし」で exit 1 を返すのは正常系（違反なし）なので、
  # ここでは `|| true` で吸収し、後段の while ループが空入力を正しく処理する。
  matches=$(printf '%s\n' "$swift_files" | xargs grep -nHE "$IMPORT_REGEX" -- 2>/dev/null || true)

  if [[ -z "$matches" ]]; then
    return
  fi

  while IFS= read -r matched_line; do
    [[ -z "$matched_line" ]] && continue

    local file lineno content
    file="${matched_line%%:*}"
    local rest="${matched_line#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"

    local module
    module=$(printf '%s\n' "$content" | awk -v allowed="$allowed_csv" '
      BEGIN {
        n = split(allowed, arr, ",")
        for (i = 1; i <= n; i++) allow[arr[i]] = 1
      }
      {
        line = $0
        gsub(/^[ \t]+/, "", line)
        # 先頭の修飾語（属性・アクセスレベル）を任意の組み合わせ・任意回数分だけ取り除く
        while (line ~ /^(@testable|@_implementationOnly|public|internal|package|private|fileprivate)[ \t]+/) {
          sub(/^(@testable|@_implementationOnly|public|internal|package|private|fileprivate)[ \t]+/, "", line)
        }
        sub(/^import[ \t]+/, "", line)
        split(line, toks, /[ \t.;]/)
        mod = toks[1]
        gsub(/[^A-Za-z0-9_].*$/, "", mod)
        print mod
        exit
      }
    ')

    if [[ ",${allowed_csv}," != *",${module},"* ]]; then
      echo "check-imports: 違反: ${file}:${lineno}: 許可されていない import '${module}' (許可リスト: ${allowed_csv}) -- ${content}" >&2
      overall_fail=1
    fi
  done <<< "$matches"
}

scan_scope "packages/Domain/Sources" "Foundation"
scan_scope "packages/Application/Sources" "Foundation,Domain"

if [[ "$overall_fail" -ne 0 ]]; then
  echo "check-imports: FAIL — 許可リスト外の import を検出しました。architecture.md 3.3 / 4.3 を参照してください。" >&2
  exit 1
fi

echo "check-imports: OK — Domain / Application の import はすべて許可リスト内です。"
exit 0
