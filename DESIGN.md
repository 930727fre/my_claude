# DESIGN — Claude Code in Docker Compose

Design rationale, trade-offs, and attack surface analysis. The operational guide is in [`README.md`](./README.md).

---

## TL;DR

- All repos share a single Claude Code container; compose lives in `~/my_claude/`, independent of any project
- Repos are bind-mounted into the container; switch projects with `cd` inside the session
- OAuth token and conversation history live in one named volume; history is still isolated per-cwd (Claude Code keys on cwd)
- User instructions (`CLAUDE.md`) are maintained in the `~/my_claude/` git repo and bind-mounted into the container
- Container runs as a non-root user (UID/GID matching the host) to avoid bind-mount ownership contamination
- An external network (`my_network`) gives Claude access to other app stacks' services
- Git push stays on the host — the container has no GitHub credentials
- Container runs in the background with `up -d`; each terminal opens its own session via `exec`

---

## Background: why this design exists

The most convenient setup — install Claude Code on the host and run `claude` from each repo's root — has several risks:

1. When Claude runs bash commands it does so as your user, with access to `~/.ssh/`, `~/.aws/`, `~/.npmrc`, and every other file you have.
2. Dependency installs (`pip install`, `npm install`) run post-install scripts under your user.
3. Prompt injection (via malicious dependencies, poisoned documents, ingested web content) can use Claude's filesystem access to do anything you can do.

Containerization confines Claude's execution to an explicit boundary, which is a reasonable isolation strategy. But containerizing raises new design questions: where does OAuth live? How do you share user instructions? This document answers them.

---

## The design decisions in detail

### Decision 1: Claude runs in a container; host has nothing installed

**Purpose**: limit the scope of what Claude can do when it runs commands. Its filesystem view is confined to the explicitly mounted directories plus `/home/claude/.claude/`. It can't see `~/.ssh`, `~/.aws`, or any other sensitive directory on the host.

**Trade-offs**:

- ✅ Strong isolation
- ✅ Easy to wipe and rebuild
- ⚠️ Adds a layer of abstraction; initial setup takes some effort
- ⚠️ You have to understand the container's network and filesystem yourself

### Decision 2: Independent container, reaching app services via an external network

**Purpose**: the Claude container doesn't belong to any project's compose stack — its lifecycle is fully independent. By joining the existing shared network `my_network`, it can reach each app stack's services directly by container name.

**Trade-offs**:

- ✅ Unaffected by any app stack's `up -d --build`
- ✅ Reuses the existing `my_network`; one line of config, no extra network setup
- ✅ Can reach any service connected to `my_network`
- ✅ Shared across all repos, so OAuth login only happens once
- ⚠️ Claude can see every service on `my_network` — accepted as known risk

### Decision 3: OAuth token stored in a single named volume

**Setup**:

```yaml
volumes:
  - claude-data:/home/claude/.claude
```

**Purpose**:

- OAuth persists and is shared across all repos — log in once
- Container writes don't contaminate the host filesystem

**What's actually inside the volume**:

- `.credentials.json` (OAuth token)
- `projects/<hash>/` (conversation history, used by `claude --resume`)
- `settings.json` (Claude Code settings)
- Other files Claude Code generates

**History isolation**: even though every repo shares the volume, Claude Code keys `projects/<hash>/` on a hash derived from cwd, so history is naturally isolated per-cwd — as long as you launch claude from the repo root, different repos' histories don't mix. Note this is cwd-based, not repo-based: launching from a subdirectory of the same repo is treated as a separate project with its own history.

**Trade-offs**:

- ✅ One OAuth login
- ✅ Token persists without leaking to the host filesystem
- ✅ Conversation history still per-cwd
- ✅ Recoverable: `docker volume rm my_claude_claude-data` forces a fresh login
- ⚠️ Inspecting history requires `docker run` into the volume

<a id="decision-4"></a>
### Decision 4: User instructions live in a host git repo, bind-mounted in

**Setup**:

```yaml
volumes:
  - ${HOME}/my_claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md
```

**Why this design**:

`CLAUDE.md` holds personal preferences shared across every project (style, design philosophy). The requirements are:

1. Maintain in one place; every project's Claude sees the same file
2. Version control (git)

**How**:

- `~/my_claude/` on the host is a git repo holding both `CLAUDE.md` and Claude's `docker-compose.yml`
- `CLAUDE.md` must be a self-contained single file (no `@path` imports) — this design only bind-mounts one file, so imported paths wouldn't exist inside the container
- The container bind-mounts that same host path
- To update rules: edit on the host → commit → push
- The bind mount is live, so the next Claude session inside the container will read the new version

**Why the bind sits on top of a named volume**:

The entire `/home/claude/.claude/` is a named volume, **but `CLAUDE.md` (a single file) is overridden by a bind mount**. This mount overlay is officially supported by docker: multiple mounts on the same point are sorted by target-path depth, and the child path always overrides the parent (independent of YAML write order). This lets us "use volume by default, but make exceptions for specific files".

In practice the compose entry uses long-form syntax with `create_host_path: false`: if the source (`~/my_claude/CLAUDE.md`) doesn't exist, `compose up` fails immediately instead of docker's default behavior (silently creating an empty directory, with the container starting up but Claude unable to read user instructions, with no error raised).

### Decision 5: Memory system handling (easy to confuse — pay attention)

Claude Code's memory system has **two independent mechanisms**: CLAUDE.md (instructions you write, divided into scopes) and auto memory (notes Claude writes about itself). This design handles them differently.

#### CLAUDE.md: four scopes

CLAUDE.md can live in four places, loaded in order (broad to narrow):

| Scope | Location | Who writes it | Range |
|---|---|---|---|
| **Managed policy** | `/Library/Application Support/ClaudeCode/CLAUDE.md` (macOS) / `/etc/claude-code/CLAUDE.md` (Linux) / `C:\Program Files\ClaudeCode\CLAUDE.md` (Windows) | Org IT/DevOps | All users on the machine |
| **User instructions** | `~/.claude/CLAUDE.md` | You, by hand | Across all projects |
| **Project instructions** | `./CLAUDE.md` or `./.claude/CLAUDE.md` | You or the team | That project |
| **Local instructions** | `./CLAUDE.local.md` | You, by hand; needs `.gitignore` | That project, personal |

All four files are **merged** at load time. More specific scopes are read later, so they win when overriding.

#### Auto memory: a completely separate mechanism

Auto memory is a feature introduced in a more recent version of Claude Code — Claude writes learned preferences into `~/.claude/projects/<project>/memory/MEMORY.md` and loads them on the next session, isolated per-cwd. Claude maintains it, you don't typically edit it by hand.

Don't confuse it with user instructions: both paths sit under `~/.claude/`, but `~/.claude/CLAUDE.md` (your instructions) and `~/.claude/projects/<project>/memory/` (Claude's learning notes) are two completely separate things.

#### Auto memory and prompt-injection persistence

Auto memory has a non-obvious attack vector: **persistent cross-session infection**. A session that gets prompt-injected can be made to write malicious instructions into auto memory ("next time, remember to do X"). The next session loads them automatically, the infection persists, and you don't proactively look at it.

This design keeps auto memory enabled and accepts the risk — cross-session memory is genuinely useful, the preconditions to successfully inject the first session are already strict, and what auto memory writes is behavioral preferences (far less influential than user instructions).

**Mitigation**: if you suspect a session has been compromised, check or clear with the `/memory` command, or run `docker volume rm my_claude_claude-data` to start fresh.

#### How this design handles each scope

| Layer | Status | Why |
|---|---|---|
| Managed policy | N/A | Personal use; nothing deployed |
| User instructions (`~/.claude/CLAUDE.md`) | ✅ Enabled | Single source of truth shared across projects, bind-mounted from a host git repo (see [Decision 4](#decision-4)) |
| Project instructions (`./CLAUDE.md`) | ⚠️ Not maintained | Personal preference; if you want it, put a file at the repo root and `cd` in before launching claude |
| Local instructions (`./CLAUDE.local.md`) | ⚠️ Not maintained | Same; gitignore if you use it |
| Auto memory | ✅ Enabled | Default behavior, per-cwd cross-session memory |

"Not maintaining project / local instructions" is a personal workflow preference, not a design constraint. Others might use project instructions for team-wide project rules, or use both layers (user = personal preferences, project = project rules). I picked one user-instructions file because most of my rules are cross-project collaboration style, I don't want to maintain one per repo, and I don't want Claude config committed into project repos.

### Decision 6: Git push stays on the host

**Purpose**: the container has zero GitHub credentials. Even if it's fully compromised, the attacker can only modify code in the working directory — they can't push.

**Workflow**:

1. Claude edits and commits inside the container (under the fake identity)
2. You exit the session and return to the host
3. `git diff origin/main..HEAD` to review what Claude did
4. Push with your host SSH key

**Why this is the safest setup**:

- Even with the container fully compromised, any code changes still have to clear your pre-push `git diff` review
- Your host SSH key never enters the container
- The container doesn't need any GitHub deploy key, PAT, or other credential

**Trade-offs**:

- ✅ Strongest isolation
- ⚠️ Claude can't open PRs by itself — no fully automated "edit → push → open PR" flow
- Workflow impact: you have an extra "push from host" step, but that step is also a review gate

### Decision 7: Git inside the container uses a fake identity

**Setup** (in the Dockerfile):

```dockerfile
RUN git config --global user.email "claude@container.local" && \
    git config --global user.name "Claude (container)"
```

**Purpose**:

- Lets `git commit` work (git requires an author identity)
- Doesn't leak your real email/name
- Commit author shows "Claude (container)", so on the host you can spot which commits came from Claude when reading the log

<a id="decision-8"></a>
### Decision 8: Container runs as a non-root user, UID/GID aligned with the host

**Setup**: see the `useradd` + `USER claude` + `mkdir .claude` block in [`Dockerfile.claude`](./Dockerfile.claude).

**Background**:

On Linux, container UIDs **map directly** to host UIDs (when user namespaces aren't enabled). If the container runs as root (UID 0), every file written through a bind mount ends up root-owned on the host. That cascades into several problems:

1. **`git status` / `git diff` get blocked**: git 2.35+'s `safe.directory` check sees `.git/` ownership doesn't match the current user and refuses all operations
2. **`git checkout` / `git pull` / `git merge` fail**: host-side git running as your regular user can't overwrite root-owned files in the working tree
3. **Manual editing needs sudo**: even fixing a typo requires `sudo vim`
4. **`sudo git push` has its own issues**: root's `$HOME` is `/root`, so it can't read your SSH key

**Solution**: create a non-root user inside the container whose UID/GID matches the host user, eliminating the ownership mismatch at its source.

**Why pre-create `.claude`**:

On first mount, docker copies the contents (including ownership) of the mount target from the image into the volume. If the image doesn't have `/home/claude/.claude/`, the docker daemon creates the mount point and it ends up root-owned, leaving the `claude` user unable to write to it. Pre-creating an empty directory lets the volume inherit the right ownership.

**Trade-offs**:

- ✅ Solves the ownership-contagion problem at the source — no downstream friction
- ✅ Further reduces attack surface: even if prompt injection makes Claude write maliciously inside the container, it runs as a regular user, not root
- ⚠️ The Dockerfile has to make sure `USER_UID/GID` match the host. Compose pulls these from the required env vars `HOST_UID` / `HOST_GID` (using `${VAR:?error}`) so a missing export fails loudly instead of silently building with the wrong UID
- ⚠️ If you later need to install additional system packages, do it **before** `USER claude` (you no longer have sudo after)

---

## Attack surface analysis

**This section's perspective**: assume someone wants to attack you (via prompt injection, malicious dependencies, etc.) — which paths does this design block, and which risks remain.

The next section ("Scope of 'won't accidentally push sensitive info'") takes a different angle: assuming you have no malicious intent yourself but might fumble and commit the wrong thing, which slips does this design catch.

### Blocked attack paths

| Attack vector | Mitigation |
|---|---|
| Claude reading `~/.ssh/` when running commands | Container can't see the host home |
| Malicious dependency stealing `~/.aws/credentials` | Same |
| Prompt injection making Claude push malicious code | Container has no GitHub credentials |
| Container writes contaminating the host filesystem | Uses a named volume, not a bind mount; only user instructions and individual repos are bind-mounted |
| Container processes running as root and wreaking havoc | Container runs as a non-root user ([Decision 8](#decision-8)), so even a successful breach has narrower powers than root |
| Bind-mount ownership drifting and breaking host-side git | Container user UID/GID aligns with the host, so files come out owned by you ([Decision 8](#decision-8)) |
| Claude container interfering with app stack startup | Claude lives in an independent compose project with a separate lifecycle |
| `up -d --build` restarting Claude sessions | Same |

### Residual risks (known and accepted)

**1. Prompt injection inside the container modifying working-directory code**

A malicious dependency or poisoned document can make Claude write things into a repo, which show up on the host because the repo is bind-mounted.

**Mitigation**: always check `git diff` before pushing. This is the design's final gate.

**2. A malicious dependency in the container reading the project's conversation history**

Conversation history lives in the named volume, and any process in the container can read it. History may contain code you discussed with Claude, contents of config files, environment variables.

**Mitigation**: you already treat Claude as an outsider and don't paste sensitive info into the conversation.

**3. Prompt injection inside the container contaminating user instructions**

`CLAUDE.md` is bind-mounted (not read-only), so Claude inside the container can write to it. A successful injection could plant malicious instructions there for the next session to auto-load.

**Mitigation**: the host has no Claude Code installed; `CLAUDE.md` is only updated when you edit it directly on the host or via `git pull`. The blast radius is equivalent to auto memory being poisoned — known and accepted.

**4. Your GitHub account gets compromised and the `my_claude` repo gets modified**

An attacker edits `~/my_claude/CLAUDE.md` to insert malicious instructions.

**Mitigation**: you `git pull` manually and look at the diff. No auto-fetch and no external PRs accepted.

**5. Container escape exploit**

A CVE-class docker bug lets code break out of the container.

**Mitigation**: keep docker up to date. Pragmatically, this is beyond what an individual developer needs to worry about.

**6. Host itself is compromised**

If the host falls, container isolation doesn't matter.

**Mitigation**: not in this threat model — it's a higher-level concern.

### Attack paths not covered (out of scope)

- Supply-chain attacks on npm/pip itself (this is the whole industry's problem)
- MITM on Anthropic's OAuth/API endpoints (HTTPS handles transport; beyond that you're trusting Anthropic)
- Physical access to your machine

---

## Scope of "won't accidentally push sensitive info"

**This section's perspective**: assume no malicious intent on your part (in contrast to the previous section), but you might fumble and `git add .` something you didn't mean to — which slips does this design catch, and which still require you to review.

### Structurally impossible to push (not in the working tree)

OAuth token, conversation history, settings, and auto memory all live in the `claude-data` named volume (docker's managed storage). User instructions `CLAUDE.md` live in a separate repo (`~/my_claude`). The host has no Claude Code installed, so things like `~/.claude/.credentials.json` don't exist at all. None of these are physically in your project's working tree, so `git add` can't reach them, so they can't be pushed — this is a strong guarantee.

### Still need review to avoid pushing (inside the working tree)

| Object | How to defend |
|---|---|
| Temporary files Claude leaves in the repo | `.gitignore` + check untracked with `git status` |
| `./.claude/` project-level directory | `.gitignore` |
| `./CLAUDE.md`, `./CLAUDE.local.md` | Depends on your workflow; gitignore if you don't maintain them |
| Source code Claude modified (unexpected edits) | `git diff origin/main..HEAD` |
| Files where Claude dumped env vars for debugging | `git status` + `git diff` |

These things sit inside repo directories that are bind-mounted in, so in principle `git add .` could include them by accident. Two lines of defense:

**Line 1: `.gitignore`**

```gitignore
# Claude Code artifacts
.claude/
CLAUDE.local.md

# Generic temporary files
*.tmp
scratch.*
debug.log
```

**Line 2: review before push**

```bash
git status                          # any untracked surprises?
git diff origin/main..HEAD          # all the changes
git diff --stat origin/main..HEAD   # be alert if it's unexpectedly large
```

<a id="git-hooks"></a>
### Disable git hooks globally (must do)

A git hook is a shell script git executes automatically on certain events (commit, push, merge, etc.). They live in each repo's `.git/hooks/` directory. Hook contents are **not tracked by git** (they don't show up in `git diff` or `git status`), and they execute with **your host user's permissions**.

For this design, that's one of the few paths that bypasses every review step and lets contamination inside the container escape to the host. Disabling them globally is the cleanest fix:

```bash
git config --global core.hooksPath /dev/null
```

After that, **every repo's** `.git/hooks/` is ignored by git and won't execute. Even if malicious code writes a hook, git won't run it. Only do this on the machine running this docker setup (Ubuntu in this case) — other machines don't touch container-side code and don't need this layer (and since `.git/hooks/` isn't tracked by git, hooks don't sync across machines, so a contaminated hook on Ubuntu won't propagate).

**Cost**: if you later want to use hooks (pre-commit framework, husky for auto-lint, etc.), those tools will be broken. To restore:

```bash
git config --global --unset core.hooksPath
```

**Check whether the current repo's hooks are clean**:

```bash
ls -la .git/hooks/
```

You should see a pile of `.sample` files (git ships with these by default; they don't execute). If you see any executable file that isn't `.sample`-suffixed, be suspicious.

---

## Possible extensions (not done currently)

These are options if your requirements change. The current design doesn't include them.

### Give the Claude container push permission

If you want Claude to handle the full commit → push → open PR flow:

- Use a GitHub Deploy Key (per-repo SSH key)
- Add branch protection: only you can push to main; Claude can only push feature branches
- Add "require signed commits": Claude has no signing key, so its commits show as unverified

Cost: bigger attack surface, deploy keys to manage per repo, stricter PR review process.

### Sync user instructions across machines

Currently this docker setup runs on one Ubuntu machine, so a local `~/my_claude` clone is enough. If you later run it on other machines too:

- Keep the git repo as the source of truth
- Each machine `git pull`s manually (don't auto-fetch)
- Make sure each machine's `~/my_claude` path is consistent

### Egress proxy restricting container network

Advanced: add a proxy service in compose that limits the Claude container to Anthropic's API and the package registries you actually need. Prevents prompt-injection-driven exfiltration to internal networks or arbitrary endpoints.

Few people need it; an individual developer probably doesn't reach this complexity threshold.

---

## Design philosophy

A few principles running through this design:

**1. Clear trust boundaries**

Each component has a different trust level:

- User instructions (you write them): high trust
- OAuth token: medium trust (sensitive but has to be given to Claude)
- Conversation history: medium trust
- Arbitrary code from dependencies running inside the container: low trust

Different trust levels don't share a single storage location. That's why `~/.claude/` is split into "volume + user instructions bind", not handled as one directory.

**2. The container is an execution environment, not an identity**

Nothing inside the container should have the ability to act in your name. Hence the fake git identity, push staying on the host, and no GitHub credentials in the container.

**3. The last gate is a human**

No matter how much automation you build, the `git diff` before `git push` can't be skipped. Every piece of automation should be designed to make review easier, not to bypass it.

**4. Treat AI as an external collaborator**

Don't feed sensitive information into your interactions with Claude. This discipline is more fundamental than any technical isolation — tech has bugs and can be misconfigured, but "I'm just not going to tell it" doesn't.

**5. Optimize for recovery, not infallibility**

Every container can be wiped and rebuilt individually. Every volume can be deleted individually. When something goes wrong, the blast radius is contained to one project or one container. The design isn't "guaranteed nothing goes wrong" — it's "when something goes wrong, the damage is small and recovery is quick".
