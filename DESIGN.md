# DESIGN — Claude Code in Docker Compose

設計理由、權衡、攻擊面分析。操作指南在 [`README.md`](./README.md)。

---

## TL;DR

- 所有 repo 共用一個 Claude Code container，compose 放在 `~/my_claude/`，不屬於任何專案
- 所有 repo bind mount 進 container，session 內 `cd` 切換專案
- OAuth token 與對話歷史存在單一 named volume；對話歷史 per-cwd 隔離（Claude Code 用 cwd 當 key）
- User instructions (`CLAUDE.md`) 在 `~/my_claude/` git repo 維護，bind mount 進 container
- Container 內以非 root user（UID/GID 對齊 host）跑，避免 bind mount 的 ownership 傳染問題
- 透過 external network (`my_network`) 存取各 app stack 的 service
- Git push 留在 host 做，container 內沒有任何 GitHub credential
- Container 用 `up -d` 常駐，多個 terminal 各自 `exec` 進去開 session

---

## 背景：為什麼要做這個設計

直接在 host 上裝 Claude Code 並在各 repo 根目錄跑 `claude` 是最方便的做法，但有幾個風險：

1. Claude 執行 bash 命令時，環境是你個人 user，能存取 `~/.ssh/`、`~/.aws/`、`~/.npmrc` 等所有檔案
2. Dependency 安裝（`pip install`、`npm install`）的 post-install script 在你個人 user 權限下執行
3. Prompt injection（透過惡意 dependency、被污染的文件、被讀入的 web 內容）可以利用 Claude 對檔案系統的存取做任何你能做的事

容器化把 Claude 的執行環境限縮到一個明確的邊界內，是合理的隔離策略。但容器化引入新的設計問題：OAuth 怎麼存？User instructions 怎麼共用？這份文件就是回答這些問題。

---

## 每個設計決策的細節

### 決策 1：Claude 跑在 container，host 不裝

**目的**：限制 Claude 執行命令的權限範圍，把它的 filesystem 視野侷限在明確掛載進來的目錄和 `/home/claude/.claude/`，看不到你 host 的 `~/.ssh`、`~/.aws` 等敏感目錄。

**取捨**：

- ✅ 強隔離
- ✅ 容易整個清掉重來
- ⚠️ 多一層抽象，初次設定需要時間
- ⚠️ Container 內網路、檔案系統的細節要自己掌握

### 決策 2：獨立 container，透過 external network 存取 app services

**目的**：Claude container 不屬於任何專案的 compose stack，生命週期完全獨立。透過加入既有的 shared network `my_network`，能直接用 container name 存取各 app stack 的 service。

**取捨**：

- ✅ 不受任何 app stack 的 `up -d --build` 影響
- ✅ 利用現有 `my_network`，一行設定，不需要額外建 network
- ✅ 能存取所有加入 `my_network` 的 app service
- ✅ 所有 repo 共用，OAuth 只需登入一次
- ⚠️ Claude 能看到 `my_network` 上的所有 service，已知並接受

### 決策 3：OAuth token 存單一 named volume

**設定**：

```yaml
volumes:
  - claude-data:/home/claude/.claude
```

**目的**：

- OAuth 持久化，所有 repo 共用，只需登入一次
- Container 寫入不污染 host filesystem

**Volume 內實際存了什麼**：

- `.credentials.json`（OAuth token）
- `projects/<hash>/`（對話歷史，`claude --resume` 用）
- `settings.json`（Claude Code 設定）
- 其他 Claude Code 自動產生的檔

**對話歷史的隔離**：雖然所有 repo 共用同一個 volume，Claude Code 內部用 cwd 推導出的 hash 當 key，所以 `projects/<hash>/` 天然 per-cwd 隔離——只要習慣從 repo 根目錄啟動 claude，不同 repo 的對話歷史不會混。注意這是 cwd-based 而非 repo-based：在同一個 repo 的不同子目錄啟動會被視為不同 project，對話歷史不互通。

**取捨**：

- ✅ OAuth 只需登入一次
- ✅ Token 持久化但不洩漏到 host filesystem
- ✅ 對話歷史仍 per-cwd 隔離
- ✅ 出事可以 `docker volume rm my_claude_claude-data` 強迫重登入
- ⚠️ 想 inspect 對話歷史要 `docker run` 進 volume 看

<a id="decision-4"></a>
### 決策 4：User instructions 用 host git repo + bind mount

**設定**：

```yaml
volumes:
  - ${HOME}/my_claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md
```

**為什麼這樣設計**：

`CLAUDE.md` 是跨所有專案共用的個人偏好（風格、設計哲學）。需求：

1. 一處維護，所有專案的 Claude 看到同一份
2. 版本管理（git）

**做法**：

- Host 上 `~/my_claude/` 是一個 git repo，同時放 `CLAUDE.md` 和 Claude 的 `docker-compose.yml`
- `CLAUDE.md` 必須是自足的單一檔案（不使用 `@path` import）——這份設計只 bind 單一檔案，import 指向的路徑在 container 內不存在
- Claude container bind 同一個 host 路徑
- 想更新規則：host 上編輯 → commit → push
- Bind mount 是 live 的，container 內下次 Claude 開新 session 就讀到新版

**為什麼疊在 named volume 上**：

整個 `/home/claude/.claude/` 是 named volume，**但 `CLAUDE.md` 一個檔被 bind mount 覆蓋**。這個 mount overlay 是 docker 官方支援的行為——同一個 mount point 上可以疊多層 mount，Docker 按 target 路徑深度排序處理，子路徑永遠覆蓋父路徑（與 YAML 書寫順序無關）。這讓我們可以「主要用 volume 但只在特定檔案開例外」。

實際 compose 用 long-form syntax 並加 `create_host_path: false`：source（`~/my_claude/CLAUDE.md`）不存在時 compose up 直接 fail，避免 docker 預設行為（自動建空目錄頂上去，container 起來但 Claude 讀不到 user instructions 還不報錯）。

### 決策 5：Memory 系統的處理（容易混淆，注意區分）

Claude Code 的 memory 系統有**兩個獨立機制**：CLAUDE.md（你寫的指示，分多個 scope）和 auto memory（Claude 自己寫的學習筆記）。這份設計對這兩個系統做了不同處理。

#### CLAUDE.md：四個 scope

CLAUDE.md 可以放在四個位置，按 load 順序（從廣到窄）：

|Scope|位置|誰寫的|範圍|
|---|---|---|---|
|**Managed policy**|`/Library/Application Support/ClaudeCode/CLAUDE.md` (macOS) / `/etc/claude-code/CLAUDE.md` (Linux) / `C:\Program Files\ClaudeCode\CLAUDE.md` (Windows)|組織 IT/DevOps|機器上所有 user|
|**User instructions**|`~/.claude/CLAUDE.md`|你手寫|跨所有專案|
|**Project instructions**|`./CLAUDE.md` 或 `./.claude/CLAUDE.md`|你或團隊手寫|該專案|
|**Local instructions**|`./CLAUDE.local.md`|你手寫，要 `.gitignore`|該專案，個人|

四個檔案**合併**載入，更具體的 scope 後讀，覆蓋優先。

#### Auto memory：完全獨立的另一個機制

Auto memory 是 Claude Code 較新版本引入的功能——Claude 把學到的偏好寫進 `~/.claude/projects/<project>/memory/MEMORY.md`，下個 session 自動載入，per-cwd 隔離。由 Claude 自己維護，你不會主動編輯。

別跟 user instructions 搞混：兩者路徑都在 `~/.claude/` 下，但 `~/.claude/CLAUDE.md`（你寫的指示）跟 `~/.claude/projects/<project>/memory/`（Claude 自己寫的學習筆記）完全是兩件事。

#### Auto memory 的 prompt injection 持久化風險

Auto memory 有一個不明顯的攻擊向量：**跨 session 的感染**。被 prompt inject 的 session 可以讓 Claude 把惡意指令寫進 auto memory（「下次記得先做 X」），下個 session 自動載入，感染持續而且你不會主動看到它。

這個設計選擇繼續開 auto memory，接受這個風險——跨 session 記憶實用價值高、第一個 session 要被 inject 成功的前提條件本來就很嚴格、auto memory 寫的是行為偏好影響力遠低於 user instructions。

**緩解**：可疑時 `/memory` 命令檢查或清除，或 `docker volume rm my_claude_claude-data` 從乾淨狀態開始。

#### 這份設計對每個 scope 的處理

|層級|狀態|為什麼|
|---|---|---|
|Managed policy|N/A|個人沒部署|
|User instructions (`~/.claude/CLAUDE.md`)|✅ 啟用|跨專案共用的單一 source of truth，bind mount 自 host git repo（見 [決策 4](#decision-4)）|
|Project instructions (`./CLAUDE.md`)|⚠️ 不維護|個人偏好；想用就在 repo 根目錄放檔再 `cd` 進去啟動 claude|
|Local instructions (`./CLAUDE.local.md`)|⚠️ 不維護|同上；用了記得 `.gitignore`|
|Auto memory|✅ 開著|預設行為，per-cwd 跨 session 記憶|

「不維護 project / local instructions」是個人工作流偏好不是設計限制——別人可能會用 project instructions 給團隊共用專案規範，或同時用兩層（user = 個人偏好、project = 專案規範）。我選一份 user instructions 是因為大部分規則跨專案通用、不想在每個 repo 維護一份、不想 commit Claude 設定進專案 repo。

### 決策 6：Git push 留在 host 做

**目的**：Container 內完全沒有任何 GitHub credential。即使被打穿，攻擊者頂多能改 working directory 的程式碼，但 push 不出去。

**工作流**：

1. Claude 在 container 內改 code、commit（用假身份）
2. 你結束 session，回到 host
3. `git diff origin/main..HEAD` 檢查 Claude 做了什麼
4. 用你 host 的 SSH key push

**為什麼這樣最安全**：

- 即使 container 完全失守，攻擊者改的 code 也要過你 push 前的 `git diff` 檢查
- 你 host 的 SSH key 從來沒進過 container
- Container 不需要任何 GitHub deploy key、PAT、credential

**取捨**：

- ✅ 最強隔離
- ⚠️ Claude 不能自己開 PR、不能完成「改完 code → push → 開 PR」的全自動流程
- 對工作流的影響：你多一個「host 上 push」的步驟，但這個步驟同時是 review gate

### 決策 7：Container 內 git 用假身份

**設定**（在 Dockerfile）：

```dockerfile
RUN git config --global user.email "claude@container.local" && \
    git config --global user.name "Claude (container)"
```

**目的**：

- 讓 `git commit` 能 work（git 要求 author identity）
- 不洩漏你真實 email/name
- Commit author 顯示「Claude (container)」，你回 host 看 log 就知道哪些 commit 是 Claude 做的

<a id="decision-8"></a>
### 決策 8：Container 內以非 root user 跑，UID/GID 對齊 host

**設定**：見 [`Dockerfile.claude`](./Dockerfile.claude) 的 `useradd` + `USER claude` + `mkdir .claude` 那段。

**問題背景**：

Linux 上 container 的 UID **直接對應** host 的 UID（沒有 user namespace 隔離時）。如果 container 內以 root（UID 0）跑，所有寫入 bind mount 的檔案在 host 上 owner 就是 root。這會傳染出一連串問題：

1. **`git status` / `git diff` 被擋**：git 2.35+ 的 `safe.directory` 檢查發現 `.git/` ownership 跟當前 user 不符，refuse 所有操作
2. **`git checkout` / `git pull` / `git merge` 失敗**：host 上以普通 user 跑 git，無法 overwrite root-owned 的工作目錄檔案
3. **手動編輯要 sudo**：你想修個 typo 都得 `sudo vim`
4. **`sudo git push` 也有問題**：root 的 `$HOME` 是 `/root`，讀不到你的 SSH key

**解法**：container 內建一個 UID/GID 對應 host user 的非 root user，從源頭避免 ownership 不對等。

**為什麼預建 `.claude` 目錄**：

Named volume 第一次掛載時，docker 會把 mount target 在 image 內的內容（含 ownership）複製進 volume。如果 image 沒有 `/home/claude/.claude/`，volume 會被 docker daemon 直接建立成 root-owned，container 內 claude user 寫不進去。預建一個空目錄讓 volume 繼承正確的 ownership。

**取捨**：

- ✅ 從源頭解決 ownership 傳染問題，沒有後續摩擦
- ✅ 攻擊面進一步縮小：即使 prompt injection 讓 Claude 在 container 內亂寫，也是普通 user 權限而非 root
- ⚠️ Dockerfile 需要保證 `USER_UID/GID` 跟 host 一致。多人共用同一份 Dockerfile 時要靠 build args 傳入
- ⚠️ 如果未來 image 內需要裝額外的 system package，記得在 `USER claude` 切換前做（之後就沒 sudo 了）

---

## 攻擊面分析

**這節的視角**：假設有人想攻擊你（透過 prompt injection、惡意 dependency 等），這個設計擋掉哪些路徑、剩下哪些風險。

下一節「不會不小心 push 敏感資訊」是另一個視角——假設你自己沒有惡意，但可能失手把東西 commit 上去，設計能幫你擋哪些。

### 已隔離的攻擊路徑

|攻擊向量|緩解機制|
|---|---|
|Claude 執行命令時讀你 `~/.ssh/`|Container 內看不到 host home|
|惡意 dependency 偷你的 `~/.aws/credentials`|同上|
|Prompt injection 讓 Claude push 惡意 code|Container 內沒 GitHub credential|
|Container 寫入污染 host filesystem|用 named volume 不用 bind mount，只有 user instructions 和各 repo 是 bind|
|Container 內 process 以 root 身分搞破壞|Container 內以非 root user 跑（[決策 8](#decision-8)），即使被打穿能做的事比 root 少|
|Bind mount 檔案 ownership 跑掉導致 host 上 git 失常|Container user UID/GID 對齊 host，寫出的檔案 owner 就是你（[決策 8](#decision-8)）|
|Claude container 跟應用 stack 互相干擾啟動|Claude 在獨立 compose project，生命週期分離|
|`up -d --build` 重啟 Claude session|同上|

### 剩餘風險（已知並接受）

**1. Container 內 prompt injection 改 working directory 程式碼**

惡意 dependency 或被污染的文件能讓 Claude 寫東西進 repo，這些寫入會出現在你 host 上（因為 repo 是 bind mount）。

**緩解**：你 push 前 `git diff` 必看。這是設計上的最後一道閘門。

**2. Container 內惡意 dependency 讀到該專案的對話歷史**

對話歷史在 named volume 內，container 內任何 process 都讀得到。對話歷史可能包含你跟 Claude 討論過的 code、設定檔內容、環境變數。

**緩解**：你已經把 Claude 當外人對待，不在對話中提供敏感資訊。

**3. Container 內 prompt injection 污染 user instructions**

`CLAUDE.md` 是 bind mount（非 read-only），container 內的 Claude 能寫入。被 prompt inject 後攻擊者可以把惡意指令寫進 `CLAUDE.md`，下次 session 自動載入。

**緩解**：host 不裝 Claude Code，`CLAUDE.md` 只在 host 上被你直接編輯或 git pull 時更新。影響範圍等同 auto memory 被污染，已知並接受。

**4. 你的 GitHub 帳號被盜，`my_claude` repo 被改**

攻擊者改 `~/my_claude/CLAUDE.md` 加入惡意指令。

**緩解**：你手動 `git pull` 時看 diff。你不自動 fetch、不接受外部 PR。

**5. Container escape exploit**

Docker 本身的 CVE 級別 bug 讓 container 內能跳出。

**緩解**：keep docker 更新，但實務上這超出個人開發者該擔心的範圍。

**6. Host 本身被入侵**

Host 失守時容器隔離沒意義。

**緩解**：不在這個威脅模型內，是更上層的問題。

### 沒處理的攻擊路徑（不在威脅模型內）

- 供應鏈攻擊 npm/pip 本身（這是所有開發者的共同問題）
- Anthropic 的 OAuth/API endpoint 被 MITM（HTTPS 已保護，剩下的是你信任 Anthropic）
- 你機器的物理存取攻擊

---

## 「不會不小心 push 敏感資訊」的範圍

**這節的視角**：假設你自己沒有惡意（跟上一節攻擊面相對），但可能失手 `git add .` 把不該 commit 的東西加進去——設計幫你擋掉哪些，哪些仍要靠你自己 review。

### 結構性保證不會被 push 的（不在 working tree 內）

OAuth token、對話歷史、settings、auto memory 全部在 `claude-data` named volume（docker 管理區）；user instructions `CLAUDE.md` 在另一個 repo (`~/my_claude`)；host 上沒裝 Claude Code，所以 `~/.claude/.credentials.json` 之類根本不存在。這些東西 physically 不在你專案的 working tree 內，`git add` 不到，不可能被 push——這是強保證。

### 仍需 review 才能避免 push 的（在 working tree 內）

|物件|怎麼防|
|---|---|
|Claude 留在 repo 內的暫存檔|`.gitignore` + `git status` 看 untracked|
|`./.claude/` project-level 目錄|`.gitignore`|
|`./CLAUDE.md`、`./CLAUDE.local.md`|看你工作流，不維護就 `.gitignore`|
|被 Claude 改的 source code（異常修改）|`git diff origin/main..HEAD`|
|Claude 為 debug 而 dump 環境變數到檔案|`git status` + `git diff`|

這些東西因為在 bind mount 進來的 repo 目錄內，理論上可能被 `git add .` 不小心加進去。靠兩道防線：

**防線 1：`.gitignore`**

```gitignore
# Claude Code artifacts
.claude/
CLAUDE.local.md

# 通用暫存
*.tmp
scratch.*
debug.log
```

**防線 2：Push 前 review**

```bash
git status                          # 有沒有 untracked 出現
git diff origin/main..HEAD          # 看所有改動
git diff --stat origin/main..HEAD   # 異常大就警覺
```

<a id="git-hooks"></a>
### Git hooks 全域關閉（必做）

Git hook 是 git 在特定事件（commit、push、merge 等）自動執行的 shell script，放在每個 repo 的 `.git/hooks/` 目錄。Hook 內容**不被 git 追蹤**（不會在 `git diff`、`git status` 出現），執行時用**你 host 的 user 權限**。

對這份設計來說，這是少數能繞過所有 review 流程、讓 container 內污染逃逸到 host 的路徑。直接全域關掉最徹底：

```bash
git config --global core.hooksPath /dev/null
```

之後**所有 repo** 的 `.git/hooks/` 都被 git 忽略，不會執行。即使惡意 code 寫入 hook，git 也不會跑。只在跑這套 docker 的 Ubuntu 機器做即可——其他機器沒接觸 container 內的程式碼，不需要這層保護（`.git/hooks/` 不被 git 追蹤，不會跨機器同步，所以 Ubuntu 上被污染的 hook 不會傳給其他機器）。

**代價**：如果哪天你想用 hook（pre-commit framework、husky 自動 lint 等），這些工具會失效。要恢復：

```bash
git config --global --unset core.hooksPath
```

**檢查當前 repo 的 hooks 是否乾淨**：

```bash
ls -la .git/hooks/
```

預期看到一堆 `.sample` 結尾的範例檔（git 預設就有，不會執行）。如果有任何不是 `.sample` 結尾的可執行檔，要警覺。

---

## 一些可能的擴充方向（目前沒做）

這些是「如果需求變了」可以考慮的選項，目前的設計沒做這些。

### 給 Claude container push 權限

如果想讓 Claude 自己完成 commit → push → 開 PR 流程：

- 用 GitHub Deploy Key（per-repo SSH key）
- 加 branch protection：限制 main 只有你能 push，Claude 只能 push feature branch
- 加 require signed commits：Claude 沒簽章 key，它的 commit 顯示 unverified

代價：攻擊面變大、需要設定每個 repo 的 deploy key、PR review 流程要更嚴謹。

### 跨機器同步 user instructions

目前這套 docker 架構只跑在 Ubuntu 一台機器上，所以 `~/my_claude` 本地 clone 就好。如果未來其他機器也要跑這套：

- 維持 git repo 作為 source of truth
- 每台機器各自 `git pull`（手動，不要自動 fetch）
- 確認每台機器的 `~/my_claude` 路徑一致

### Egress proxy 限制 container 網路

進階：在 compose 加一個 proxy service，限制 Claude container 只能連 Anthropic API 和必要的 package registry。防止被 prompt injection 騙去訪問內網或 exfiltrate 資料。

需要的人很少，個人開發者通常不到這個複雜度。

---

## 設計哲學

幾個貫穿這份設計的原則：

**1. 信任邊界明確**

每個元件的信任等級不同：

- User instructions（你寫的）：高信任
- OAuth token：中信任（敏感但必須給 Claude 用）
- 對話歷史：中信任
- Container 內任意 dependency 跑的 code：低信任

不同信任等級不混在一個儲存位置處理。所以 `~/.claude/` 才會被拆成「Volume + user instructions bind」兩塊，而不是整個目錄一起處理。

**2. 容器是執行環境，不是身份**

Container 內不應該有「以你的名義做事」的能力。所以 git 用假身份、push 留在 host、Claude container 沒有 GitHub credential。

**3. 最後一道閘門是人**

不管前面有多少自動化，`git push` 前的 `git diff` 是不能省的。所有自動化都應該設計成「方便你 review」，不是「跳過 review」。

**4. 把 AI 當外部協作者**

不在跟 Claude 互動時提供敏感資訊。這個紀律比任何技術隔離都更根本——技術會有 bug、會配置錯誤，但「我不會講」這個原則不會。

**5. Optimize for 出事時的可恢復性**

每個 container 可以單獨清掉重來。每個 volume 可以單獨刪除。出事的影響面盡量限縮在單一專案、單一 container。設計不是「保證不出事」，是「出事時損失小、恢復快」。
