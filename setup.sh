#!/usr/bin/env bash
echo "Add to your shell rc (.bashrc / .zshrc):"
echo
echo "  export HOST_UID=$(id -u)"
echo "  export HOST_GID=$(id -g)"
echo
echo "Then 'source' the rc file (or open a new shell) before running docker compose."
echo "If these aren't exported, 'docker compose' commands will fail with a clear error."
