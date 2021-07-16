# [ANY] Movement Recorder
Records usercmds and plays them back. Saves to `sourcemod/data/recordings`.
Intended for personal use, not a polished release, expect issues.

## Commands

- `rec_start <recording name>` - Start recording
- `rec_stop` - Stop recording
- `rec_play <recording name>` - Play back a record
- `rec_botplay <recording name>` - Play back a record on a free bot
- `rec_playstop` - Stop playing back a record
- `rec_skip <frame count>` - While in playback, skip X frames forcefully (might cause desync)
- `rec_playextend` - Play back a recording at 15x speed and last 100 frames at normal speed. When playback ends, start a new recording that will include the original frames. Saves as `<originalname>_ex.txt`

## Convars

`rec_debug` - Console verbose while recording/playing back
