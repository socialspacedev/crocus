# A Certain Sound

A minimal, reliable DJ deck for the radio show *A Certain Sound* — built to do one
job well: play short **groups** of songs that crossfade into each other, then stop
so you can back-announce.

It deliberately does *less* than Apple Music or a club DJ app. No browsing, no
clutter, no network mid-show — just local audio files, played cleanly.

## The core idea: groups

A **group** is 2–3 songs that play, crossfade between each other, and then the
music **stops** — your cue to talk. You build a **rundown** of groups for the
episode, then trigger them one at a time.

## Features

- **Import** files or whole folders (mp3, m4a, wav, aiff, flac, …). Owned/downloaded
  Apple Music tracks are real files and work directly.
- **Crossfade** between songs in a group (equal-power, adjustable 0–12s).
- **Auto-stop** at the end of each group for back-announcing.
- **Fade to Talk** — slowly fade the current song out (5–90s) so you can talk over
  a long outro.
- **Trim** per song — set custom start/end points to skip long intros/outros.
- **Big countdown** to when the music stops — readable across the desk.
- **Show identity** — name, number, and date, saved automatically.

## Hotkeys

| Key | Action |
|-----|--------|
| `Space` | Play / Pause |
| `⌘ →` | Skip to next song in group |
| `⌘ ↩` | Play next group |
| `⌘ ⇧ F` | Fade to Talk |
| `⌘ .` | Stop |
| `⌘ N` | New Show |
| `⌘ O` | Import Music |

## Build & run

Requires the Xcode Command Line Tools (Swift 6+). No full Xcode needed.

```bash
./build.sh release        # build optimized .app and launch it
./build.sh                # fast debug build and launch
./build.sh release nolaunch
```

The app is assembled at `dist/A Certain Sound.app` — drag it to `/Applications`
once you're happy with it.

## Data

Your library, rundown, and settings are saved to:

```
~/Library/Application Support/A Certain Sound/
```

## Notes

- Apple Music **streaming-catalog** tracks are DRM-protected and can't be crossfaded
  or trimmed by any app — use downloaded/owned files for the show.
- Built as a Swift Package that compiles into a native macOS app bundle.
