#!/bin/bash
# =============================================================================
# voice-memos — Auto-transcribe Apple Voice Memos
#
# Watches for new Voice Memos (recorded on iPhone, Apple Watch, or Mac),
# transcribes them locally using whisper.cpp, and appends the text to
# the current weekly note under "## Notes & Captures".
#
# Usage:
#   ./transcribe-memos.sh           # Process new memos once and exit
#   ./transcribe-memos.sh --watch   # Watch for new memos continuously
#   ./transcribe-memos.sh --all     # Reprocess ALL memos (ignores state file)
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

# Where Apple stores Voice Memos (same for all macOS users)
MEMOS_DIR="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

# Defaults (overridden by config file)
OUTPUT_DIR="$HOME/Brain/Calendar/Weekly"
OUTPUT_TAG="#voice-memo"
OUTPUT_TIMESTAMP=true
OUTPUT_DURATION=true
LANGUAGE="auto"
WHISPER_MODEL="$HOME/.local/share/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin"
WHISPER_CMD="/opt/homebrew/bin/whisper-cli"

# State file — tracks which memos have already been transcribed
STATE_DIR="$HOME/.local/share/voice-memos"
STATE_FILE="$STATE_DIR/processed.txt"

# Temp directory for WAV conversion
TMP_DIR="/tmp/voice-memos-transcribe"

# Load user config (overrides defaults above)
CONFIG_FILE="${VOICE_MEMOS_CONFIG:-$HOME/.config/voice-memos/config}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --- Setup -------------------------------------------------------------------

mkdir -p "$STATE_DIR" "$TMP_DIR" "$OUTPUT_DIR"
touch "$STATE_FILE"

# --- Helper functions --------------------------------------------------------

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# Get recordings by scanning .m4a files directly (no DB dependency).
# Filenames follow pattern: YYYYMMDD HHMMSS[-UUID].m4a
# Returns: filename|datetime|duration (one line per recording)
get_recordings() {
    log "Scanning for .m4a files..."

    # Use ls + grep instead of glob — avoids sandbox/permission issues with
    # LaunchAgents accessing iCloud-synced files in Group Containers
    ls "$MEMOS_DIR" 2>/dev/null | grep '\.m4a$' | sort | while IFS= read -r fname; do
        local m4a="$MEMOS_DIR/$fname"

        # Parse date/time from filename: "20260320 174404-A60B3B5A.m4a" or "20260309 083408.m4a"
        local datepart timepart
        datepart="${fname%% *}"                          # 20260320
        timepart="${fname#* }"                           # 174404-A60B3B5A.m4a or 083408.m4a
        timepart="${timepart%%[-.]*}"                    # 174404 or 083408

        # Format as YYYY-MM-DD HH:MM:SS
        local ymd="${datepart:0:4}-${datepart:4:2}-${datepart:6:2}"
        local hms="${timepart:0:2}:${timepart:2:2}:${timepart:4:2}"

        # Get duration from file using afinfo (macOS built-in)
        local dur
        dur=$(afinfo "$m4a" 2>/dev/null | awk '/estimated duration/{print $3}')
        dur="${dur:-0}"

        echo "${fname}|${ymd} ${hms}|${dur}"
    done
}

# Check if a memo has already been processed
is_processed() {
    local filename="$1"
    grep -qxF "$filename" "$STATE_FILE" 2>/dev/null
}

# Mark a memo as processed
mark_processed() {
    local filename="$1"
    echo "$filename" >> "$STATE_FILE"
}

# Convert .m4a to 16kHz mono WAV (what whisper.cpp expects)
convert_to_wav() {
    local input="$1"
    local output="$2"
    afconvert "$input" "$output" -d LEI16 -f WAVE -c 1 -r 16000 2>/dev/null
}

# Transcribe a WAV file using whisper.cpp
# For long recordings (>4min), processes in chunks to avoid repetition loops.
# Returns the transcript text (no timestamps)
transcribe() {
    local wav_file="$1"
    local duration_secs="${2:-0}"
    local chunk_ms=240000      # 4 minutes per chunk
    local overlap_ms=10000     # 10s overlap to avoid cutting mid-sentence

    duration_secs="${duration_secs%.*}"  # drop decimal

    # Short recordings: single pass (no chunking needed)
    if (( duration_secs < 270 )); then
        "$WHISPER_CMD" \
            -m "$WHISPER_MODEL" \
            -f "$wav_file" \
            --no-timestamps \
            -l "$LANGUAGE" \
            2>/dev/null \
        | sed 's/^[[:space:]]*//'
        return
    fi

    # Long recordings: process in chunks with overlap
    log "Long recording (${duration_secs}s) — chunking to avoid repetition loops"
    local total_ms=$(( duration_secs * 1000 ))
    local offset=0
    local all_text=""

    while (( offset < total_ms )); do
        local chunk_text
        chunk_text=$("$WHISPER_CMD" \
            -m "$WHISPER_MODEL" \
            -f "$wav_file" \
            --no-timestamps \
            -l "$LANGUAGE" \
            -ot "$offset" \
            -d "$chunk_ms" \
            2>/dev/null \
        | sed 's/^[[:space:]]*//')

        if [[ -n "$chunk_text" ]]; then
            if [[ -n "$all_text" ]]; then
                # Deduplicate overlap: drop first line of new chunk if it matches last line of previous
                local last_line
                last_line=$(echo "$all_text" | tail -1)
                local first_line
                first_line=$(echo "$chunk_text" | head -1)
                if [[ "$last_line" == "$first_line" ]]; then
                    chunk_text=$(echo "$chunk_text" | tail -n +2)
                fi
                all_text="$all_text"$'\n'"$chunk_text"
            else
                all_text="$chunk_text"
            fi
        fi

        offset=$(( offset + chunk_ms - overlap_ms ))
    done

    echo "$all_text"
}

# Format duration (seconds) into human-readable string
format_duration() {
    local secs="${1%.*}"  # drop decimal
    if (( secs < 60 )); then
        echo "${secs}s"
    else
        local mins=$(( secs / 60 ))
        local rem=$(( secs % 60 ))
        echo "${mins}m ${rem}s"
    fi
}

# Extract date portion (YYYY-MM-DD) from the datetime string
recording_date() {
    local datetime="$1"
    echo "${datetime%% *}"
}

# Compute the weekly note filename (e.g. W15-2026) from a YYYY-MM-DD date
recording_week() {
    local ymd="$1"
    date -jf '%Y-%m-%d' "$ymd" '+W%V-%G'
}

# Resolve the weekly note path for a given date. The note must already exist
# (created by Obsidian); returns empty string and logs a warning if missing.
resolve_weekly_note() {
    local ymd="$1"
    local week_name
    week_name=$(recording_week "$ymd")
    local note_path="$OUTPUT_DIR/${week_name}.md"

    if [[ ! -f "$note_path" ]]; then
        log "WARNING: Weekly note not found: $note_path"
        echo ""
        return 1
    fi

    echo "$note_path"
}

# Append a transcript under "## Notes & Captures" in the weekly note.
# Inserts before the next ## heading so other sections aren't displaced.
append_transcript() {
    local note_path="$1"
    local time="$2"
    local duration="$3"
    local transcript="$4"

    # Join multiline transcripts into one line
    local oneline
    oneline=$(echo "$transcript" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

    # Build output line from config
    local line=""
    [[ -n "$OUTPUT_TAG" ]] && line="$OUTPUT_TAG "
    [[ "$OUTPUT_TIMESTAMP" == "true" ]] && line="${line}${time} / "
    [[ "$OUTPUT_DURATION" == "true" ]] && line="${line}${duration} / "
    line="${line}${oneline}"

    # Find the "## Notes & Captures" section and insert before the next ## heading
    local section_line next_heading_line total_lines
    section_line=$(grep -n '^## Notes & Captures' "$note_path" | head -1 | cut -d: -f1)

    if [[ -z "$section_line" ]]; then
        log "WARNING: '## Notes & Captures' not found in $note_path — appending to end"
        printf '\n%s\n' "$line" >> "$note_path"
        return
    fi

    total_lines=$(wc -l < "$note_path")

    # Find the next ## heading after the section header
    next_heading_line=$(tail -n +"$((section_line + 1))" "$note_path" \
        | grep -n '^## ' | head -1 | cut -d: -f1)

    if [[ -n "$next_heading_line" ]]; then
        # Convert relative line number to absolute
        local insert_at=$(( section_line + next_heading_line ))
        # Split file and reassemble with the new line inserted
        # (safer than sed -i with arbitrary transcript text)
        local tmp="$TMP_DIR/_weekly_note_insert.md"
        { head -n "$((insert_at - 1))" "$note_path"
          printf '%s\n\n' "$line"
          tail -n +"$insert_at" "$note_path"
        } > "$tmp"
        mv "$tmp" "$note_path"
    else
        # No subsequent heading — append to end of file
        printf '\n%s\n' "$line" >> "$note_path"
    fi
}

# --- Main processing ---------------------------------------------------------

process_new_memos() {
    local skip_state="${1:-false}"
    local count=0
    local recordings
    recordings=$(get_recordings)

    if [[ -z "$recordings" ]]; then
        log "No recordings found."
        return
    fi

    while IFS='|' read -r filename datetime duration; do
        # Skip if already processed (unless --all flag)
        if [[ "$skip_state" != "true" ]] && is_processed "$filename"; then
            continue
        fi

        local memo_path="$MEMOS_DIR/$filename"

        # Skip if file doesn't exist (might have been deleted)
        if [[ ! -f "$memo_path" ]]; then
            log "Skipping $filename — file not found"
            mark_processed "$filename"
            continue
        fi

        log "Processing: $filename ($(format_duration "$duration"))"

        # Convert to WAV
        local wav_path="$TMP_DIR/$(basename "$filename" .m4a).wav"
        if ! convert_to_wav "$memo_path" "$wav_path"; then
            log "ERROR: Failed to convert $filename to WAV"
            continue
        fi

        # Transcribe (pass duration so long recordings get chunked)
        log "Transcribing..."
        local transcript
        transcript=$(transcribe "$wav_path" "$duration")

        # Clean up temp WAV
        rm -f "$wav_path"

        if [[ -z "$transcript" ]]; then
            log "WARNING: Empty transcript for $filename"
            mark_processed "$filename"
            continue
        fi

        # Get the date this was recorded and find the weekly note
        local rec_date
        rec_date=$(recording_date "$datetime")
        local rec_time="${datetime##* }"  # just the HH:MM:SS part

        local note_path
        note_path=$(resolve_weekly_note "$rec_date")

        if [[ -z "$note_path" ]]; then
            log "Skipping $filename — no weekly note for $rec_date"
            continue
        fi

        # Append to weekly note under ## Notes & Captures
        local week_name
        week_name=$(recording_week "$rec_date")
        append_transcript "$note_path" "$rec_time" "$(format_duration "$duration")" "$transcript"
        log "Appended to ${week_name}.md"

        # Mark as processed
        mark_processed "$filename"
        count=$((count + 1))

    done <<< "$recordings"

    if (( count == 0 )); then
        log "No new memos to process."
    else
        log "Done — processed $count memo(s)."
    fi
}

# --- Entry point -------------------------------------------------------------

# Verify dependencies exist
if [[ ! -f "$WHISPER_MODEL" ]]; then
    echo "ERROR: Whisper model not found at $WHISPER_MODEL"
    echo "Run install.sh or download manually:"
    echo "  curl -L -o \"$WHISPER_MODEL\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
    exit 1
fi

if [[ ! -x "$WHISPER_CMD" ]]; then
    echo "ERROR: whisper-cli not found at $WHISPER_CMD"
    echo "Install with: brew install whisper-cpp"
    exit 1
fi

if [[ ! -d "$MEMOS_DIR" ]]; then
    echo "ERROR: Voice Memos directory not found at $MEMOS_DIR"
    echo "This tool requires macOS with the Voice Memos app."
    exit 1
fi

case "${1:-}" in
    --watch)
        log "Watching for new Voice Memos... (Ctrl+C to stop)"
        # Process any pending memos first
        process_new_memos

        # Then watch for new .m4a files (requires fswatch: brew install fswatch)
        if ! command -v fswatch &>/dev/null; then
            echo "ERROR: fswatch not found. Install with: brew install fswatch"
            exit 1
        fi
        fswatch -0 -e ".*" -i "\\.m4a$" "$MEMOS_DIR" | while IFS= read -r -d '' _event; do
            sleep 3
            process_new_memos
        done
        ;;
    --all)
        log "Reprocessing ALL memos..."
        process_new_memos true
        ;;
    --help|-h)
        echo "Usage: $(basename "$0") [--watch|--all|--help]"
        echo ""
        echo "  (no args)  Process new memos once and exit"
        echo "  --watch    Watch for new memos continuously (requires fswatch)"
        echo "  --all      Reprocess all memos (ignore state file)"
        echo "  --help     Show this help"
        ;;
    *)
        # Wait for Voice Memos app to finish syncing and writing files
        # WatchPaths fires on first folder change, but .m4a may not be fully written yet
        sleep 10
        process_new_memos

        # Retry once after another delay — catches slow iCloud syncs
        sleep 30
        process_new_memos
        ;;
esac
