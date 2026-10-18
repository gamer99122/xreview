# xreview

Claude Code 的跨模型 code review skill。Claude 負責寫程式，再把未提交的變更交給 **Codex** 和 **agy（Gemini）** 兩個不同模型做唯讀 review。Claude 會把兩邊的意見合併，對照實際程式碼逐條判斷，列給你確認，你同意的項目才修改。

不用在多個終端機之間切換，也不用手動搬運 review 結果。

## 流程

```
/xreview
  1. prepare   收集未提交的變更（staged + unstaged + untracked）
  2. review    Codex 和 agy 在背景平行執行，只讀不寫
  3. verify    確認 review 期間沒有任何檔案被改動
  4. 判斷      Claude 逐條標註「同意／不同意＋理由」
  5. 修改      只修改你同意的項目；最多來回兩輪
```

## 需求

| 工具 | 測試過的版本 | 備註 |
|---|---|---|
| Claude Code | 2.1.302 | |
| Codex CLI | 0.162.1 | 需要先登入 |
| agy CLI | 1.4.0 | 需要先登入 |
| git、python3、perl | macOS 內建 | perl 用來代替 macOS 沒有的 `timeout` 指令 |

## 安裝

```bash
git clone https://github.com/gamer99122/xreview.git
mkdir -p ~/.claude/skills
ln -s "$(pwd)/xreview" ~/.claude/skills/xreview
```

用 symlink 安裝，修改 repo 裡的檔案後會直接生效。重開 Claude Code 就能使用 `/xreview`。

## 使用

在有未提交變更的 git repo 裡，於 Claude Code 輸入：

| 指令 | 使用的 reviewer |
|---|---|
| `/xreview` | Codex 和 agy 都用（預設） |
| `/xreview codex` | 只用 Codex |
| `/xreview agy` | 只用 agy |

只用一個 reviewer 會比較快、也比較省額度，但就沒有交叉檢查；報告會標明這次只用了哪一個。第二輪會沿用第一輪選的 reviewer。

這個 skill 設定成**只能手動觸發**（`disable-model-invocation: true`），Claude 不會自己啟動它，避免在你沒注意時消耗額度。

## Reviewer 模型

模型寫死在 `xreview.sh` 開頭，不依賴各 CLI 的預設值：

| reviewer | 模型 | 推理強度 |
|---|---|---|
| Codex | `gpt-5.6-sol` | `medium` |
| agy | `gemini-3.8-flash-high` | 已包含在模型名稱裡 |

要換模型，直接改那幾行就好。agy 也提供 Claude 模型，**不要拿來當 reviewer**，否則就失去跨模型檢查的意義。

## 唯讀保護

| reviewer | 保護方式 |
|---|---|
| Codex | 強制 `sandbox_mode="read-only"`，並從 log 確認實際使用的模型和沙盒 |
| agy | 在空的暫存資料夾執行、加 `--sandbox`；執行前檢查 agy 設定，有 allow 規則就拒絕執行 |
| 兩者 | `verify` 比對 repo 指紋，並找出 review 期間被寫入的所有檔案（包含 .gitignore 忽略的檔案） |

## 失敗處理

- **執行失敗不等於 review 通過。** 失敗的 reviewer 會在報告開頭標示「⚠️ 未執行」和原因。
- 兩個都失敗時，Claude 會停下來，不進入修改步驟。
- 不自動重試，也不會改用付費 API key。

## 已知限制

- 只能 review 未提交的變更，還不能指定 branch 或 commit 範圍。
- agy 很慢：12KB 的 diff 可能要 6 分鐘以上，是整個流程最慢的一段。
- agy 只看得到 diff，看不到 diff 以外的程式碼。
- diff 上限約 300KB；超過時 Claude 會問你要縮小範圍，還是只跑 Codex。

## 手動執行腳本（除錯用）

```bash
bash xreview.sh prepare           # 印出 OUT=<暫存資料夾>
bash xreview.sh codex <OUT>
bash xreview.sh agy <OUT>
bash xreview.sh verify <OUT>
```

每個子指令最後都會印出 `STATUS:` 行，review 結果在 `<OUT>/codex.txt` 和 `<OUT>/agy.txt`。

## 檔案

| 檔案 | 用途 |
|---|---|
| `SKILL.md` | 給 Claude 看的流程說明 |
| `xreview.sh` | 輔助腳本 |
| `cross-review-plan.md` | 設計決策、實測紀錄、待辦清單 |
