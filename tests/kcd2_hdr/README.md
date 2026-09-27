# KCD2 HDR10 compatibility quirk

KCD2 1.5.6's `r_HDROutput` callback selects `r_HDRPipeline=1` (scRGB) when
HDR is enabled and supported. Applying saved graphics settings can therefore undo
`r_HDRPipeline=2` from user.cfg. Real DLSSG requires the game's HDR10 output.

`Kcd2Hdr.cpp` changes that one selection immediate to 2 in memory when KCD2's
quirk and real DLSSG output are selected. The existing HDR support and SDR branches
remain intact. It stays applied for the session, including when FG is temporarily
disabled, to avoid changing HDR encoding during an FG toggle. Restart after changing
FG backends to return to the game's original callback. No game file is modified.

Supported WHGame.dll: PE timestamp `6a350e20`, image size `05b2d000`, callback
RVA `01dec4c0`, selection offset `80`. The complete 175-byte callback must match.
Unknown builds and callbacks modified by another mod are rejected and logged.
To support an update, inspect the callback and its CVar registration again; do not
just loosen the signature or update the timestamp.

Run `./tests/kcd2_hdr/run.ps1 -GameDll <path-to-WHGame.dll>` on Windows with VS
Build Tools. The test reads the installed DLL without loading or executing it,
checks its callback against the production signature, then executes those callback
bytes in an isolated image with mock CVar and display interfaces. It checks the
original override, patched HDR/SDR/support branches, game/backend gates, rejection
of changed builds, exact write scope, page protection and repeated initialization.

Game verification remains separate: launch normally, check the quirk log, confirm
PQ/10-bit output survives profile loading and HDR toggles, then verify actual DLSSG
interpolation and NR visibility with both NR placements. A passing callback test
does not establish frame generation or image quality in-game.
