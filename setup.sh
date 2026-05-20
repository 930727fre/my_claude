#!/usr/bin/env bash
echo "Your host UID: $(id -u)"
echo "Your host GID: $(id -g)"
echo
echo "If these aren't 1000:1000, edit docker-compose.yml's USER_UID / USER_GID to match."
