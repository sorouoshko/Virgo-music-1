# Virgo Music V6

Merge of `Virgo_Music_Reconstruction_V4_FUNCTIONAL` (real playback engine ideas) and `Virgo_Music_V5`
(UI structure), restyled to match the two Elderbrook / Innerlight EP mockups and the screen recording.
Reference images and motion notes are in `docs/`.

## What changed vs V5
**Design (from mockups)**
- Now Playing: art fades into the background, circular chevron / more buttons, left-aligned title,
  wavy progress with thumb bar, three big rounded transport buttons (wide play/pause), "Up next" strip
  with queue + lyrics icons.
- Album page: centered rounded cover, title / artist / year, connected button group
  (shuffle · Play · save-check), numbered track rows, current track highlighted with equalizer icon.
- Mini player: wavy progress line under the text, rounded pause button, skip-next.
- Floating pill nav with the active tab expanding into a tonal pill with label.
- Dynamic colour: accent / tonal colours are derived from the current artwork
  (`ColorScheme.fromImageProvider`) – lavender for Elderbrook, cyan for NEFFEX, etc.
- Bundled demo cover `innerlight.jpg` cropped from the mockup, plus the Innerlight EP demo tracks.

**Functionality (fixes & additions)**
- Nested navigator: mini player and nav stay visible on album / artist / list pages (as in the mockup).
- Real play queue (`queue`, `qIndex`) – tapping a song plays its list; next / previous / auto-advance
  follow the queue; shuffle & repeat honoured; previous restarts the song if >3 s in.
- Queue sheet: jump to any item, **Shuffle** and **Clear** with the snackbar **Undo** seen in the recording.
- Song menu actions now work: Like, Play next, Add to queue, Shuffle what's left, Save queue as playlist, Clear queue.
- Playlists (persisted), History (persisted), saved albums (persisted), likes (persisted).
- Library counts are real (were hard-coded); Albums / Artists / Playlists / History tiles open real pages.
- Search: starts empty (was pre-filled), AND-matching, and the Songs / Albums / Artists / Playlists tabs work.
- Fixed duplicate `Hero` tags on Home rails (would throw when opening an album from a repeated item).
- Fixed division-by-zero when a local file reports duration 0; duration now follows `just_audio`.
- Fixed `play()` being awaited (it only completes when playback ends).
- Sheets use their own context so Back / dismiss pops the right route.
- Android back button: pops detail pages, then returns to Home, then exits.

## Run
1. `flutter create .` in this folder (generates the platform folders).
2. Add the permissions from `ANDROID_SETUP.md`.
3. `flutter pub get && flutter run`

> Note: the Flutter SDK was not available where this was generated, so the code could not be compiled
> or run here. If `flutter analyze` reports anything, send me the message and I'll fix it.

---
## خلاصه (فارسی)
نسخهٔ V6 ادغام V4 و V5 است که ظاهرش مطابق دو موکاپ Elderbrook و ویدیوی ضبط‌شده بازطراحی شده و
ایرادهای V5 (لیست پخش واقعی، تعداد‌های ثابت، Hero تکراری، جستجو، منوها و …) رفع شده است.
