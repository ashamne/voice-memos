#!/bin/bash
# =============================================================================
# voice-memos uninstaller
# Removes the LaunchAgent. Optionally removes config, state, and model.
# =============================================================================

set -euo pipefail

PLIST_NAME="com.voice-memos.transcriber"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
CONFIG_DIR="$HOME/.config/voice-memos"
DATA_DIR="$HOME/.local/share/voice-memos"
MODEL_FILE="$HOME/.local/share/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin"

echo "voice-memos uninstaller"
echo "======================="
echo ""

# --- Unload and remove LaunchAgent -------------------------------------------

if [[ -f "$PLIST_DEST" ]]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm "$PLIST_DEST"
    echo "LaunchAgent removed."
else
    echo "LaunchAgent not found — skipping."
fi

# --- Optional cleanup --------------------------------------------------------

echo ""
read -rp "Remove config ($CONFIG_DIR)? [y/N]: " remove_config
if [[ "${remove_config,,}" == "y" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "Config removed."
fi

read -rp "Remove state file and logs ($DATA_DIR)? [y/N]: " remove_data
if [[ "${remove_data,,}" == "y" ]]; then
    rm -rf "$DATA_DIR"
    echo "State and logs removed."
fi

read -rp "Remove whisper model (547 MB)? [y/N]: " remove_model
if [[ "${remove_model,,}" == "y" ]]; then
    rm -f "$MODEL_FILE"
    echo "Model removed."
fi

echo ""
echo "Uninstall complete. Your transcripts were not touched."
