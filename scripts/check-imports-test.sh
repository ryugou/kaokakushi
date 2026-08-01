#!/usr/bin/env bash
#
# check-imports-test.sh
#
# scripts/check-imports.sh の回帰テスト。肯定・否定ケースを一時ディレクトリ上に
# 生成し、期待どおりの exit code になることを検証する。CI の import-scan ジョブが
# 本スキャンの前に実行する。字句処理（コメント正規化・ネスト・文字列保護）は
# 境界ケースが多いため、ここで固定する。
#
# 使い方: bash scripts/check-imports-test.sh（リポジトリルートから）

set -euo pipefail

script="scripts/check-imports.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-imports-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail=0
case_no=0

# run_case <期待exit(0|1)> <説明> <ファイル内容...>
run_case() {
  local expect="$1" desc="$2"; shift 2
  case_no=$((case_no + 1))
  local dir="$tmp/case$case_no/Sources"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/Case.swift"
  local actual=0
  bash "$script" "$dir" "Foundation" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expect" ]]; then
    echo "ok   case$case_no: $desc"
  else
    echo "FAIL case$case_no: $desc (expect=$expect actual=$actual)"
    fail=1
  fi
}

# --- 肯定ケース（違反なし = exit 0） ---
run_case 0 "基本の許可 import" 'import Foundation'
run_case 0 "種別つき import（Foundation）" 'import struct Foundation.Date'
run_case 0 "修飾つき許可 import" '@_exported import Foundation'
run_case 0 "コメント挿入だが許可モジュール" 'import/*gap*/Foundation'
run_case 0 "行コメント内の import は無視" '// import UIKit' 'import Foundation'
run_case 0 "複数行コメントで無効化された import" '/*' 'import UIKit' '*/' 'import Foundation'
run_case 0 "文字列リテラル内のコメント記号" 'let s = "/* not a comment */"' 'import Foundation'

# --- 否定ケース（違反あり = exit 1） ---
run_case 1 "禁止 import" 'import UIKit'
run_case 1 "修飾つき禁止 import" '@preconcurrency import UIKit'
run_case 1 "種別つき禁止 import" 'import struct UIKit.CGRect'
run_case 1 "コメント挿入による迂回" 'import/*gap*/UIKit'
run_case 1 "ネストコメントの残渣による迂回" '/*/**/*/import UIKit'
run_case 1 "複数行コメントで分割された import（fail-closed）" 'import/*' '*/UIKit'
run_case 1 "未終端コメント（fail-closed）" '/* unterminated' 'import UIKit'
run_case 1 "空ディレクトリ相当（*.swift なし）は別ケースのため、ここでは禁止 import 混在" 'import Foundation' 'import UIKit'

if [[ "$fail" -ne 0 ]]; then
  echo "check-imports-test: FAIL — 期待と異なるケースがあります。" >&2
  exit 1
fi
echo "check-imports-test: OK — 全 ${case_no} ケースが期待どおりです。"
exit 0
