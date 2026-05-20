# my_claude

跨所有 repo 共用一個獨立的 Claude Code container 的 docker compose 設定。Claude 跑在 container 裡，不直接接觸 host filesystem；OAuth 與對話歷史在 named volume，user instructions (`CLAUDE.md`) bind mount 進去。

設計理由、攻擊面分析、所有 trade-off 在 [`DESIGN.md`](./DESIGN.md)。

---

## 需求

- Docker（含 Docker Compose v2）
- 一個叫 `my_network` 的 external network（如果沒有，跑 `docker network create my_network`）
- Linux（這份設定針對 Ubuntu 設計；macOS Docker Desktop 應該也能跑但沒驗證）

---

## 一次性 setup

```bash
# 1. clone 到 ~/my_claude（路徑不能變，compose 裡寫死了）
git clone https://github.com/<yourname>/my_claude.git ~/my_claude
cd ~/my_claude

# 2. 確認 host UID/GID
./setup.sh
# 印出來不是 1000:1000 的話，把 docker-compose.yml 的 USER_UID / USER_GID 改成你的數字

# 3. 編輯 CLAUDE.md，放入你的 user instructions

# 4. 把要 bind 進來的 repo 改進 docker-compose.yml 的 volumes 區塊
#    預設範例是 ~/repoA、~/repoB，自行調整

# 5. Build image
docker compose build

# 6. 啟動 container（常駐背景）
docker compose up -d
```

---

## 日常使用

```bash
# 每個 terminal 都這樣開 session（可以同時開多個）
cd ~/my_claude
docker compose exec claude bash

# 進到 container 後切到要工作的 repo，啟動 claude
cd ~/repoA
claude
# 第一次跑會走 OAuth flow（device code），用瀏覽器完成登入後 token 存在 volume，之後不用再登
```

Claude 改完 code 後**回 host push**：

```bash
git diff origin/main..HEAD       # 檢查 Claude 做了什麼
git push                          # 用 host 的 SSH key
```

Container 不用時可以 `docker compose down`，但 idle 開著沒實質成本，通常不用管。

---

## 重要 gotchas

1. **CLAUDE.md 不存在 → compose up 會直接 fail**（因為 `create_host_path: false`）。這是故意的——避免 docker 默默建空目錄頂上去、container 起來但 Claude 讀不到 instructions 還不報錯。
2. **Push 在 host 做，不在 container**。Container 內沒有 GitHub credential，這是設計上的安全閘門，不是 bug。
3. **對話歷史 per-cwd 隔離**。同一個 repo 的不同子目錄會被視為不同 project，歷史不互通——習慣從 repo 根目錄啟動 claude。
4. **UID/GID 必須對齊 host**。不然 bind mount 寫出的檔案 owner 跟你不一致，host 上 git 會被 `safe.directory` 擋住、`vim` 編輯要 sudo。`./setup.sh` 印出來確認。
5. **`docker attach` 不要用**——它共用 PID 1 stdio，多 terminal 會互相干擾。多 session 用 `docker compose exec`。
6. **強烈建議 host 全域關閉 git hooks**：`git config --global core.hooksPath /dev/null`。原因見 [`DESIGN.md`](./DESIGN.md#git-hooks)。

---

## 更新 user instructions

```bash
cd ~/my_claude
vim CLAUDE.md
git commit -am "update rule"
git push

# 已經在跑的 Claude session 不會立刻看到新版
# 下次 Claude 開新 session 自動載入
```

---

## 清理狀態

```bash
# 強迫重新 OAuth、清掉所有對話歷史
docker volume rm my_claude_claude-data
```

---

## FAQ

**Q: 我有好幾個 Claude session 同時開，編輯 CLAUDE.md 後即時生效嗎？**

檔案層級即時，session 層級不會。Claude 在 session 啟動時讀一次 CLAUDE.md 後不會動態 reload。已開的 session 要 `/clear` 或退出重開才會看到新版。

**Q: CLAUDE.md 該寫什麼？**

純粹的協作偏好——回覆語言、commit 訊息格式、staging 習慣、設計哲學等。避免內網 URL、客戶名稱、密鑰、絕對路徑揭露身份等資訊（CLAUDE.md 會被 commit 進這個 repo，把 Claude 當外人看待自然不會在這檔寫敏感東西）。

**Q: Hot reload 在 container 內不 work？**

跟 Claude 設定無關，是 docker bind mount 在 Mac/Windows 上的 file watching 問題。解法：framework 配置開 polling 模式（Vite `usePolling: true`、CRA `CHOKIDAR_USEPOLLING=true`、Next.js webpack `poll: 500`）。

---

完整設計理由請看 [`DESIGN.md`](./DESIGN.md)。
