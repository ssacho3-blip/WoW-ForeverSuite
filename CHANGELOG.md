# Changelog

All notable changes to **ForeverSuite** and **ForeverSuite_GJBridge** are documented in this file.

## [0.3.3] - 2026-11-17

### Hardened (`FS-V033-AUDIT-FIX` — `Claude Opus 5.5` Audit & `DeepSeek` Review)
- **Fail-Closed Nameplate CVar & Module State Safety (`Core/ProfileManager.lua`, `Modules/Combat.lua`)**:
  - Enforced `ProfileManager:CanWrite()` at `ApplyTemporaryCVar` entry and inside the deferred `CombatQueue` preset closure, removing unrecorded `SafeSetCVar` fallbacks.
  - Guarded `/fs nameplate on|off` against disabled/yielded `Combat` module state and aligned status output with actual runtime outcomes (external addon yield, combat deferral, or unsupported CVar failure).
  - Removed user-toggleable `nameplateShowEnemies` / `nameplateShowAll` from `NAMEPLATE_CVAR_PRESET` so player `V` / `Shift-V` toggles persist across reloads, and cleaned legacy snapshots (`LEGACY_NAMEPLATE_CVARS`) on external yield.
- **GJBridge Schema & Guard Parity (`ForeverSuite_GJBridge/State.lua`, `ForeverSuite_GJBridge/Bridge.lua`)**:
  - Replaced duplicated schema cap constant with dynamic `ResolveSupportedFsSchema()` referencing `FS.ProfileManager.SCHEMA_VERSION` and harmonized `FS.IsFeatureYielded` / `FS.GetFeatureYieldOwner` function guards.
- **Automated Release & Mailing Pipeline (`scripts/release.py`, `scripts/notify_release.py`, `.github/workflows/release.yml`)**:
  - Added version-parity bumper, verified HTTP 200 + SHA-256 download gate, idempotent sent ledger, and Gmail OAuth / SMTP release mailing automation with PII-free test coverage.

## [0.3.2] - 2026-11-16

### Added (`FS-INTEGRATE-2026-ADDONS-V032`)
- **Zero-Taint Nameplate Readability & Stacking Preset (`Modules/Combat.lua`, `Core/ProfileManager.lua`, `UI/SettingsPanel.lua`)**:
  - Added `combat.enhanceNameplates` (`ApplyTemporaryCVar` / `RestoreTemporaryCVar` backed up in `pendingCVarRestores` and deferred safely via `CombatQueue:RunOrDefer`) configuring verified `1.60.1` CVars (`nameplateShowEnemies=1`, `nameplateShowEnemyMinions=1`, `nameplateShowAll=1`, `nameplateMotion=1`, `nameplateMaxDistance=41`, `nameplateSelectedScale=1.2`).
  - Automatically yields and restores original CVars if external nameplate addons (`Platynator`, `Plater`, `Kui_Nameplates`, `TidyPlates_ThreatPlates`) are loaded, plus `/fs nameplate [on|off|status]`.
- **Forever Expansion Quest Badge (`UI/QuestLogCollector.lua`, `UI/QuestTrackerModel.lua`)**:
  - Queries `C_QuestLog.GetQuestExpansion(qid)` (with `info.expansionID` fallback) and displays `|cff2dd4bf[∞ 포에버]|r` in `QuestTracker` for non-vanilla Forever expansion quests (`expansionID >= 1`).
- **Layer & Instance Diagnostic (`Modules/Map.lua`, `UI/SettingsPanel.lua`)**:
  - Added `Map.ExtractZoneLayerFromGUID` (with `ns.IsSecret` guard) and `/fs layer` to inspect current `ZoneUID`, `InstanceID`, `ServerID`, and instance state from `target`/`mouseover`/`npc` GUIDs.

## [0.3.1] - 2026-11-15

### Upgraded (`FS-V031-OPUS-FABLE-CONSENSUS` — `Claude Opus 5.5` × `Claude Fable 5.2` Synthesis)
- **Client `1.60.1.70938` TOC & `C_AddOns` Metadata Alignment (`ForeverSuite.toc`, `ForeverSuite_GJBridge.toc`, `Core/Init.lua`)**:
  - Aligned `## Interface: 16001, 120105` with upstream `GodJohnson v5.236`, eliminating retired `11701` header drift.
  - Preferred `C_AddOns.GetAddOnMetadata` with safe `_G.GetAddOnMetadata` fallback in `Core/Init.lua` and synced `tests/binary_api_manifest.py` + `tests/wow_forever_mock.py` to build `1.60.1.70938` (`TOC 16001`).
- **Zero-SV-Mutation `ForeverSuite_GJBridge` & `ProfileShare` Purity (`ForeverSuite_GJBridge/Bridge.lua`)**:
  - Replaced all `_fsgj*` flags on `GJCompanion`, frames, and `GodJohnsonCompanionDB` with private weak-key tables (`__mode = "k"`) and `_G.ForeverSuiteDB.gjBridge` (`tradeNotifySeeded`, `starterLootSeeded`), guaranteeing 100% clean `ProfileShare.lua:282` validation.
  - Added lossless one-time migration of legacy `tradeManager404._fsgjUserInitialized` preserving existing user `notify` preferences while scrubbing `GodJohnsonCompanionDB`.
  - Wrapped `C.ApplyAuthorPreset` with pre/post snapshots (`notify`, `starterLoot`) that restore personal overrides and re-run `C.CommitSettings()` + `C.RefreshQuestAnnounce()` + `ns.SyncOwnership()` strictly when `ApplyAuthorPreset` returns `true`.
  - Switched `questAnnounce` personalization to pure render/playback interception (`C.QuestAnnounce.Format` plain prefix check `"[갓존슨]"` → `"[포에버]"`, `NotificationSoundNames` label remap, `PlayNotificationSound` remap to `"dingdong"`) without mutating `ExtraSchemas` or saved templates, and removed unintended `libraryBooksAccess471` initialization.
  - Updated `C.BuildHome404` wrapper for `v5.236` (`Home404.lua:12-37`): swaps child `ChannelLogo` region via `GetRegions()`, rewrites `setupReminder` & `notice`, forwards return tuples, and re-propagates upstream errors via `error(err, 0)`. Removed dead `BuildYouTubeButton`, `vitalAlerts`, `BorderApply`, and `RefreshUtilities` hooks.
- **Granular 6-Key Single-Owner Arbitration (`Modules/Quest.lua`, `UI/SettingsPanel.lua`, `ForeverSuite_GJBridge/Bridge.lua`)**:
  - Split monolithic `"questAuto"` into independent `"questAutoAccept"` (`GJ automation.accept`) and `"questAutoTurnIn"` (`GJ automation.complete`) ownership keys across `Quest.lua`, `Bridge.lua`, and `SettingsPanel.lua`.
- **Bridge-Aware Economy Gold Ledger (`Modules/Economy.lua`, `Core/MoneyLedgerQueue.lua`, `Modules/Utility.lua`, `Modules/Quest.lua`)**:
  - Installed `hooksecurefunc` attribution hooks on `RepairAllItems`, `C_Container.UseContainerItem` (guarded by `IsMerchantContextOpen()` and `target == nil`), and `GetQuestReward` with `_fs*ArmedAt` deduplication and `3.0s` max TTL so `Economy` accurately classifies `REPAIR`, `VENDOR_SELL`, and `QUEST` deltas even when `ForeverSuite` yields automation to `GodJohnsonGoldBorder` or when the player clicks manually, without misclassifying negative vendor purchases or party loot gold.
- **Full-Tree `folder_sha256` Upstream Pin Verification & Dynamic Release Versioning (`scripts/sync_upstream.py`, `scripts/deploy_mac.sh`, `scripts/build_win_exe.py`, `scripts/package_release.py`, `pinned_upstream.json`)**:
  - Added deterministic Merkle-style `folder_sha256` across every file in all 21 `GodJohnson*` folders, enforced fail-closed in `sync_upstream.py --verify-dir` and `deploy_mac.sh`.
  - Eliminated hardcoded version strings in `package_release.py` and `build_win_exe.py` by reading `0.3.1` dynamically from `ForeverSuite/ForeverSuite.toc`.

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
