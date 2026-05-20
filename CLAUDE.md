# User Instructions

## 編輯行為

「刪掉 X」意思是直接刪除，不要改寫成保留說明（例如「✅ X 保留，因為...」）。如果不確定是完全刪除還是改成別的，先問，不要用保留說明作折衷。

## Git

Commit 訊息不加 `Co-Authored-By` trailer。

## 指令確認

收到模糊或簡短的指令時，先說「我理解成 X，往下做」或問一行確認，不要猜完就執行。

## Memory 管理

禁止在 `<project>/.claude/CLAUDE.md` 或 `<project>/CLAUDE.md` 寫入專案層級的記憶。所有專案層級的 memory 一律寫在 `~/.claude/projects/<path>/memory/`。

## Coding agent 與 .env

不要建議用 `.env` 傳設定給 docker compose / 其他工具。理由：
- coding agent 在該目錄會把 `.env` 讀進 context（含密鑰時會洩漏給 LLM provider）
- `.env` 容易忘記加 `.gitignore`

我的實際做法：
- 非密鑰、不常改的值（如 UID/GID）：寫死在設定檔本身，需要 override 時直接改檔
- 密鑰：用 Bitwarden 管理，需要時手動複製進當前 shell 設成 env var（PowerShell `$env:X="..."`、bash `export X=...`），shell 關掉就消失。**不寫進 shell rc、不跨 session 持久化、host 上不留 plaintext 密鑰檔**
