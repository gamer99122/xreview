---
name: xreview
description: 跨模型 code review：把目前未提交的變更交給 Codex（gpt-5.6-sol）和／或 agy（gemini-3.8-flash-high）唯讀審查，由 Claude 合併、逐條判斷，使用者確認後才修改。只能手動用 /xreview 觸發；可用參數 codex 或 agy 只跑其中一個。
disable-model-invocation: true
argument-hint: "[codex|agy]"
---

# /xreview — 跨模型 code review

Codex 和 agy **只負責 review，不能修改任何檔案**。修改一律由 Claude 進行，而且要先經過使用者同意。

輔助腳本：`~/.claude/skills/xreview/xreview.sh`。模型設定寫死在腳本開頭，不依賴 CLI 的預設值。

## 選擇 reviewer

使用者給的參數：`$ARGUMENTS`

| 參數 | 使用的 reviewer |
|---|---|
| （空白） | Codex 和 agy 都用 |
| `codex` | 只用 Codex |
| `agy` | 只用 agy（`gemini`、`ayg` 這類明顯指 agy 的寫法也算） |

- 參數看不懂時，不要猜，列出上表請使用者重新指定，然後結束。
- 以下步驟裡的「選定的 reviewer」指的就是這裡決定的一個或兩個。
- 只用一個 reviewer 時，報告要寫明「只用 Codex」或「只用 agy」，提醒使用者這次沒有交叉檢查。

## 步驟

### 1. 準備

```bash
bash ~/.claude/skills/xreview/xreview.sh prepare
```

- 記下輸出中的 `OUT=` 路徑，之後每個指令都用這個**實際路徑**（shell 變數不會保留到下一次 Bash 呼叫）。
- `STATUS: NO_CHANGES`：告訴使用者沒有未提交的變更，結束。
- `STATUS: AGY_TOO_LARGE`：diff 太大，無法交給 agy。沒有選 agy 時可以忽略。有選 agy 時，停下來問使用者要縮小範圍，還是只跑 Codex（原本兩個都用、改成只跑 Codex 時，報告要標示 agy「⚠️ 未執行」）。
- `ERROR:`：說明原因，結束。

### 2. 執行選定的 reviewer

每個選定的 reviewer 各用一個 Bash 呼叫，都設 `run_in_background: true`；兩個都用時，要在**同一則訊息**裡送出，才會真的平行。在背景執行也不受 Bash 工具前景 10 分鐘的上限限制；腳本自己有 15 分鐘的硬上限。

```bash
bash ~/.claude/skills/xreview/xreview.sh codex <OUT>
```
```bash
bash ~/.claude/skills/xreview/xreview.sh agy <OUT>
```

- 送出後告訴使用者：哪些 reviewer 已在背景執行，diff 較大時可能要幾分鐘（agy 特別慢）。
- 等**所有選定的** reviewer 完成通知都到了才繼續；不要輪詢，也不要 sleep。完成後讀取各自的背景輸出檔，取得 `STATUS:` 行。
- review 進行期間，不要修改 repo 裡的任何檔案。

### 3. 確認沒有檔案被改動

```bash
bash ~/.claude/skills/xreview/xreview.sh verify <OUT>
```

如果是 `STATUS: CHANGED`，**立刻停下**，把 `git status` 給使用者看，說明是 review 期間發生的變更，不要繼續後面的步驟，也不要自己還原。

### 4. 判斷每個 reviewer 是否成功

以腳本最後的 `STATUS:` 行為準：

- **執行失敗不等於 review 通過。** 失敗的 reviewer 在報告開頭標示「⚠️ 未執行：<原因>」。
- 選定的 reviewer 全部失敗（只選一個時，就是那一個失敗）：停下來通知使用者，不進入修改步驟。可以提議改用另一個 reviewer，或用 `/code-review` 暫時頂替，但要說清楚 `/code-review` 是 Claude 自己檢查自己。
- 不要自動重試，也不要改用付費 API key。
- 有 `WARNING:` 行時，把內容寫進報告。

### 5. 合併與判斷

讀取成功的 reviewer 的輸出：`<OUT>/codex.txt`、`<OUT>/agy.txt`。

1. 對照**實際程式碼**（用 Read 打開相關檔案）逐條驗證，不要只看 reviewer 的描述。
2. 合併重複的意見，標記提出者：Codex／agy／兩者（只用一個 reviewer 時，提出者欄可以省略）。
3. 統一嚴重度：Codex 的 P0、P1 → 高，P2 → 中，P3 → 低。
4. 每條給出判斷：**同意**或**不同意**，並附上理由。不同意的常見原因包括誤解程式碼、情境不可能發生、與變更無關。
5. 只有 Claude 自己想到、reviewer 沒提的問題，另外列在「Claude 補充」，不要混在 reviewer 的意見裡。

### 6. 報告格式（用使用者的語言）

```
## 跨模型 Review（第 N 輪）
Reviewer：Codex + agy          ← 或「只用 Codex（沒有交叉檢查）」
⚠️ agy 未執行：<原因>          ← 只在有失敗時出現
範圍：未提交的變更，共 N 個檔案

| # | 嚴重度 | 位置 | 問題 | 提出者 | 判斷 |
|---|---|---|---|---|---|
| 1 | 高 | calc.py:3 | 迴圈從 index 1 開始，漏掉第一個元素 | 兩者 | ✅ 同意 |
| 2 | 低 | calc.py:4 | … | agy | ❌ 不同意：<理由> |
```

最後問使用者要修哪幾條（例如「修 1、3」或「全部同意的都修」）。

### 7. 修改

- 只修改使用者同意的項目，其他一律不動。
- 修改完成後，簡短列出改了什麼。

### 8. 第二輪（最多兩輪）

- 第 1 輪修改完成後，問使用者要不要跑第 2 輪。要的話，用**和第 1 輪相同的 reviewer**，從步驟 1 重新開始（會用新的 OUT 資料夾）。第 2 輪報告要特別標出：第 1 輪的修改有沒有引入新問題。
- 第 2 輪修改完成後就結束，**不再主動提議第 3 輪**。還沒解決的問題列成清單交給使用者決定。
