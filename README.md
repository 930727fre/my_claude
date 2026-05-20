# my_claude

Docker compose setup for a single Claude Code container shared across all your repos. Claude runs inside the container without direct access to the host filesystem. OAuth, conversation history, and user instructions all live in a named volume mounted at `$HOME` (covers both `~/.claude/` and the sibling `~/.claude.json` file Claude Code writes). User instructions (`CLAUDE.md`) are kept in this repo as source of truth and manually pasted into the container after build.

Design rationale, attack surface analysis, and all trade-offs are in [`DESIGN.md`](./DESIGN.md).

---

## Requirements

- Docker (with Docker Compose v2)
- An external network named `my_network` (if it doesn't exist, run `docker network create my_network`)
- Linux (designed for Ubuntu; macOS Docker Desktop should work but isn't verified)

---

## One-time setup

```bash
# 1. Clone the repo (convention: ~/my_claude; path no longer matters to compose)
git clone https://github.com/<yourname>/my_claude.git ~/my_claude
cd ~/my_claude

# 2. Export HOST_UID / HOST_GID in your shell rc
./setup.sh
# Copy the printed export lines into your ~/.bashrc or ~/.zshrc,
# then 'source' it (or open a new shell). Every docker compose command
# below requires HOST_UID and HOST_GID to be in the environment — if
# they're unset, compose fails loudly with a clear error.

# 3. Edit CLAUDE.md to suit your preferences (stays on host as source of truth)

# 4. Adjust the repos mounted in docker-compose.yml's volumes section
#    The defaults are ~/repoA and ~/repoB — change as needed

# 5. Build and start the container
docker compose build
docker compose up -d

# 6. Log in to Claude Code, then paste CLAUDE.md into the container
docker compose exec claude bash
# inside container:
claude                       # first run triggers OAuth; also creates ~/.claude/
# Ctrl+C out of claude, then:
nano ~/.claude/CLAUDE.md     # paste content from host's ~/my_claude/CLAUDE.md, save
# CLAUDE.md now persists in the volume across rebuilds
```

---

## Daily use

```bash
# Open a session in any terminal (you can open multiple)
cd ~/my_claude
docker compose exec claude bash

# Inside the container, cd to the repo you want to work on and launch claude
cd ~/repoA
claude
# OAuth was done during setup and the token is in the volume, so no login needed
```

When Claude is done editing, **push from the host**:

```bash
git diff origin/main..HEAD       # Review what Claude did
git push                          # Uses your host SSH key
```

When you're not using the container you can `docker compose down`, but idle has essentially no cost, so you usually don't need to.

---

## Important gotchas

- **Push happens on the host, not in the container.** There's no GitHub credential inside the container; this is a deliberate security gate, not a bug.
- **Conversation history is keyed by cwd.** Different subdirectories of the same repo are treated as different projects with separate histories — get into the habit of launching `claude` from the repo root.
- **`HOST_UID` / `HOST_GID` must be exported in your shell.** Compose pulls these into the build args; if they're missing, every `docker compose` command fails immediately. This is the defense against silent ownership mismatch — bind-mounted files would otherwise end up with the wrong owner, host-side git would get blocked by `safe.directory`, and editing would need sudo. Run `./setup.sh` to see the export lines to add.
- **Strongly recommended: disable git hooks globally on the host**: `git config --global core.hooksPath /dev/null`. `setup.sh` warns you if this isn't set. See [`DESIGN.md`](./DESIGN.md#git-hooks) for the reasoning.
- **First commit on a fresh container will fail with "Author identity unknown"** — git identity isn't baked into the image (would get shadowed by the volume; see [`DESIGN.md`](./DESIGN.md#decision-7)). Set it once with `git config --global user.email/name` inside the container; it persists in the volume.

---

## Updating user instructions

```bash
# 1. Edit on host (source of truth)
cd ~/my_claude
vim CLAUDE.md
git commit -am "update rule"
git push

# 2. Re-paste into the container
docker compose exec claude bash
nano ~/.claude/CLAUDE.md     # paste new content, save

# Already-running claude sessions won't pick up the change until restarted.
```

---

## Resetting state

```bash
# Force re-authentication and wipe all conversation history
# (also wipes the in-container CLAUDE.md — re-paste from host after next login)
docker volume rm my_claude_claude-data
```

---

For full design rationale, see [`DESIGN.md`](./DESIGN.md).
