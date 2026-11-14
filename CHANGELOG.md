# Changelog

All notable changes to **ForeverSuite** and **ForeverSuite_GJBridge** are documented in this file.

## [0.3.0] - 2026-11-12

### Synced (`FS-UPSTREAM-GJ-5236` — 2026-11-14)
- **GodJohnson Upstream `v5.236` (`rev 588`, Client `1.60.1.70938`)**:
  - Updated `pinned_upstream.json` and `ForeverSuite_GJBridge` (`ns.UPSTREAM_PIN = "5.236"`, CurseForge File ID `9609539`, 21 folders, SHA-256 `900d2c532396eec4...`) and rebuilt `dist/ForeverSuite_Installer.exe` + `dist/ForeverSuite-v0.3.0.zip`.
  - Extended `scripts/sync_upstream.py` to parse 2-segment archive versions (`GodJohnson-5.236.zip`) directly and auto-detect target WoW Forever client builds (`1.60.1.70938`).

### Improved (`FS-QUEST-HUD-V2` & `FS-QUEST-HUD-V2-POLISH` — 2026-11-14)
- **High-Visibility Right-Side Quest Tracker HUD (`UI/QuestTrackerModel.lua`, `UI/QuestTracker.lua`, `Modules/Quest.lua`)**:
  - 3-tier visual hierarchy (`GameFontNormal` group/quest headers vs `GameFontHighlightSmall` objective sub-rows) with `1px` crisp drop shadows preserved across `SetFontObject` transitions, `340px` width, `22px` row height, `3px`/`4px` semantic left accent bars, and `2px` objective guide rails.
  - Right-aligned quest progress summary badges (`c/m`, `완료`, `실패`, `[아이템]`) and 100% KS X 1001 Korean WoW (`koKR`) font glyph compatibility (`●`, `×`, `▶`, `◆`, `▷`, `·`).
  - Automatic combat backdrop semi-transparency (`PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED`, toggleable via `/fs quest fade`) and `0.45s` golden row highlight flash upon objective progress/completion increments.

### Added (`P0` · `P1` · `P2` Full Upgrade — `FS-V030-FULL-UPGRADE`)
- **Settings Panel (`UI/SettingsPanel.lua`, `UI/Framework.lua`, `Core/ProfileManager.lua`)**:
  - Idempotent `_G.UISpecialFrames` registration (`ESC` closes `/fs`, never duplicates across opens or `/reload`).
  - 3 mutually exclusive tabs: `[모듈 · 세부설정]`, `[GJ 브리지 상태]` (live `ForeverSuite_GJBridge` status & ownership inspector), and `[골드 원장]` (session revenue/expense breakdown + reset button).
  - Per-module detail drawer exposing all configurable `ProfileManager` boolean keys (including `autoRepair`, `useGuildRepair`, `autoSellJunk`, `fastAutoLoot`, `applyQoLCVars`, `autoAccept`, `autoTurnIn`, `doubleClickFishing`, `fishingSoundBoost`, `lowHealthAlert`, `showCoordsOnWorldMap`, `enableWaySlash`, `hudUnlocked`, and Quest/Inventory/Economy toggles) with live runtime sync and read-only schema rollback protection.
  - Dynamic version banner (`v0.3.0 · 1.60.1 (16001)`) derived from TOC metadata + `GetBuildInfo()`.
- **Quest Tracker UX & Combat-Safe Item Pool (`UI/QuestTracker.lua`, `UI/QuestLogCollector.lua`, `UI/DefaultTrackerSync.lua`)**:
  - `Ctrl+LeftClick` opens quest details via combat-safe fallback chain (`QuestMapFrame_OpenToQuestDetails` → `QuestMapFrame_ShowQuestDetails` → `ToggleQuestLog` + `C_QuestLog.SetSelectedQuest`).
  - `Alt+LeftClick` (or `Shift+LeftClick` while a chat editbox is focused) inserts quest hyperlinks (`GetQuestLink`); `Shift+LeftClick` without chat focus toggles quest watch.
  - Hovering truncated `objective` rows displays full objective text + quest title in `GameTooltip`.
  - `[잠금]` pill button (`quest.trackerLocked`) and `/fs quest lock` freeze drag positioning while keeping row clicks active.
  - Pooled `SecureActionButtonTemplate` quest item buttons (`ForeverSuiteQuestItemBtn1..6`) strictly parented & anchored to `UIParent` and synchronized via `CombatQueue:RunOrDefer` (`0` taint / `0` `ADDON_ACTION_BLOCKED` in combat).
- **9-Class Buff & Weapon Enchant Audit + Cursor Coordinates (`Modules/Combat.lua`, `Modules/Map.lua`)**:
  - Expanded out-of-combat buff check across all 9 Classic classes (`MAGE`, `PRIEST`, `WARRIOR`, `DRUID`, `PALADIN`, `SHAMAN`, `WARLOCK`, `HUNTER`, `ROGUE`) using spell-family group variants + `GetWeaponEnchantInfo` for `ROGUE`/`SHAMAN`, with unlearned/resting/mounted/taxi/secret suppression.
  - Added WorldMap normalized cursor coordinates alongside player coordinates (`플레이어: X, Y  |  커서: X, Y`).
- **Inventory, Merchant & Profession Enhancements (`Modules/Inventory.lua`, `Modules/Utility.lua`, `Modules/Profession.lua`, `Modules/Economy.lua`)**:
  - Stack vendor value (`묶음 판매가(xN)`) for bag/slot stacks `N >= 2`, `[판매 보호됨]` tooltip badge, and duplicate-line guard (`NumLines`).
  - `/fs protect <아이템링크|itemID|list>` protection manager and `/fs sell` manual 12-item safe batch command with residual count notice when >12 grey items remain.
  - `classID == 7` (Trade Goods / fish) gather yield vs general loot separation with lossless async item-cache (`nil`) reconciliation and party loot filtering.
  - `/fs move` (`reset`) unified HUD unlock/drag/persistence for `ForeverSuiteBagHUD` and `ForeverSuiteHealthAlertFrame`, plus live `Economy` session gold ledger tooltip on `ForeverSuiteBagHUD` hover.
- **Architecture & Build Pipeline (`Core/MoneyLedgerQueue.lua`, `scripts/sync_upstream.py`, `scripts/package_release.py`)**:
  - Split `Core/Init.lua` (`Core/MoneyLedgerQueue.lua`) and `UI/QuestTracker.lua` (`UI/QuestLogCollector.lua`, `UI/DefaultTrackerSync.lua`), keeping all `UI/*.lua` modules under 700 lines with standardized `--` module contract headers across all 18 Lua files.
  - Hardened `sync_upstream.py` to preserve `patch_zip_url`/`patch_zip_sha256`, enforce `--expected-sha256` fail-closed before mutating pins, unwrap single-wrapper archives, write JSON atomically, and share `resolve_default_extract_dir` (`--print-extract-dir`) with `deploy_mac.sh`.

## [0.2.0] - 2026-11-10

### Added
- Regional (`ZONE`, current zone pinned first) and difficulty-tier (`LEVEL`) on-screen Quest Tracker HUD (`UI/QuestTrackerModel.lua`, `UI/QuestTracker.lua`).
- Upstream pin synced to `GodJohnson v5.0.213` (revision `565`, 21 folders) with personalized quest sound (`dingdong`) override in `ForeverSuite_GJBridge`.

## [0.1.0] - 2026-11-05

### Added
- Initial 3-Tier architecture (`GodJohnson` read-only base + `ForeverSuite` fault-isolated suite + `ForeverSuite_GJBridge` single-owner arbitrator) and deterministic Windows PE32+ 1-click installer (`ForeverSuite_Installer.exe`).
