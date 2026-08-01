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
#   @preconcurrency import X
#   @_exported import X
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
# 対応範囲:
#   修飾（@testable / @_implementationOnly / @preconcurrency / @_exported / アクセスレベル）と
#   種別つき import（`import struct Foundation.Date` 等）はモジュール名を正しく抽出する。
#   行内ブロックコメントの挿入（`import/*x*/UIKit` 等。コメントはトークン区切りとして
#   機能するため正規表現を迂回できる）は、検査前にコメントを空白へ正規化して検出する。
#   複数行に跨るコメントで import 文を分割する等、通常のコーディングで現れない構文への
#   完全対応は目的にしない（意図的な難読化はレビューで検出する）。

set -euo pipefail

# import 行検出用の正規表現（grep -E）。
# 修飾キーワードを0回以上・任意の順序で許容し、最終的に "import <Identifier>" にマッチする。
IMPORT_REGEX='^[[:space:]]*(@testable[[:space:]]+|@_implementationOnly[[:space:]]+|@preconcurrency[[:space:]]+|@_exported[[:space:]]+|public[[:space:]]+|internal[[:space:]]+|package[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+)*import[[:space:]]+[A-Za-z_][A-Za-z0-9_]*'

# モジュール名を伴わない import で行が終わるケース（複数行分割）の検出用。
DANGLING_IMPORT_REGEX='^[[:space:]]*(@testable[[:space:]]+|@_implementationOnly[[:space:]]+|@preconcurrency[[:space:]]+|@_exported[[:space:]]+|public[[:space:]]+|internal[[:space:]]+|package[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+)*import[[:space:]]*$'

# strip_comments <file>
# Swift のコメントを空白へ正規化して出力する（行構造は保持）。
#   - ブロックコメント /* */ は Swift 仕様どおり**ネストを数えて**除去する
#   - 行コメント // 以降は行末まで除去する
#   - 文字列リテラル "..."（同一行）内は保護し、内部の /* や // を無視する
#   - EOF 時にコメント深度が残っている場合（未終端。複数行文字列内の /* 等でも起こる）は
#     見逃しに倒さず fail-closed で違反として報告する
strip_comments() {
  awk '
    BEGIN { depth = 0 }
    {
      line = $0; out = ""; i = 1; n = length(line); instr = 0
      while (i <= n) {
        two = substr(line, i, 2); one = substr(line, i, 1)
        if (depth == 0 && instr == 0 && one == "\"") { instr = 1; out = out one; i++; continue }
        if (instr == 1) {
          if (one == "\\") { out = out substr(line, i, 2); i += 2; continue }
          if (one == "\"") { instr = 0 }
          out = out one; i++; continue
        }
        if (depth == 0 && two == "//") { break }
        if (two == "/*") { depth++; out = out "  "; i += 2; continue }
        if (depth > 0 && two == "*/") { depth--; out = out "  "; i += 2; continue }
        if (depth > 0) { out = out " "; i++ } else { out = out one; i++ }
      }
      print out
    }
    END { if (depth > 0) { print "UNTERMINATED_COMMENT" > "/dev/stderr"; exit 3 } }
  ' "$1" 2>"${TMPDIR:-/tmp}/check_imports_stderr.$$" || {
    if grep -q UNTERMINATED_COMMENT "${TMPDIR:-/tmp}/check_imports_stderr.$$" 2>/dev/null; then
      echo "__CHECK_IMPORTS_UNTERMINATED__"
    fi
  }
  rm -f "${TMPDIR:-/tmp}/check_imports_stderr.$$"
}

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

  local matches=""
  # ブロックコメントを空白へ正規化してから import 行を検査する。
  # コメント挿入（`import/*x*/UIKit`）・ネストコメント（`/*/**/*/import UIKit`。Swift は
  # ネスト可）・複数行コメントによる迂回を防ぐため、行単位の sed ではなく
  # 深度カウンタつきの awk 正規化器（strip_comments）を通す。
  # 正規化後に "NN:content" 形式で出力し、ファイル名を前置して "file:line:content" を保つ。
  # grep が「マッチなし」で exit 1 を返すのは正常系（違反なし）なので `|| true` で吸収する。
  local f m norm dangling
  while IFS= read -r f; do
    norm=$(strip_comments "$f")

    # 未終端コメント（複数行文字列内のコメント記号でも起こる）は見逃しに倒さず
    # fail-closed で違反として報告する。
    if [[ "$norm" == *"__CHECK_IMPORTS_UNTERMINATED__"* ]]; then
      echo "check-imports: 違反: ${f}: 閉じられていないブロックコメントを検出しました（複数行文字列内に /* を含む場合も該当）。fail-closed で違反扱いとします" >&2
      overall_fail=1
      continue
    fi

    m=$(printf '%s\n' "$norm" | grep -nE "$IMPORT_REGEX" | sed "s@^@${f}:@" || true)
    if [[ -n "$m" ]]; then
      matches+="${m}"$'\n'
    fi

    # 正規化後、モジュール名を伴わず行末が import で終わる行は、複数行コメント等で
    # import 文が分割されている可能性がある。見逃しに倒さず fail-closed で報告する。
    dangling=$(printf '%s\n' "$norm" | grep -nE "$DANGLING_IMPORT_REGEX" | sed "s@^@${f}:@" || true)
    if [[ -n "$dangling" ]]; then
      echo "check-imports: 違反: ${dangling%%$'\n'*}: モジュール名を伴わない import 行を検出（コメント等による分割の可能性。1 行の import へ書き直してください）" >&2
      overall_fail=1
    fi
  done <<< "$swift_files"

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
    module=$(printf '%s\n' "$content" | awk '
      {
        line = $0
        gsub(/^[ \t]+/, "", line)
        # 先頭の修飾語（属性・アクセスレベル）を任意の組み合わせ・任意回数分だけ取り除く
        while (line ~ /^(@testable|@_implementationOnly|@preconcurrency|@_exported|public|internal|package|private|fileprivate)[ \t]+/) {
          sub(/^(@testable|@_implementationOnly|@preconcurrency|@_exported|public|internal|package|private|fileprivate)[ \t]+/, "", line)
        }
        sub(/^import[ \t]+/, "", line)
        # 種別つき import（import struct Foundation.Date 等）は種別キーワードを読み飛ばす
        sub(/^(struct|class|enum|protocol|typealias|actor|func|var|let)[ \t]+/, "", line)
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

# 引数 2 つ（<dir> <allowlist>）が与えられた場合は、そのスコープだけを検査する
# （scripts/check-imports-test.sh の回帰テストが使う）。引数なしが通常運用。
if [[ $# -eq 2 ]]; then
  scan_scope "$1" "$2"
else
  scan_scope "packages/Domain/Sources" "Foundation"
  scan_scope "packages/Application/Sources" "Foundation,Domain"
fi

if [[ "$overall_fail" -ne 0 ]]; then
  echo "check-imports: FAIL — 許可リスト外の import を検出しました。architecture.md 3.3 / 4.3 を参照してください。" >&2
  exit 1
fi

echo "check-imports: OK — 検査対象の import はすべて許可リスト内です。"
exit 0
