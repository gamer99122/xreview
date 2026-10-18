---
name: xreview
description: 跨模型 code review：把目前未提交的變更交給 Codex（gpt-5.6-sol）和 agy（gemini-3.8-flash-high）唯讀審查，由 Claude 合併、逐條判斷，使用者確認後才修改。只能手動用 /xreview 觸發。
disable-model-invocation: true
---

# /xreview — 跨模型 code review

Codex 和 agy **只負責 review，不能修改任何檔案**。修改一律由 Claude 進行，而且要先經過使用者同意。

輔助腳本：`~/.claude/skills/xreview/xreview.sh`。模型設定寫死在腳本開頭，不依賴 CLI 的預設值。

## 步驟

### 1. 準備

```bash
bash ~/.claude/skills/xreview/xreview.sh prepare
```

- 記下輸出中的 `OUT=` 路徑，之後每個指令都用這個**實際路徑**（shell 變數不會保留到下一次 Bash 呼叫）。
- `STATUS: NO_CHANGES`：告訴使用者沒有未提交的變更，結束。
- `STATUS: AGY_TOO_LARGE`：diff 太大，無法交給 agy。停下來問使用者要縮小範圍，還是只跑 Codex（只跑 Codex 時，報告要標示 agy「⚠️ 未執行」）。
- `ERROR:`：說明原因，結束。

### 2. 同時執行兩個 reviewer

在**同一則訊息**裡送出兩個 Bash 呼叫，**兩個都設 `run_in_background: true`**。在背景執行才會真的平行，也不受 Bash 工具前景 10 分鐘的上限限制；腳本自己有 15 分鐘的硬上限。

```bash
bash ~/.claude/skills/xreview/xreview.sh codex <OUT>
```
```bash
bash ~/.claude/skills/xreview/xreview.sh agy <OUT>
```

- 送出後告訴使用者：兩個 reviewer 已在背景執行，diff 較大時可能要幾分鐘。
- 等**兩個**完成通知都到了才繼續；不要輪詢，也不要 sleep。完成後讀取各自的背景輸出檔，取得 `STATUS:` 行。
- review 進行期間，不要修改 repo 裡的任何檔案。

### 3. 確認沒有檔案被改動

```bash
bash ~/.claude/skills/xreview/xreview.sh verify <OUT>
```

如果是 `STATUS: CHANGED`，**立刻停下**，把 `git status` 給使用者看，說明是 review 期間發生的變更，不要繼續後面的步驟，也不要自己還原。

### 4. 判斷每個 reviewer 是否成功

以腳本最後的 `STATUS:` 行為準：

- **執行失敗不等於 review 通過。** 失敗的 reviewer 在報告開頭標示「⚠️ 未執行：<原因>」。
- 兩個都失敗：停下來通知使用者，不進入修改步驟。可以提議改用 `/code-review` 暫時頂替，但要說清楚那是 Claude 自己檢查自己。
- 不要自動重試，也不要改用付費 API key。
- 有 `WARNING:` 行時，把內容寫進報告。

### 5. 合併與判斷

讀取 `<OUT>/codex.txt` 和 `<OUT>/agy.txt`：

1. 對照**實際程式碼**（用 Read 打開相關檔案）逐條驗證，不要只看 reviewer 的描述。
2. 合併重複的意見，標記提出者：Codex／agy／兩者。
3. 統一嚴重度：Codex 的 P0、P1 → 高，P2 → 中，P3 → 低。
4. 每條給出判斷：**同意**或**不同意**，並附上理由。不同意的常見原因包括誤解程式碼、情境不可能發生、與變更無關。
5. 只有 Claude 自己想到、reviewer 沒提的問題，另外列在「Claude 補充」，不要混在 reviewer 的意見裡。

### 6. 報告格式（用使用者的語言）

```
## 跨模型 Review（第 N 輪）
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

- 第 1 輪修改完成後，問使用者要不要跑第 2 輪。要的話，從步驟 1 重新開始（會用新的 OUT 資料夾）。第 2 輪報告要特別標出：第 1 輪的修改有沒有引入新問題。
- 第 2 輪修改完成後就結束，**不再主動提議第 3 輪**。還沒解決的問題列成清單交給使用者決定。
