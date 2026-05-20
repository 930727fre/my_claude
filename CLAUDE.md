# User Instructions

## Editing behavior

"Delete X" means actually remove it — don't rewrite it as a "kept for reason Y" note (e.g. "✅ X kept because..."). If you're unsure whether to delete entirely or replace with something else, ask first instead of compromising with a "kept" annotation.

## Git

- Don't add `Co-Authored-By` trailer to commit messages
- Pre-commit flow: `git status` → `git diff` → `git add .` → `git commit`. Use `git add .` rather than listing individual files (the prior status + diff already covered review, so nothing unintended gets staged)

## Instruction clarification

When you receive ambiguous or terse instructions, either say "I'm reading this as X, proceeding" or ask one quick clarifying question — don't guess and execute.

## Memory management

Never write project-level memory into `<project>/.claude/CLAUDE.md` or `<project>/CLAUDE.md` (pollutes the codebase and forces gitignore work for every repo). All project-level memory goes in `~/.claude/projects/<path>/memory/`.

## Coding agent and .env

Don't suggest `.env` for passing config to docker compose or other tools — the coding agent reads `.env` into context (any secrets inside leak to the LLM provider), and it's easy to forget gitignoring.

Use instead: hardcode non-secret values directly in the config file; for secrets, manage them in Bitwarden and manually export into the current shell when needed (PowerShell `$env:X="..."` / bash `export X=...`). Don't write to shell rc, don't persist across sessions.

Exception (defensive mechanism): if forgetting to set a value would silently break things downstream rather than fail loudly, prefer a required env var using compose's `${VAR:?error}` syntax over hardcoding — the failure happens immediately at compose parse time. Pair with a setup script that prints the export command.

## Markdown lists

Use numbered lists only when order genuinely matters (steps, priority). For independent parallel items use `-` bullets — avoids renumbering on insertion/deletion and keeps diffs clean.

## Language for file edits

All edits Claude makes to files (code, comments, docs, configs) are in English. Conversation language follows whatever I'm using.

## Container environment

You're running inside a docker container connected to the shared external network `my_network`. Services on `my_network` are reachable by container name (e.g., `curl http://service-name:port`). When you add new services during development, attach them to `my_network` so you can reach them from here.

You run as a non-root user with no sudo, no host filesystem outside the bind mounts (no `~/.ssh`, `~/.aws`, etc.), and no GitHub credentials — you can `git commit` (under fake identity "Claude (container)") but `git push` will fail; pushes happen on the host. Outbound internet is unrestricted.

(Unless I explicitly say you're not in docker.)
