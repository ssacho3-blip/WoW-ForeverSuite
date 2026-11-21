# Changelog

All notable changes to **ForeverSuite** and **ForeverSuite_GJBridge** are documented in this file.

## [0.5.2] - 2026-11-21

### Added (`FS-V052-BAGANATOR-WIDGETS`)
- **`Baganator` Corner Widget Bridge for GodJohnson Labels (`ForeverSuite_GJBridge/Bridge.lua`, `State.lua`, `ForeverSuite/UI/SettingsPanel.lua`)**:
  - Automatically registers two idempotent `Baganator.API.RegisterCornerWidget` overlays without modifying upstream `GodJohnsonGoldBorder` or `Baganator`:
    - `fsgj_material` (`bottom_left`): renders localized profession material labels (`요리`, `약초`, `가죽`, `광석`, `천`, `생선`, `마부`, `재료`, etc.) using GodJohnson's `BagMaterialMatch` and configured `reagentColors` / `UIFontPath` (11pt `OUTLINE`).
    - `fsgj_badge` (`top_right`): renders `다크문`, `평판`, `책`, and `버프` consumable/event badges via `DarkmoonGoods`, `BagReputationItem`, `BagLibraryBookInfo471`, and `BagBuffItem`.
- **One-Time `Auctionator` Auto-Scan Seed (`ForeverSuite_GJBridge/Bridge.lua`)**:
  - Seeds `Auctionator` `autoscan_2 = true` and `replicate_scan_3 = true` once on `PLAYER_LOGIN` (persisted via `ForeverSuiteDB.gjBridge.auctionatorAutoscanSeeded`) so Auction House price databases refresh automatically while respecting subsequent user preference changes (`163 passed`).

## [0.5.1] - 2026-11-21

### Added & Fixed (`FS-V051-EXTERNAL-COEXISTENCE`)
- **External Specialist Addon Coexistence (`ForeverSuite_GJBridge/Bridge.lua`, `State.lua`, `Branding.lua`, `ForeverSuite/UI/SettingsPanel.lua`)**:
  - Added `ReconcileExternalCoexistence(C)` to automatically yield overlapping `GodJohnsonGoldBorder` features without modifying upstream files: `auctionHelper` (`enabled`/`tooltips`/`autoScan`) yields to `Auctionator`, `enemyNameplates` (`enabled`/`replaceNative`) yields to `Platynator`/`Plater`/`Kui_Nameplates`/`TidyPlates_ThreatPlates` (with combat-safe `PLAYER_REGEN_ENABLED` refresh deferral), and `altInventory.tooltips`/`bankMaterials.tooltips` yield to `Syndicator`/`Baganator`.
  - Preserves coexistence across `PLAYER_LOGIN`, late `ADDON_LOADED`, `/fsgj sync`, and `ApplyAuthorPreset`, with re-entrancy guards and strict future-schema read-only protection.
- **Zero-Duplicate Item Tooltips (`ForeverSuite/Core/Init.lua`, `Modules/Inventory.lua`, `ForeverSuite_GJBridge/Bridge.lua`)**:
  - Added `tooltipVendorPrice` (`Auctionator`) and `tooltipItemLevel` (`GodJohnsonGoldBorder`) `FeatureYield` arbitration so vendor price and item-level lines never duplicate while `[판매 보호됨]` badges and `/fs cheap` remain active (`162 passed`).

## [0.5.0] - 2026-11-21

### Added & Hardened (`FS-V050-SMART-QOL`)
- **Low-Bag Auto-Cheap Notice (`ForeverSuite/Modules/Inventory.lua`)**:
  - Automatically emits a single non-spamming chat line (`가방 여유 N칸 — 최저가 추천: ... | 전체 보기: /fs cheap`) on `BAG_UPDATE_DELAYED` whenever free bag slots drop to `<= 2` (edge-triggered with 60s cooldown), including full coexistence when `Baganator` yields `bagHud` and fail-closed silence on incomplete/`C_Secrets` scans.
- **Combat-Safe UI Scale Command (`/fs scale [0.64~1.00 | reset]`) (`ForeverSuite/Core/Init.lua`, `UI/SettingsPanel.lua`)**:
  - Prints live `useUiScale` / `uiScale` state, applies validated scale bounds (`0.64..1.00`) or resets to Blizzard auto-scaling (`useUiScale=0`) through `CombatQueue:RunOrDefer` with readback verification so MacBook Pro Retina and Mac Studio displays can switch scales with one command.
- **4th Level-Up Event Ordering Guard (`ForeverSuite/Modules/Utility.lua`)**:
  - Hardened `SyncSessionXP()` wait condition to defer once whenever `lvl == lastLevel + 1` and `xp == lastXP` even if `maxXP` already updated before `UnitXP` wrapped (`159 passed`).

## [0.4.0] - 2026-11-21

### Added (`FS-V040-CHEAP-XP`)
- **Lowest-Value Bag Guide (`/fs cheap [1~10]`, alias `/fs junk`) (`ForeverSuite/Modules/Inventory.lua`, `UI/SettingsPanel.lua`)**:
  - Scans bags `0..4` with full `pcall` + `C_Secrets` + item-cache fail-closed guards and ranks unprotected, non-quest Poor/Common sellable items by lowest total stack vendor value (`sellPrice * stackCount`, Poor before Common tie-break) so players know which single slot loses the least gold when bags are full.
  - Guidance-only (zero `DeleteCursorItem` / auto-sell calls); rejects non-positive limits cleanly and flags uncached `C_Item.GetItemInfo == nil` slots as incomplete.
- **Session XP/Hour & Level-Up ETA Tracker (`/fs xp [reset]` + BagHUD Tooltip) (`ForeverSuite/Modules/Utility.lua`, `Modules/Inventory.lua`)**:
  - Tracks session XP gained across `PLAYER_XP_UPDATE` and `PLAYER_LEVEL_UP` with full classic/forever event-ordering resilience (`pendingLevelUp` + bounded `waitCount`, zero stall or double-count across level rollovers), rested XP readout, max-level detection, `C_Secrets` gap resync without fabricated deltas, and Zero Fabricated Status (`—` before XP gain or `< 1s` elapsed).
  - Surfaces live `세션 XP/시간` in the BagHUD tooltip when enabled and adds manifest `patch_zip_url` version parity test (`156 passed`).

## [0.3.9] - 2026-11-21

### Hardened (`FS-PREEMPTIVE-AUDIT-V039`)
- **Zero-Taint `GameTooltip` & Fail-Closed Bag Capacity (`ForeverSuite/Modules/Inventory.lua`)**:
  - Replaced direct `_fs*` field mutations on Blizzard's global `GameTooltip` frame with module-local weak-key tables (`__mode = "k"`), preventing tooltip taint propagation in WoW Forever `1.60.1`.
  - Wrapped `C_Container.GetContainerNumSlots` / `GetContainerNumFreeSlots` in `pcall` + `ns.IsSecret` guards, returning an incomplete scan (`nil, nil, true` -> `가방: —`) whenever any bag is unreadable instead of fabricating partial totals.
- **Combat-Safe & Read-Only-Safe CVar Management (`ForeverSuite/Modules/Utility.lua`, `Modules/Profession.lua`)**:
  - Routed `Utility:ApplyQoLCVars()` / `RestoreQoLCVars()` and `Profession:SyncFishingSoundBoost()` / `RestoreFishingSoundBoost()` through `CombatQueue:RunOrDefer` with strict `CanWrite()` guards, independent `Sound_SFXVolume` / `Sound_MusicVolume` recovery, and accurate return values.
- **`C_Secrets` & Weapon Enchant Reactivity (`ForeverSuite/Modules/Profession.lua`, `Modules/Quest.lua`, `Modules/Combat.lua`)**:
  - Guarded `GetInventoryItemID`, `GetItemInfo` fishing-pole fields, `C_Minimap.GetNumTrackingTypes`, and `C_SuperTrack.GetSuperTrackedQuestID` against `SecretValue` traps.
  - Subscribed `Combat` to `WEAPON_ENCHANT_CHANGED` (`0.30s` bucket) so Shaman/Rogue weapon imbue changes refresh out-of-combat buff state immediately (`151 passed`).

## [0.3.8] - 2026-11-21

### Fixed (`FS-TEMP-ENCHANT-ICON`)
- **Weapon Enchant Buff Icon Display (`ForeverSuite/Modules/Combat.lua`, `Core/ProfileManager.lua`, `UI/SettingsPanel.lua`)**:
  - Added `combat.showTempEnchantIcon` (default `true`, toggleable in `/fs` → `Combat` detail drawer as `무기 강화 버프 아이콘 표시`) managing WoW Forever `1.60.1`'s verified `displayTemporaryEnchantIcon` CVar via `CombatQueue:RunOrDefer` without ever mutating Blizzard's `BuffFrame` (zero taint on EditMode / protected `CancelUnitBuff`), so Shaman weapon imbues (e.g., Rockbiter Weapon) and Rogue poisons display their enchant spell icon instead of the equipped weapon texture.
- **Fail-Closed CVar Verification & Combat-Safe Startup Recovery (`ForeverSuite/Core/Init.lua`, `Core/ProfileManager.lua`)**:
  - Hardened `ns.SafeSetCVar` with `applied == false` and live readback verification (`ns.CVarValuesMatch`), preserved original `pendingCVarRestores` entries on clamped client writes or failed readback, and routed `ProfileManager:RecoverPendingCVars()` through `CombatQueue:RunOrDefer("profile:recoverPendingCVars", ...)` for combat-reload safety (`150 passed`).

## [0.3.7] - 2026-11-19

### Fixed (`FS-BUFF-RANK-FIX`)
- **Out-of-Combat Class Buff False-Alarm Fix (`ForeverSuite/Modules/Combat.lua`)**:
  - Expanded `CLASS_BUFF_FAMILIES` across all 9 classes to cover all Classic/Era/Forever spell ranks and aura/blessing/shield/armor/aspect variants instead of Rank 1 spell IDs only.
  - Added a `C_Secrets`-safe `C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")` fallback scan matching both spell ID sets and cached localized spell names (`C_Spell.GetSpellInfo`) so higher ranks or custom Forever spell IDs never trigger false missing-buff alerts.
  - Accepted numeric truthy (`1`) weapon enchant flags in `GetWeaponEnchantInfo` and added 10 new DDT/regression tests in `tests/test_forever_suite.py` (`148 passed`).

## [0.3.6] - 2026-11-19

### Changed & Hardened (`FS-V036-ECOSYSTEM`)
- **Zero-Flicker Combat Default Tracker Hide (`ForeverSuite/UI/DefaultTrackerSync.lua`)**:
  - Applied unprotected `SetAlpha(0)` immediately when Blizzard shows `ObjectiveTrackerFrame`/`QuestWatchFrame` during `InCombatLockdown()` (matching Questie `6e2d15b`), preventing the default tracker from flashing over `ForeverSuiteQuestTracker` before `CombatQueue` defers `Hide()`, and restoring `SetAlpha(1)` before `Show()`.
- **Persistent Per-Quest Folding & Zone Transition Debounce (`ForeverSuite/Core/ProfileManager.lua`, `UI/QuestTracker.lua`, `Modules/Quest.lua`, `Modules/Profession.lua`)**:
  - Persisted per-quest right-click collapse state (`collapsedQuests`) across `/reload` with hierarchy + `ClearCollapsedQuests()` support.
  - Debounced `ZONE_CHANGED_NEW_AREA` through `0.30s` / `0.35s` buckets to avoid stale/empty zone strings immediately after portals (`forever-lint FL013` parity).
- **Hybrid Feature-Level Coexistence & 16001 Static Checks (`ForeverSuite/Core/Init.lua`, `ModuleManager.lua`, `Modules/*`, `tests/test_forever_suite.py`)**:
  - Added granular `FeatureYield` rules for `Plumber` (`fastLoot`), `DialogueUI` (`questAutoDialog`), `Leatrix_Maps` (`mapCoords`), `BetterBags`/`Baganator`/`Bagnon` (`bagHud`), `!KalielsTracker` (`questTrackerHud`), and `TomTom` (`way`), keeping orthogonal `/fs layer`, map coords, and `[판매 보호됨]`/vendor-price tooltips active.
  - Added `forever-lint` Forever 1.60.1 parity rules to static Lua compliance tests (`GetFrameStrata`, `WOW_PROJECT_CLASSIC`, guarded `SendChatMessage`, multiline `GetBuildInfo >= 100000`).
- **Settings Panel Search (`ForeverSuite/UI/Framework.lua`, `UI/SettingsPanel.lua`)**:
  - Added a cross-module keyword search box inside `/fs` detail settings drawer to filter options across all 7 modules without leaving the panel.

## [0.3.5] - 2026-11-19

### Fixed (`FS-QUEST-NAV-FIX`)
- **Live Special Quest Item Button Anchor (`ForeverSuite/UI/QuestTracker.lua`)**:
  - Replaced SavedVariables-only anchor math with `ResolveItemButtonAnchor()` reading live screen coordinates (`GetLeft`/`GetRight`/`GetTop`, `UIParent:GetWidth`, `GetEffectiveScale()` ratio, and `widget:GetTop`) anchored to `UIParent` `"BOTTOMLEFT"` inside `CombatQueue:RunOrDefer`, preventing item button drift under `SetClampedToScreen(true)` or mismatched `point`/`relPoint` settings while preserving headless fallback and `UIParent` isolation.
- **Quest Row Readability & Hover Tooltip (`ForeverSuite/UI/QuestTracker.lua`, `ForeverSuite/UI/QuestTrackerModel.lua`)**:
  - Stripped color codes when calculating `rightReserve` badge clearance and added `questZone` + up to 4 `questObjectives` to quest-row hover tooltips so truncated titles/objectives remain readable.
- **ForeverSuite ↔ GodJohnson Navigation Sync & `/way` Protection (`ForeverSuite_GJBridge/Bridge.lua`, `ForeverSuite/Modules/Quest.lua`, `ForeverSuite/Modules/Map.lua`)**:
  - Added `SyncExternalQuestNavigation` & `ShouldPreserveActiveNavigation` bridge hooks so left-clicking a quest in `ForeverSuiteQuestTracker` unpauses/re-syncs `GJCompanion` 3D arrow navigation without clobbering manual checkpoints or service routes.
  - Hardened `/way` (`clear`/`reset` whitespace & case trimming, overview-map fallback to player map) and preserved active `/way` or external checkpoints during `QUEST_ACCEPTED` `autoSuperTrack`.

## [0.3.4] - 2026-11-18

### Synced & Improved (`FS-UPSTREAM-GJ-5278` & `navRangeLayout`)
- **GodJohnson Upstream `v5.278` (`rev 630`, Client `1.60.1.70938`, File ID `9663720`)**:
  - Updated `pinned_upstream.json` and `ForeverSuite_GJBridge/Bridge.lua` (`ns.UPSTREAM_PIN = "5.278"`) across all 21 upstream folders with full `folder_sha256` verification, incorporating upstream quest 3D navigation arrow handoff and world map pin combat-safety fixes.
- **GJBridge Navigation Arrow & Target Range Separation (`ForeverSuite_GJBridge/State.lua`, `ForeverSuite_GJBridge/Branding.lua`, `ForeverSuite_GJBridge/Bridge.lua`)**:
  - Added one-time non-destructive overlap separation (`navRangeLayout`: nav arrow `y=0.74`, range display `y=0.36`), `/fsgj layout` manual reset, and automatic re-separation on `ApplyAuthorPreset` while respecting user drags and combat lockdown.
- **Settings Panel Bridge Tab Parity (`ForeverSuite/UI/SettingsPanel.lua`)**:
  - Updated `BuildBridgeStatusText()` to display all 7 personalization overrides including `navRangeLayout`.

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
