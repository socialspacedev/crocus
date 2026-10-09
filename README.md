# Crocus 🌱

A minimal, reliable DJ deck for radio, built for the show *Certain Sound* and
set up for any show via **Settings**. It does one job well: play short **groups**
of songs that crossfade into each other, then stop so you can back-announce.

It deliberately does *less* than Apple Music or a club DJ app. No browsing, no
clutter, no network mid-show. Just local audio files, played cleanly.

## The core idea: groups

A **group** is 2–3 songs that play, crossfade between each other, and then the
music **stops**, which is your cue to talk. You build a **rundown** of groups for the
episode, then trigger them one at a time. A big countdown shows exactly when the
music will stop, turning red and pulsing gently through the last ten seconds.

## Install

Crocus is free, and there's no paid Apple Developer certificate behind it. That
shapes the two ways in, and makes the first one genuinely the easier one.

### Build it yourself (recommended)

```bash
git clone https://github.com/socialspacedev/crocus.git && cd crocus && ./install.sh
```

That's it. The script checks for the Xcode Command Line Tools (a free Apple
download; the script says how to get them if they're missing), compiles, and
installs to `/Applications`. A minute or two the first time, seconds after that.

**Why this is the easy path, not the hard one:** macOS only quarantines software
that arrives from a browser. An app compiled on your own Mac isn't quarantined, so
it opens on a double-click with no warnings and no trip through System Settings.

Requires macOS 14 (Sonoma) or newer.

### Download the DMG instead

Grab `Crocus-x.y.z.dmg` from
[the latest release](https://github.com/socialspacedev/crocus/releases/latest) and
drag Crocus to Applications.

Because a download *is* quarantined and Crocus isn't notarised, macOS will refuse
it the first time, with "Apple could not verify Crocus is free of malware". To allow
it, once:

1. Try to open Crocus, and let it be refused
2. Open **System Settings ▸ Privacy & Security**
3. Scroll to the bottom and click **Open Anyway** next to Crocus
4. Authenticate, then confirm

It opens normally from then on. (Notarising it away would cost US$99/year, which
a free tool for a handful of radio people doesn't warrant yet.)

### Updating

`git pull && ./install.sh`. Your library, shows and settings live in Application
Support and are untouched by reinstalling.

## Development

```bash
./build.sh                 # fast debug build, then launch
./build.sh release         # optimized build, then launch
./build.sh release nolaunch
./release.sh               # build + sign + package dist/Crocus-<version>.dmg
```

`release.sh` reads its signing setup from the environment, so it works with or
without an Apple Developer account:

```bash
CROCUS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
CROCUS_NOTARY_PROFILE="crocus"   # from: xcrun notarytool store-credentials
```

With neither set it ad-hoc signs and tells you what that means for anyone
downloading the result.

## Features

- **Import** files or whole folders (mp3, m4a, wav, aiff, flac, …). Owned /
  downloaded Apple Music tracks are real files and work directly.
- **Crossfade** between songs in a group (equal-power, adjustable 0–12s).
- **Auto-stop** at the end of each group for back-announcing.
- **Fade to Talk**: duck the music to a bed level and hold it there so you can
  talk over a song; press again to bring it back up. Tunable duck time + bed level.
- **Fade Out** (`O`): take a song out early when it's running long and you didn't
  set an end marker. With another song left in the group the next song comes up
  underneath; on the last song the music fades to silence and the group ends
  normally, so the next group still cues up. The countdown shortens the moment you
  press it. Its own **Fade out** fader (2–20s) sets the length, deliberately
  separate from Crossfade: automatic transitions inside a group want to be quick,
  but deciding by hand to end a song wants a long, unhurried ride down. Adjustable
  live, so you can dial it in during the very song you're about to take out.
- **Output fader with a built-in VU**: the level is metered inside the fader's
  own groove and rises until it meets the cap, so the control marks the ceiling.
  Green through the working range, amber and red just short of the cap for a hot
  song, with a peak-hold mark. The fader trims only (100% is unity), so new shows
  start at 80% to leave somewhere to go.
- **Waveform** with draggable start/end **trim markers**: see the song's shape
  and quiet parts; the end marker can shorten the current song live.
- **Drag-and-drop** to reorder songs and to drop library songs into groups.
- **Artwork, album & year** read from the files; a per-song **note** that flows
  into the website export.
- **Edit Info**: fix a song's title / artist / album / year (hover a library row
  for the pencil, or right-click ▸ *Edit Info…*). See the tags actually embedded
  in the file, adopt them with one click, and, for **mp3** and **m4a**, write
  the corrected tags back into the file so Music / Finder agree. Edits also update
  every copy of the song already placed in the rundown. Artwork and other tags are
  preserved; the write is validated and swapped in atomically, so a failure never
  corrupts the original. FLAC/WAV can be edited in Crocus but not written back.
- **Show identity**: editable name, number, date, and theme; saved automatically.
- **Previous shows** archive: reopen any past episode.
- **Export**, four ways out of a show:
  - *Copy Running Order*: one numbered column of `Artist - Title`, no header,
    for pasting straight into the station's sheet.
  - *Copy Detailed Notes*: the episode as plain text, grouped as broadcast,
    with years and per-song notes. Raw material for writing up longer show notes.
  - *Export Markdown…*: an episode page for a static site, using the schema key
    and tag set in Settings.
  - *Export CSV…*: the columnar table (Date · Theme · # · Artist · Song).
- **Battery** readout with a low warning, and the display is **held awake** for as
  long as Crocus is open: no screensaver and no lock screen mid-show, including
  while you're back-announcing with the music stopped. Held two ways: a power
  assertion against display sleep, plus a user-activity declaration every 30s,
  because the screen saver runs on its own idle timer and the assertion alone
  doesn't stop it. Verify any time with `pmset -g assertions | grep Crocus`.

## Hotkeys

Single keys, because the keyboard is dedicated to the show. They work whenever the
window is focused, except while editing a text field (press **Esc** to leave one).

| Key | Action |
|-----|--------|
| `Space` | Play / Pause |
| `S` · `→` | Skip to next song |
| `P` · `←` | Previous song (or restart) |
| `N` · `⏎` | Play next group |
| `F` | Fade to Talk (toggle) |
| `O` | Fade out song early |
| `.` | Stop |
| `Esc` | Leave a text field / Stop |
| `⌘N` | New show |
| `⌘O` | Import music |

## Settings (⌘,)

Everything specific to *your* show, rather than to any one episode. Out of the box
Crocus is unbranded, so this is the first stop on a new installation.

| | |
|---|---|
| **Show name** | Used for new shows. Episodes already saved keep the name they were saved under. |
| **Station** | Appears in the website export's description line, e.g. "Otago Access Radio 105.4FM". Leave it empty and the station is left out of the sentence altogether. |
| **Time zone** | The zone episode dates are stamped in for the website export. Defaults to this Mac's own. |
| **Schema key / Tag** | For *Export Markdown…* only: the `_schema` value, the front-matter block holding the tracklist, and the tag added alongside `music`. Ignore these unless you publish episode pages to a static site. |
| **Page template** | The whole shape of the Markdown export. *Edit Template…* opens it; *Reset to Default* puts it back. See below. |

Stored in `~/Library/Application Support/Crocus/settings.json`, pretty-printed and
sorted, so it can be hand-edited or kept in a dotfiles repo just as easily.

### The page template

Every site wants different front matter, so *Export Markdown…* renders a template
you own rather than a shape baked into Crocus. It lives at
`~/Library/Application Support/Crocus/export-template.md` and is created with a
working default the first time you need it.

The language is three rules, because YAML front matter is line-oriented:

| | |
|---|---|
| `{{token}}` | replaced by its value |
| `{{token\|yaml}}` | the same, quoted if YAML would need it |
| `{{#tracks}}` … `{{/tracks}}` | the lines between are repeated once per song |
| `{{! … }}` | a note to yourself; never reaches the output |

Plus one rule that removes the need for conditionals: **a line whose placeholders
all come out empty is dropped**. That's why `year: {{track.year}}` simply vanishes
for a song with no year, the way hand-written front matter would.

Available placeholders (the template file lists them in its own header too):

- **Show**: `{{show.name}}` `{{show.number}}` `{{show.title}}` `{{show.theme}}`
  `{{show.description}}` `{{show.date}}` `{{show.dateLong}}` `{{show.slug}}`
  `{{show.trackCount}}` `{{show.playtime}}`
- **From Settings**: `{{station}}` `{{schemaKey}}` `{{schemaTag}}`
- **Per song**, inside `{{#tracks}}`: `{{track.n}}` `{{track.artist}}`
  `{{track.title}}` `{{track.year}}` `{{track.note}}` `{{track.album}}`
  `{{track.group}}`

## Data

Your library, rundown, previous shows, and settings are saved to:

```
~/Library/Application Support/Crocus/
```

## Notes

- Apple Music **streaming-catalog** tracks are DRM-protected and can't be
  crossfaded or trimmed by any app, so use downloaded/owned files for the show.
- **Long songs** are fine, with one thing to know. A song's trimmed audio is read
  whole into memory so its samples can be scaled for loudness matching: about
  600MB for half an hour of 44.1kHz stereo, released as soon as the song ends. The
  read happens off the main thread and the *next* song is decoded ahead of time
  while the current one plays, so neither the app nor a crossfade waits on it;
  starting a long song shows "Loading…" for a second or two first. Trimming cuts
  both the memory and the load time proportionally. The one rough edge on a very
  long track is the waveform: at ~1.6s per screen pixel across half an hour, the
  trim markers are coarse.
- Built as a Swift Package that compiles into a native macOS app bundle.
- *Crocus* is the app; *Certain Sound* is the radio show it was built for. Nothing
  about that show is hardcoded any more; it all lives in Settings (see below).
  The one deliberate exception is the migration in `AppState.migrateLegacyData`,
  which reads the old `~/Library/Application Support/A Certain Sound/` folder.
  That string is a historical path, not a name: change it and old data stops being
  found. Leave it alone even though the show has been renamed.
- Writing mp3 tags uses [ID3TagEditor](https://github.com/chicio/ID3TagEditor)
  (fetched automatically on the first build, so it needs a network connection once).
- The app icon is generated by `icon/makeicon.swift`.

## Ideas for next time

- Consolidate any pre-managed-library originals into `~/Music/Crocus/Media`.
- Optionally write tags back to **FLAC/WAV** too (needs an external tool such as
  `exiftool`, so left out for now).
