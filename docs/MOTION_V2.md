# Virgo Music V2 — Motion Fidelity

This version prioritizes the movement language observed in the supplied 85.844s / 25fps reference recording.

## Motion changes
- Parent/detail navigation now moves the incoming page from the right while the previous route receives a subtle left parallax.
- Back navigation reverses the same stack motion.
- Home/Search/Library/Settings are controlled by a `PageController`, so switching tabs is a real horizontal page movement instead of an `IndexedStack` replacement.
- Mini-player artwork and full-player artwork share a Hero (`player-art`) for physical expansion.
- Album rail artwork shares a Hero with Album Detail.
- Queue and song menus use a bottom-entering slide + fade with a dark scrim.
- Play/pause uses scale + icon crossfade.
- Touch targets have a short 0.965 press scale.
- Full-player artwork/background crossfades when the track changes, with blur remaining continuous.
- Horizontal recommendation rails and vertical pages use real scroll physics.

## Tuned motion constants
- Page enter: 300ms, easeOutCubic
- Page reverse: 270ms, easeInCubic
- Tab movement: 300ms, easeOutCubic
- Queue/menu entrance: 310ms, easeOutCubic
- Micro press: 90ms
- Player icon transition: 150–170ms
- Artwork/background crossfade: 360–420ms
