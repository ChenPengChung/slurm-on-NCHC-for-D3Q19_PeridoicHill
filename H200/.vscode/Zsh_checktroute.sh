#!/usr/bin/env bash
# Zsh_checktroute.sh — Auto-fix VPN route for cfdlab servers
# Install: cp this to ~/Library/LaunchAgents/ area (see below)
#
# This script monitors for VPN (ppp) interface changes and automatically
# adds the route 140.114.58.0/24 through the VPN tunnel.

SUBNET="140.114.58.0/24"
CHECK_INTERVAL=5  # seconds

function get_ppp_iface() {
  ifconfig 2>/dev/null | grep -o '^ppp[0-9]*' | head -1
}

function route_ok() {
  local iface
  iface="$(route -n get 140.114.58.87 2>/dev/null | awk '/interface:/{print $2}')"
  [[ "$iface" == ppp* ]]
}

function fix_route() {
  local ppp="$1"
  sudo route add -net "$SUBNET" -interface "$ppp" >/dev/null 2>&1
}

echo "[VPN-WATCHER] Started (checking every ${CHECK_INTERVAL}s)"

while true; do
  ppp="$(get_ppp_iface)"
  if [[ -n "$ppp" ]]; then
    if ! route_ok; then
      echo "[VPN-WATCHER] $(date '+%H:%M:%S') Fixing route: $SUBNET → $ppp"
      fix_route "$ppp"
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
