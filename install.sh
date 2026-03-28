#!/bin/bash
# =============================================================================
# voice-memos installer
# Installs dependencies, downloads the whisper model, sets up config,
# and installs a LaunchAgent for automatic transcription.
# =============================================================================

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/voice-memos"
CONFIG_FILE="$CONFIG_DIR/config"
DATA_DIR="$HOME/.local/share/voice-memos"
MODEL_DIR="$HOME/.local/share/whisper-cpp/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
PLIST_NAME="com.voice-memos.transcriber"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "voice-memos installer"
echo "====================="
echo ""

# --- Check macOS -------------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: voice-memos requires macOS."
    exit 1
fi

# --- Check Homebrew ----------------------------------------------------------

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required. Install from https://brew.sh"
    exit 1
fi

# --- Install whisper-cpp -----------------------------------------------------

if ! command -v whisper-cli &>/dev/null; then
    echo "Installing whisper-cpp..."
    brew install whisper-cpp
else
    echo "whisper-cpp already installed."
fi

# --- Download model ----------------------------------------------------------

if [[ -f "$MODEL_FILE" ]]; then
    echo "Whisper model already downloaded."
else
    echo "Downloading whisper model (547 MB)..."
    mkdir -p "$MODEL_DIR"
    curl -L -o "$MODEL_FILE" "$MODEL_URL"
    echo "Model downloaded."
fi

# --- Create config -----------------------------------------------------------

mkdir -p "$CONFIG_DIR" "$DATA_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config already exists at $CONFIG_FILE — skipping."
else
    echo ""
    read -rp "Where should transcripts be saved? (e.g., ~/Notes/Daily): " output_dir
    output_dir="${output_dir/#\~/$HOME}"

    if [[ -z "$output_dir" ]]; then
        output_dir="$HOME/Notes"
    fi

    mkdir -p "$output_dir"

    # Ask about language
    echo ""
    echo "Language options: auto (detect), en, es, ru, de, fr, ja, zh, etc."
    read -rp "Whisper language [auto]: " lang
    lang="${lang:-auto}"

    cat > "$CONFIG_FILE" <<EOF
# voice-memos configuration
# See config.example for all options.

OUTPUT_DIR="$output_dir"
LANGUAGE="$lang"
EOF

    echo "Config saved to $CONFIG_FILE"
fi

# --- Install LaunchAgent -----------------------------------------------------

echo ""
echo "Installing LaunchAgent..."

# Unload existing agent if present
launchctl list | grep -q "$PLIST_NAME" 2>/dev/null && \
    launchctl unload "$PLIST_DEST" 2>/dev/null || true

# Generate plist from template
sed \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$INSTALL_DIR/com.voice-memos.plist.template" > "$PLIST_DEST"

# Load the agent
launchctl load "$PLIST_DEST"
echo "LaunchAgent installed and loaded."

# --- Make script executable --------------------------------------------------

chmod +x "$INSTALL_DIR/transcribe-memos.sh"

# --- Done --------------------------------------------------------------------

echo ""
echo "================================================================"
echo "Installation complete!"
echo ""
echo "  Config:      $CONFIG_FILE"
echo "  Transcripts: $(grep OUTPUT_DIR "$CONFIG_FILE" | head -1 | cut -d'"' -f2)"
echo "  Log:         $DATA_DIR/transcribe.log"
echo ""
echo "IMPORTANT: For the LaunchAgent to access Voice Memos, you must"
echo "grant Full Disk Access to /bin/bash:"
echo ""
echo "  System Settings > Privacy & Security > Full Disk Access"
echo "  Click +, press Cmd+Shift+G, type /bin/bash, click Open"
echo ""
echo "To test manually:  $INSTALL_DIR/transcribe-memos.sh --all"
echo "To watch live:     $INSTALL_DIR/transcribe-memos.sh --watch"
echo "================================================================"
