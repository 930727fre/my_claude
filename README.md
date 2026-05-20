# my_claude

Docker compose setup for a single Claude Code container shared across all your repos. Claude runs inside the container without direct access to the host filesystem; OAuth and conversation history live in a named volume, and user instructions (`CLAUDE.md`) are bind-mounted in.

Design rationale, attack surface analysis, and all trade-offs are in [`DESIGN.md`](./DESIGN.md).

---

## Requirements

- Docker (with Docker Compose v2)
- An external network named `my_network` (if it doesn't exist, run `docker network create my_network`)
- Linux (designed for Ubuntu; macOS Docker Desktop should work but isn't verified)

---

## One-time setup

```bash
# 1. Clone into ~/my_claude (the path is hardcoded in compose, don't change it)
git clone https://github.com/<yourname>/my_claude.git ~/my_claude
cd ~/my_claude

# 2. Export HOST_UID / HOST_GID in your shell rc
./setup.sh
# Copy the printed export lines into your ~/.bashrc or ~/.zshrc,
# then 'source' it (or open a new shell). Every docker compose command
# below requires HOST_UID and HOST_GID to be in the environment — if
# they're unset, compose fails loudly with a clear error.

# 3. Edit CLAUDE.md with your user instructions

# 4. Adjust the repos mounted in docker-compose.yml's volumes section
#    The defaults are ~/repoA and ~/repoB — change as needed

# 5. Build the image
docker compose build

# 6. Start the container (runs in the background)
docker compose up -d
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
# First run goes through the OAuth device-code flow; the token is stored
# in the volume so you won't have to log in again
```

When Claude is done editing, **push from the host**:

```bash
git diff origin/main..HEAD       # Review what Claude did
git push                          # Uses your host SSH key
```

When you're not using the container you can `docker compose down`, but idle has essentially no cost, so you usually don't need to.

---

## Important gotchas

- **If `CLAUDE.md` doesn't exist, `compose up` fails immediately** (because of `create_host_path: false`). This is intentional — it prevents docker from silently mounting an empty directory in its place, where the container would start but Claude couldn't read your instructions.
- **Push happens on the host, not in the container.** There's no GitHub credential inside the container; this is a deliberate security gate, not a bug.
- **Conversation history is keyed by cwd.** Different subdirectories of the same repo are treated as different projects with separate histories — get into the habit of launching `claude` from the repo root.
- **`HOST_UID` / `HOST_GID` must be exported in your shell.** Compose pulls these into the build args; if they're missing, every `docker compose` command fails immediately. This is the defense against silent ownership mismatch — bind-mounted files would otherwise end up with the wrong owner, host-side git would get blocked by `safe.directory`, and editing would need sudo. Run `./setup.sh` to see the export lines to add.
- **Strongly recommended: disable git hooks globally on the host**: `git config --global core.hooksPath /dev/null`. `setup.sh` warns you if this isn't set. See [`DESIGN.md`](./DESIGN.md#git-hooks) for the reasoning.

---

## Updating user instructions

```bash
cd ~/my_claude
vim CLAUDE.md
git commit -am "update rule"
git push

# Sessions that are already running won't see the new version immediately.
# Claude only reloads CLAUDE.md when a new session starts.
```

---

## Resetting state

```bash
# Force re-authentication and wipe all conversation history
docker volume rm my_claude_claude-data
```

---

For full design rationale, see [`DESIGN.md`](./DESIGN.md).
