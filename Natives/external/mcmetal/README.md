# mcmetal

iOS build of mcopt's native Metal lib. From https://github.com/noahdunnagan/mcopt (`metal/src/main/native`, commit 7b1d0fb49b4aa03f0a8ebd31a42f93c5fa1cbc6c, 0.3.0-alpha.2), Apache-2.0, LICENSE and NOTICE are theirs.

The mod ships a macOS-only libmcmetal.dylib, so `make dep_mcmetal` builds this for iOS and `hooked_dlopen` in main_hook.m gives the mod this one instead.

Only change from upstream is the `TARGET_OS_OSX` bits in mcmetal.m (CADisplayLink instead of CVDisplayLink, no displaySyncEnabled on iOS).

Has to match the mcopt jar's version. For a newer mcopt, copy its native folder over this and redo the mcmetal.m change.
