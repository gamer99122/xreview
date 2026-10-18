#!/bin/bash
# xreview 輔助腳本：prepare / codex / agy / verify
# 只讀取 repo，不修改任何檔案。要換 reviewer 模型，改下面這幾行就好。
set -u

CODEX_MODEL="gpt-5.6-sol"
CODEX_EFFORT="medium"
AGY_MODEL="gemini-3.8-flash-high"
AGY_PRINT_TIMEOUT="600s"     # high 推理模型遇到較大的 diff 會想很久，5 分鐘不夠
REVIEWER_TIMEOUT_SECS=900   # 硬上限；SKILL.md 讓兩個 reviewer 在背景跑，不受 Bash 工具 600 秒限制
MAX_PROMPT_BYTES=300000     # agy 只能從命令列參數收 diff（不讀 stdin），macOS ARG_MAX 約 1MB
AGY_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

die() { echo "ERROR: $*"; exit 2; }

# agy headless 模式的唯讀，前提是設定裡沒有 allow 規則、工具權限維持預設的 request-review
agy_settings_unsafe() {
  [ -f "$AGY_SETTINGS" ] || return 1
  python3 -I - "$AGY_SETTINGS" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    unsafe = bool((d.get("permissions") or {}).get("allow")) or d.get("toolPermission", "request-review") != "request-review"
except Exception:
    unsafe = True  # 讀不懂就當作不安全
sys.exit(0 if unsafe else 1)
EOF
}

# macOS 沒有內建 timeout 指令，用 perl alarm 代替；超時的 exit code 是 142
with_timeout() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec failed: $!\n"' "$secs" "$@"; }

has_head() { git rev-parse --verify -q HEAD >/dev/null; }
untracked() { git ls-files --others --exclude-standard -z; }
gdiff() { git diff --no-color --no-ext-diff "$@"; }

collect_diff() {
  if has_head; then gdiff HEAD; else gdiff --cached; gdiff; fi
  untracked | while IFS= read -r -d '' f; do gdiff --no-index -- /dev/null "$f"; done
}

changed_files() {
  { if has_head; then gdiff HEAD --name-only; else gdiff --cached --name-only; gdiff --name-only; fi
    untracked | tr '\0' '\n'
  } | sort -u
}

# 工作目錄、index、HEAD、untracked 檔案內容的指紋，用來確認 reviewer 沒有動到任何東西
snapshot() {
  { git rev-parse -q --verify HEAD
    git status --porcelain=v1 -uall
    gdiff HEAD --binary
    gdiff --cached --binary
    untracked | while IFS= read -r -d '' f; do shasum "$f"; done
  } 2>/dev/null | shasum | cut -d' ' -f1
}

build_prompt() {
  cat <<'EOF'
You are a code reviewer. Respond with plain text only. Do NOT modify any files, do NOT run any commands, do NOT use any tools — everything you need is in this message.

Review the git diff below for correctness bugs: logic errors, crashes, wrong edge-case handling, security issues, data loss, broken error handling, regressions. Ignore pure style preferences.

Output format:
- The first line must be exactly: REVIEWED FILES: <comma-separated paths of every file in the diff>
- Then one block per finding:
  [high|medium|low] path:line — the problem
  Failure scenario: concrete input/state → wrong result
- If there are no findings, write exactly NO FINDINGS after the first line.

<diff>
EOF
  cat "$1"
  echo '</diff>'
}

cmd_prepare() {
  local root out bytes tmp=${TMPDIR:-/tmp}
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "不在 git repo 裡"
  cd "$root" || die "無法進入 $root"
  out=$(mktemp -d "${tmp%/}/xreview.XXXXXX") || die "無法建立暫存資料夾"
  printf '%s\n' "$root" > "$out/root"
  collect_diff > "$out/diff.patch"
  if [ ! -s "$out/diff.patch" ]; then echo "STATUS: NO_CHANGES"; exit 3; fi
  changed_files > "$out/files.txt"
  build_prompt "$out/diff.patch" > "$out/prompt.txt"
  touch "$out/before.marker"
  snapshot > "$out/before.sha"
  bytes=$(wc -c < "$out/prompt.txt" | tr -d ' ')
  echo "OUT=$out"
  echo "ROOT=$root"
  echo "FILES ($(wc -l < "$out/files.txt" | tr -d ' ')):"
  sed 's/^/  /' "$out/files.txt"
  echo "PROMPT_BYTES=$bytes"
  if [ "$bytes" -gt "$MAX_PROMPT_BYTES" ]; then echo "STATUS: AGY_TOO_LARGE"; else echo "STATUS: READY"; fi
}

cmd_codex() {
  local out=$1 rc
  cd "$(cat "$out/root")" || die "無法進入 repo"
  with_timeout "$REVIEWER_TIMEOUT_SECS" codex review --uncommitted \
    -c "model=\"$CODEX_MODEL\"" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    -c 'sandbox_mode="read-only"' \
    > "$out/codex.txt" 2> "$out/codex.log" < /dev/null
  rc=$?
  echo "OUTPUT=$out/codex.txt"
  if [ $rc -eq 142 ]; then echo "STATUS: FAILED — 超過 ${REVIEWER_TIMEOUT_SECS} 秒被中止"
  elif [ $rc -ne 0 ]; then echo "STATUS: FAILED — exit code $rc"
  elif [ ! -s "$out/codex.txt" ]; then echo "STATUS: FAILED — 沒有輸出"
  elif ! grep -qxF "model: $CODEX_MODEL" "$out/codex.log"; then echo "STATUS: FAILED — 實際使用的模型不是 $CODEX_MODEL"
  else
    grep -qx 'sandbox: read-only' "$out/codex.log" || echo "WARNING: Codex 的沙盒不是 read-only，請特別留意 verify 結果"
    echo "STATUS: OK"; return 0
  fi
  echo "--- codex.log 最後 20 行 ---"; tail -20 "$out/codex.log"
}

cmd_agy() {
  local out=$1 rc f missing=""
  if agy_settings_unsafe; then
    echo "STATUS: FAILED — $AGY_SETTINGS 有 allow 規則或改過 toolPermission，無法保證唯讀，所以沒有執行"
    return 0
  fi
  # diff 已經在提示詞裡，agy 不需要讀 repo；在空資料夾執行，就算它想寫檔也碰不到 repo，也不會載入 repo 裡的 agy 設定
  mkdir -p "$out/agy-cwd" && cd "$out/agy-cwd" || die "無法建立 agy 的工作資料夾"
  with_timeout "$REVIEWER_TIMEOUT_SECS" agy -p "$(cat "$out/prompt.txt")" \
    --model "$AGY_MODEL" --print-timeout "$AGY_PRINT_TIMEOUT" --sandbox \
    > "$out/agy.txt" 2> "$out/agy.log" < /dev/null
  rc=$?
  echo "OUTPUT=$out/agy.txt"
  [ -n "$(ls -A "$out/agy-cwd")" ] && echo "WARNING: agy 在它的工作資料夾裡寫了檔案（$out/agy-cwd），代表它試過寫檔"
  # agy 在權限被拒、整次中止時 exit code 仍是 0，所以要看輸出內容判斷
  if [ $rc -eq 142 ]; then echo "STATUS: FAILED — 超過 ${REVIEWER_TIMEOUT_SECS} 秒被中止"
  elif [ $rc -ne 0 ]; then echo "STATUS: FAILED — exit code $rc"
  elif grep -qs 'print timeout' "$out/agy.txt" "$out/agy.log"; then echo "STATUS: FAILED — 超過 agy 的 --print-timeout（$AGY_PRINT_TIMEOUT）"
  elif grep -qs 'no output produced' "$out/agy.txt" "$out/agy.log"; then echo "STATUS: FAILED — agy 嘗試使用工具被拒絕，整次中止"
  elif [ ! -s "$out/agy.txt" ]; then echo "STATUS: FAILED — 沒有輸出"
  elif ! grep -qi 'REVIEWED FILES:' "$out/agy.txt"; then echo "STATUS: FAILED — 缺少 REVIEWED FILES 行，無法確認它有收到 diff"
  else
    while IFS= read -r f; do grep -qF "$f" "$out/agy.txt" || missing="$missing $f"; done < "$out/files.txt"
    [ -n "$missing" ] && echo "WARNING: agy 的回覆沒有提到這些檔案:$missing"
    echo "STATUS: OK"; return 0
  fi
  echo "--- agy 輸出最後 20 行 ---"; tail -20 "$out/agy.txt" "$out/agy.log"
}

cmd_verify() {
  local out=$1 touched
  cd "$(cat "$out/root")" || die "無法進入 repo"
  # snapshot 看不到被 .gitignore 忽略的檔案，所以再用 mtime 找出 prepare 之後被寫過的所有檔案
  touched=$(find . -path ./.git -prune -o -type f ! -name .DS_Store -newer "$out/before.marker" -print 2>/dev/null | head -50)
  if [ "$(cat "$out/before.sha")" = "$(snapshot)" ] && [ -z "$touched" ]; then echo "STATUS: UNCHANGED"
  else
    echo "STATUS: CHANGED — review 期間有檔案被改動"
    git status --short
    [ -n "$touched" ] && { echo "--- prepare 之後被寫入的檔案 ---"; echo "$touched"; }
    exit 4
  fi
}

case "${1:-}" in
  prepare) cmd_prepare ;;
  codex|agy|verify)
    [ -n "${2:-}" ] && [ -f "$2/root" ] || die "用法：$0 $1 <OUT 資料夾>"
    "cmd_$1" "$2" ;;
  *) echo "用法：$0 prepare | codex <OUT> | agy <OUT> | verify <OUT>"; exit 2 ;;
esac
