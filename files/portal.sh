#!/bin/bash
# Session portal terminal (ttyd). No basic-auth: reachable only within the
# owner's private single-user tailnet, which is the security boundary.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
for i in $(seq 1 60); do TSIP="$(tailscale ip -4 2>/dev/null | head -1)"; [ -n "$TSIP" ] && break; sleep 2; done
[ -n "$TSIP" ] || exit 1
exec ttyd -p 7681 -i "$TSIP" -W -a \
  -t titleFixed="Session" -t 'theme={"background":"#0f0e0d"}' -t fontSize=15 \
  bash "$HOME/.claude-launcher/bin/portal-attach.sh"
