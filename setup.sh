#!/usr/bin/env bash
echo "Add to your shell rc (.bashrc / .zshrc):"
echo
echo "  export HOST_UID=$(id -u)"
echo "  export HOST_GID=$(id -g)"
echo
echo "Then 'source' the rc file (or open a new shell) before running docker compose."
echo "If these aren't exported, 'docker compose' commands will fail with a clear error."
echo

current_hooks_path=$(git config --global --get core.hooksPath 2>/dev/null || true)
if [ "$current_hooks_path" = "/dev/null" ]; then
    echo "Git hooks: globally disabled (good)."
else
    echo "WARNING: global git hooks are NOT disabled."
    echo "  Run: git config --global core.hooksPath /dev/null"
    echo "  See DESIGN.md#git-hooks for why this matters."
fi
