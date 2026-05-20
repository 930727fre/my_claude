# DESIGN — Claude Code in Docker Compose

Design notes for `~/my_claude/`. Operational guide is in [`README.md`](./README.md).

---

## TL;DR

- Single Claude Code container shared across all repos. Compose lives in `~/my_claude/`, independent of any project.
- Repos are bind-mounted in; switch with `cd` inside the session.
- OAuth + conversation history live in a named volume mounted at `$HOME`. History is keyed per-cwd by Claude Code.
- User instructions (`CLAUDE.md`) are kept in the host git repo and pasted into the container's `~/.claude/` after login. No bind mount.
- Container runs as a non-root user with UID/GID matching the host, to avoid bind-mount ownership contamination.
- Container joins the existing external `my_network` so Claude can reach other services by name.
- Git push stays on the host — the container has no GitHub credentials.

---

## Why it exists

The convenient default (install Claude Code on the host) gives any command Claude runs access to `~/.ssh/`, `~/.aws/`, `~/.npmrc`, etc. Prompt injection via dependencies or ingested content could weaponize that access. Containerization confines Claude's filesystem to an explicit set of paths. The rest of this doc covers the non-obvious choices that arise once you commit to that.

---

## Decisions

### 1–2. Container scope and networking

Claude runs in a standalone compose project (`~/my_claude/`), independent of any app stack. It joins the existing external `my_network` to reach other services by container name. Restarts/rebuilds of app stacks don't affect Claude and vice versa.

Trade-off: Claude can see every service on `my_network` — accepted.

<a id="decision-3"></a>
### 3. Volume mounted at `$HOME`, not `~/.claude/`

```yaml
volumes:
  - claude-data:/home/claude
```

Claude Code splits state across `~/.claude/` (credentials, projects/, settings) AND `~/.claude.json` (a sibling file in `$HOME` for account identity, MCP config, oauth state). A volume at `~/.claude/` covers the directory but misses the sibling file; container rebuild then loses `.claude.json` and forces re-login. Mounting one level up at `$HOME` covers both.

**What's in the volume**:
- OAuth token, conversation history, settings
- `.claude/CLAUDE.md` (manually pasted user instructions — see [Decision 4](#decision-4))
- `.claude.json` (account / MCP / oauth state)
- Whatever else lands in `$HOME` over time: shell history, `.npm/`, ad-hoc `.gitconfig`, etc.

**History isolation**: Claude Code keys `projects/<hash>/` on cwd, so different repos don't share history. Note: cwd-based, not repo-based — launching from a subdirectory is treated as a separate project.

**Image-baked dotfile trap**: anything the Dockerfile writes under `$HOME` is one-shot copied into the volume on first init, then silently shadows later Dockerfile edits. Keep the Dockerfile clean of `$HOME` writes (related: [Decision 7](#decision-7)).

<a id="decision-4"></a>
### 4. User instructions: copy-paste, not bind mount

`CLAUDE.md` lives in `~/my_claude/` as the source of truth (under git). After each build (or any edit), paste its contents into the container:

```bash
docker compose exec claude bash
nano ~/.claude/CLAUDE.md     # paste, save
```

Persists in the volume across restarts; only `docker volume rm` wipes it. **CLAUDE.md must be self-contained** (no `@path` imports): only this one file is synced, so imported paths wouldn't resolve.

**Why not bind-mount it**: the natural alternative would bind-mount `~/my_claude/CLAUDE.md` to `/home/claude/.claude/CLAUDE.md`. That target is inside the `$HOME` volume, so the bind must overlay on top — which requires `.claude/` pre-created in the Dockerfile (otherwise dockerd creates it as root and Claude can't write to its own state dir), long-form `create_host_path: false` syntax, and reasoning about mount precedence. For a single user editing CLAUDE.md infrequently, manual sync is a fair trade.

**Trade-offs**:
- ✅ No overlay-on-volume mechanics, no Dockerfile dance
- ⚠️ Drift risk: edit on host without re-pasting → stale rules
- ⚠️ A successful in-container injection can overwrite `~/.claude/CLAUDE.md` (no read-only protection). Re-paste from host overwrites it back.

### 5. Memory system handling

Two independent mechanisms — easy to confuse:
- **CLAUDE.md** (you write): merged from four scopes (managed → user → project → local). This design uses the **user scope** only, via the manual paste in [Decision 4](#decision-4). Project / local scopes aren't maintained — personal workflow preference.
- **Auto memory** (Claude writes): per-cwd notes in `~/.claude/projects/<hash>/memory/`. Enabled, default behavior.

**Auto memory's non-obvious risk**: a prompt-injected session can be made to write malicious instructions into auto memory; the next session loads them automatically. Accepted — behavioral preferences are less influential than user instructions, and injection preconditions are already strict. Clear with `/memory` or `docker volume rm` if you suspect compromise.

<a id="decision-6"></a>
### 6. Git push stays on the host

The container has no GitHub credentials. Even if fully compromised, an attacker can only modify code in the working directory — pushing requires you exiting the container and running `git push` from the host. The pre-push `git diff` is the last gate.

Cost: no fully automated "edit → push → open PR" flow inside the container.

<a id="decision-7"></a>
### 7. Git identity set ad-hoc inside the container

Nothing in the Dockerfile. First commit fails with "Author identity unknown"; set it once:

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name (my_claude container)"
```

The `(my_claude container)` suffix makes container-authored commits visually distinct in `git log`. Values persist in the volume (only wiped by `docker volume rm`).

**Why not bake it**: the named volume seeds itself from the image on first attach and shadows image-baked dotfiles thereafter (the trap in [Decision 3](#decision-3)). Baked `.gitconfig` would be copied once and silently ignore later Dockerfile edits.

<a id="decision-8"></a>
### 8. Non-root user with UID/GID matching the host

```dockerfile
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid ${USER_GID} claude \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash claude
USER claude
```

Container UIDs map directly to host UIDs on Linux. If the container runs as root, every bind-mounted file written becomes root-owned on the host — blocking `git status` (safe.directory), `git checkout/pull`, and forcing sudo for any cleanup. Aligning UIDs fixes this at the source.

Compose pulls `USER_UID`/`USER_GID` from the required env vars `HOST_UID`/`HOST_GID` with `${VAR:?error}`, so a missing export fails loudly instead of silently building with the wrong UID. If you ever need extra system packages, install them **before** `USER claude` (no sudo after).

---

## Attack surface

### Blocked

| Attack | How |
|---|---|
| Claude reading `~/.ssh`, `~/.aws`, etc. | Container can't see the host home |
| Compromise pushing malicious code | Container has no GitHub credentials |
| Container writes contaminating host | Named volume; only specific repos are bind-mounted |
| Container processes running as root | UID-matched non-root user ([Decision 8](#decision-8)) |
| Bind-mount ownership breaking host git | Same |

### Residual (known and accepted)

- **In-container injection modifying working-directory code** → pre-push `git diff` review.
- **In-container injection overwriting `CLAUDE.md`** ([Decision 4](#decision-4)) → re-paste from host; `docker volume rm` resets.
- **Malicious dependency reading conversation history** in the volume → don't paste sensitive info into chat.
- **Your GitHub account itself getting compromised** → manual `git pull` + diff review on the host repo.
- **Container escape CVE** → keep Docker updated; beyond a single dev's threat budget otherwise.

Out of scope: npm/pip supply-chain attacks, MITM on Anthropic endpoints, physical access.

---

## "Won't accidentally push sensitive info"

Different angle: assume no malicious intent, but `git add .` might catch something it shouldn't.

**Structurally impossible to push**: OAuth, history, settings, auto memory, and the in-container `CLAUDE.md` all live in the named volume. The host has no Claude Code installed. None of these are in your project's working tree, so `git add` can't reach them.

**Still need review**: anything Claude writes inside a mounted repo — temp files, `.claude/` dir, accidental env dumps, unexpected source edits. Two defenses:

1. Project `.gitignore`:
   ```
   .claude/
   CLAUDE.local.md
   *.tmp
   scratch.*
   debug.log
   ```
2. Before push: `git status` (untracked surprises?) + `git diff origin/main..HEAD` + `--stat` for size sanity.

<a id="git-hooks"></a>
### Disable git hooks globally (do this)

```bash
git config --global core.hooksPath /dev/null
```

Git hooks execute with **your host user's permissions** and aren't tracked by git, so they're one of the few paths that bypasses every review step. Disabling globally is the cleanest fix; restore with `--unset` if you ever need them. Check the current repo with `ls -la .git/hooks/` — anything not `.sample`-suffixed is suspicious.

---

## Extensions (not implemented)

- Give container push permission via per-repo Deploy Key + branch protection
- Multi-machine sync: each machine pulls + re-pastes CLAUDE.md
- Egress proxy restricting container network to Anthropic + chosen package registries

---

## Operating principle

Optimize for recovery, not infallibility. Every container can be wiped, every volume deleted, blast radius stays contained. The last gate is always the human reviewing `git diff` before push. Don't feed sensitive info into Claude; that discipline is more fundamental than any technical isolation.
