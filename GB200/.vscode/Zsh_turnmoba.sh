#!/usr/bin/env bash
#
# Setup 'mobaxterm' command alias for Mac/Linux
# Run: source ./.vscode/Zsh_turnmoba.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFDLAB_SCRIPT="$SCRIPT_DIR/Zsh_mainsystem.sh"

# Ensure script is executable
chmod +x "$CFDLAB_SCRIPT" 2>/dev/null

# Determine shell profile
if [[ -n "$ZSH_VERSION" ]]; then
    SHELL_PROFILE="$HOME/.zshrc"
    SHELL_NAME="zsh"
elif [[ -n "$BASH_VERSION" ]]; then
    if [[ -f "$HOME/.bash_profile" ]]; then
        SHELL_PROFILE="$HOME/.bash_profile"
    else
        SHELL_PROFILE="$HOME/.bashrc"
    fi
    SHELL_NAME="bash"
else
    SHELL_PROFILE="$HOME/.profile"
    SHELL_NAME="sh"
fi

# Function code to add (uses git root detection for portability)
read -r -d '' ALIAS_CODE << 'ENDBLOCK'

# ========== MobaXterm Alias ==========
# 跨平台遠端管理工具 (Mac/Linux → bash, Windows → PowerShell)
# 用法: mobaxterm push / pull / gpus / ssh / issh / vpnfix ...
mobaxterm() {
  local script
  script="$(git rev-parse --show-toplevel 2>/dev/null)/.vscode/Zsh_mainsystem.sh"
  if [[ -x "$script" ]]; then
    "$script" "$@"
  else
    echo "[ERROR] Cannot find Zsh_mainsystem.sh (not in a git repo?)" >&2
    return 1
  fi
}
# ========== End MobaXterm Alias ==========
ENDBLOCK

# Check if already added
if grep -q "MobaXterm Alias" "$SHELL_PROFILE" 2>/dev/null; then
    echo "[INFO] 'mobaxterm' alias already exists in $SHELL_PROFILE"
    echo "       Updating to latest version..."
    # macOS sed needs '' for -i
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' '/# ========== MobaXterm Alias ==========/,/# ========== End MobaXterm Alias ==========/d' "$SHELL_PROFILE"
    else
        sed -i '/# ========== MobaXterm Alias ==========/,/# ========== End MobaXterm Alias ==========/d' "$SHELL_PROFILE"
    fi
    echo "$ALIAS_CODE" >> "$SHELL_PROFILE"
    echo "[UPDATED] 'mobaxterm' function updated in $SHELL_PROFILE"
else
    echo "$ALIAS_CODE" >> "$SHELL_PROFILE"
    echo "[SUCCESS] 'mobaxterm' function added to $SHELL_PROFILE"
fi

# Activate immediately in current session
eval "$ALIAS_CODE"

echo ""
echo "[READY] You can now use:"
echo "  mobaxterm gpus          # GPU status overview"
echo "  mobaxterm ssh 87:3      # SSH to server:node"
echo "  mobaxterm issh          # Interactive SSH menu"
echo "  mobaxterm push          # Upload to all servers"
echo "  mobaxterm pull 87       # Download from .87"
echo "  mobaxterm status        # Sync status"
echo "  mobaxterm vpnfix        # Fix VPN route"
echo "  mobaxterm help          # Full command list"
echo ""
