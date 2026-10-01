# voice-memos

Auto-transcribe Apple Voice Memos and save to your notes. Records on iPhone, Apple Watch, or Mac — transcripts appear in your weekly notes automatically.

## How it works

1. You record a voice memo on any Apple device
2. iCloud syncs it to your Mac (usually within 30-120 seconds)
3. A LaunchAgent detects the new file and runs the transcription script
4. The script converts the audio to WAV, transcribes it with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and appends the text to the end of the current weekly note, between `---` lines

Each transcript is a single line inserted into your weekly note (e.g. `W15-2026.md`):

```
#voice-memo 14:32:08 / 1m 23s / Pick up groceries on the way home, also need to call the dentist.
```

The tag, timestamp, and duration are configurable. Weekly notes must already exist (e.g. created by an Obsidian template).

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon recommended (transcription is ~10x faster than Intel)
- [Homebrew](https://brew.sh)
- Apple Voice Memos app (pre-installed on macOS)

## Install

```bash
git clone https://github.com/ashamne/voice-memos.git
cd voice-memos
./install.sh
```

The installer will:
- Install whisper-cpp via Homebrew
- Download the whisper model (547 MB, one-time)
- Ask where to save transcripts
- Install and start a LaunchAgent that runs automatically

**Important:** After installing, grant Full Disk Access to `/bin/bash` so the LaunchAgent can read Voice Memos:

> System Settings > Privacy & Security > Full Disk Access > click **+** > press **Cmd+Shift+G** > type `/bin/bash` > click Open

## Configuration

Config file: `~/.config/voice-memos/config`

| Setting | Default | Description |
|---------|---------|-------------|
| `OUTPUT_DIR` | `~/Brain/Calendar/Weekly` | Directory containing weekly notes (`W{nn}-{YYYY}.md`) |
| `OUTPUT_TAG` | `#voice-memo` | Tag prepended to each line (set `""` to disable) |
| `OUTPUT_TIMESTAMP` | `true` | Include recording time (HH:MM:SS) |
| `OUTPUT_DURATION` | `true` | Include recording duration |
| `LANGUAGE` | `auto` | Whisper language (`auto`, `en`, `es`, `ru`, etc.) |
| `WHISPER_MODEL` | `~/.local/share/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin` | Path to whisper model |
| `WHISPER_CMD` | `/opt/homebrew/bin/whisper-cli` | Path to whisper-cli binary |

See `config.example` for a full annotated config.

## Usage

The LaunchAgent runs automatically — you shouldn't need to do anything after setup. It triggers on:
- New files appearing in the Voice Memos folder
- Every 30 minutes (as a safety net for slow iCloud syncs)

Manual commands:

```bash
# Process any new memos right now
./transcribe-memos.sh

# Reprocess all memos (ignoring state)
./transcribe-memos.sh --all

# Watch mode — react to new files in real time (requires fswatch)
./transcribe-memos.sh --watch
```

## How transcription works

- Audio is converted from .m4a (AAC) to 16kHz mono WAV using macOS built-in `afconvert`
- Transcription uses whisper.cpp with the `large-v3-turbo` model (quantized to q5_0)
- Short recordings (<4.5 min): single-pass transcription
- Long recordings (>4.5 min): automatically chunked into 4-minute segments with 10-second overlap to prevent whisper repetition loops
- Typical speed on M-series Macs: ~1-2 seconds for a 30-second memo

## Uninstall

```bash
./uninstall.sh
```

Removes the LaunchAgent and optionally cleans up config, state, and model files. Your transcripts are never touched.

## License

MIT
