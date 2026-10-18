# 跨模型 Code Review（/xreview）規劃與進度

最後更新：2026-10-19

## 目標
- Claude Code 負責寫程式；Codex 和 agy **只做 review、不修改程式**
- 不用在多個終端機之間切換、手動搬運 review 結果

## 檔案位置
| 檔案 | 用途 |
|---|---|
| `SKILL.md` | 給 Claude 看的流程說明（`disable-model-invocation: true`，只能手動 `/xreview`） |
| `xreview.sh` | 輔助腳本：`prepare` / `codex` / `agy` / `verify` |
| `cross-review-plan.md` | 本文件 |

- 原始檔在 `/Users/lin/Desktop/SHINARISUKI/xreview/`（獨立的 git repo）
- `~/.claude/skills/xreview` 是指向這裡的 symlink；已實測 Claude Code 2.1.302 讀得到透過 symlink 放置的 skill
- 注意：家目錄 `/Users/lin` 本身也是一個 git repo（所有檔案都未追蹤），所以 `xreview/` 要用自己的 repo

## 流程（已實作）
1. `prepare`：收集未提交的變更（staged + unstaged + untracked），產生給 agy 的提示詞，記錄 repo 指紋
2. Codex 和 agy **在背景平行**執行（不受 Bash 工具前景 10 分鐘上限限制）
3. `verify`：確認 review 期間沒有任何檔案被改動（包含 .gitignore 忽略的檔案）
4. Claude 對照實際程式碼逐條判斷「同意／不同意＋理由」，列給使用者
5. 使用者同意的才修改；**最多兩輪**

## 模型設定（寫死在 `xreview.sh` 開頭）
| reviewer | 模型 | 推理強度 |
|---|---|---|
| agy | `gemini-3.8-flash-high` | 已包含在模型名稱裡 |
| Codex | `gpt-5.6-sol` | `medium`（預設是 low，要明確指定） |

- agy 也提供 Claude 模型，**絕對不要拿來當 reviewer**
- Codex 清單裡還有比較新的 `gpt-6-sol`、`gpt-6.1-sol`，之後可以考慮換

## 唯讀保護
| reviewer | 怎麼保護 |
|---|---|
| Codex | `codex review` 預設 `sandbox: read-only`、`approval: never`；腳本另外用 `-c sandbox_mode="read-only"` 寫死，並從 log 確認模型和沙盒 |
| agy | ① 在**空的暫存資料夾**執行（diff 放在提示詞裡，不需要讀 repo）② 加 `--sandbox` ③ 執行前檢查 `~/.gemini/antigravity-cli/settings.json`：有 `permissions.allow` 或 `toolPermission` 不是 `request-review` 就拒絕執行 |
| 兩者 | `verify` 比對 repo 指紋，並找出 prepare 之後被寫入的所有檔案 |

agy 的 ①③ 是採納 Codex 在自我 review 時提出的 P1：原本的唯讀只靠「設定剛好沒有 allow 規則」。

## 實測結果

### Codex 0.162.1
- `codex review --uncommitted -c model=... -c model_reasoning_effort=...` 可正常使用
- review 結果在 stdout，執行過程在 stderr
- 時間：小 diff 37 秒；12KB diff 101 秒

### agy 1.4.0（2026-10-18 自動從 1.3.5 更新，已重測）
| 測試 | 結果 |
|---|---|
| 預設模式，要求改檔 | 寫檔被自動拒絕，檔案沒變；**但 exit code 是 0** |
| 預設模式，diff 放在提示詞 | 正常 review |
| diff 從 stdin 傳入（`-p -` 或 pipe） | **不讀 stdin**；pipe 的那次沒看到 diff 卻回「NO FINDINGS」，看起來像通過 |
| `--sandbox` + 空資料夾 | 正常 review，資料夾沒有多出檔案 |
| 12KB diff，`--print-timeout 300s` | 超時：不是卡住，是 high 推理模型想太久；輸出是空的 |
| 12KB diff，`--print-timeout 600s` | 391 秒完成 |

由此得出的設計：
- diff 一律放在命令列參數（上限 300KB，macOS ARG_MAX 約 1MB）
- 要求 agy 第一行輸出 `REVIEWED FILES:`，沒有這行就判定失敗（防止「沒收到 diff 卻說沒問題」）
- 不能只看 exit code，要檢查輸出內容
- 不要用 `--mode plan`（1.3.5 時會卡住）

## 失敗／額度用完的處理原則
- **執行失敗不等於 review 通過**
- 其中一個失敗：報告開頭標註「⚠️ 未執行：原因」
- 兩個都失敗：停下來通知使用者，不進入修改步驟；可以改用 `/code-review` 先頂著（需標註是同一模型自己檢查）
- 不自動重試，也不自動改用付費 API key
- 用「執行失敗、超時、沒有輸出、格式不對」判斷失敗，不比對特定錯誤文字（還沒看過額度用完時的錯誤訊息）

## 已知限制
- 只支援「未提交的變更」，還不能 review 某個 branch 或 commit 範圍
- agy 很慢：12KB diff 要 6 分多鐘，是整個流程最慢的一段
- agy 只看得到 diff，看不到 diff 以外的程式碼脈絡
- 無法從 agy 的 log 確認實際使用的模型，只能相信 `--model` 參數

## 待辦
- [ ] 在真實專案上實際使用幾次，調整報告格式
- [ ] （可能）支援 `--base <branch>`，review 已 commit 的變更
- [ ] （之後）設定 GitHub PR 的 review bot：Codex 雲端 review + Gemini Code Assist
- [ ] （之後）評估換成 `gpt-6-sol` / `gpt-6.1-sol`
