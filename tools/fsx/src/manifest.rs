use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub fn verified_c_apis() -> &'static HashSet<&'static str> {
    static SET: OnceLock<HashSet<&'static str>> = OnceLock::new();
    SET.get_or_init(|| {
        HashSet::from([
            "C_AddOns.DoesAddOnExist",
            "C_AddOns.GetAddOnMetadata",
            "C_AddOns.IsAddOnLoaded",
            "C_AddOns.LoadAddOn",
            "C_AddOnProfiler.GetAddOnMetric",
            "C_AddOnProfiler.IsEnabled",
            "C_ChatInfo.InChatMessagingLockdown",
            "C_ChatInfo.RegisterAddonMessagePrefix",
            "C_ChatInfo.SendAddonMessage",
            "C_ChatInfo.SendChatMessage",
            "C_Container.GetContainerItemID",
            "C_Container.GetContainerItemInfo",
            "C_Container.GetContainerNumFreeSlots",
            "C_Container.GetContainerNumSlots",
            "C_Container.SortBags",
            "C_Container.UseContainerItem",
            "C_CVar.GetCVar",
            "C_CVar.SetCVar",
            "C_DeathInfo.GetCorpseMapPosition",
            "C_DurationUtil.CreateDurationTextBinding",
            "C_EditMode.ConvertLayoutInfoToString",
            "C_EditMode.ConvertStringToLayoutInfo",
            "C_EditMode.GetLayouts",
            "C_EditMode.SaveLayouts",
            "C_EditMode.SetActiveLayout",
            "C_FriendList.GetFriendInfoByIndex",
            "C_FriendList.GetNumFriends",
            "C_Item.GetDetailedItemLevelInfo",
            "C_Item.GetItemCount",
            "C_Item.GetItemInfo",
            "C_Item.GetItemInfoInstant",
            "C_Item.PickupItem",
            "C_Item.RequestLoadItemDataByID",
            "C_Map.CanSetUserWaypointOnMap",
            "C_Map.ClearUserWaypoint",
            "C_Map.GetBestMapForUnit",
            "C_Map.GetMapInfo",
            "C_Map.GetMapRectOnMap",
            "C_Map.GetPlayerMapPosition",
            "C_Map.GetUserWaypoint",
            "C_Map.SetUserWaypoint",
            "C_MapExplorationInfo.GetExploredAreaIDsAtPosition",
            "C_MapExplorationInfo.GetExploredMapTextures",
            "C_Minimap.GetNumTrackingTypes",
            "C_Minimap.GetTrackingInfo",
            "C_Minimap.SetTracking",
            "C_QuestLog.AddQuestWatch",
            "C_QuestLog.GetDistanceSqToQuest",
            "C_QuestLog.GetHeaderIndexForQuest",
            "C_QuestLog.GetInfo",
            "C_QuestLog.GetLogIndexForQuestID",
            "C_QuestLog.GetNextWaypoint",
            "C_QuestLog.GetNextWaypointForMap",
            "C_QuestLog.GetNextWaypointText",
            "C_QuestLog.GetNumQuestLogEntries",
            "C_QuestLog.GetNumQuestWatches",
            "C_QuestLog.GetQuestDifficultyLevel",
            "C_QuestLog.GetQuestExpansion",
            "C_QuestLog.GetQuestIDForQuestWatchIndex",
            "C_QuestLog.GetQuestObjectives",
            "C_QuestLog.GetQuestTagInfo",
            "C_QuestLog.GetQuestWatchType",
            "C_QuestLog.GetQuestsOnMap",
            "C_QuestLog.GetTitleForQuestID",
            "C_QuestLog.IsComplete",
            "C_QuestLog.IsOnMap",
            "C_QuestLog.IsQuestFlaggedCompleted",
            "C_QuestLog.ReadyForTurnIn",
            "C_QuestLog.RemoveQuestWatch",
            "C_QuestLog.SetSelectedQuest",
            "C_Spell.GetSpellCooldown",
            "C_Spell.GetSpellCooldownDuration",
            "C_Spell.GetSpellInfo",
            "C_Spell.IsSpellInRange",
            "C_Spell.IsSpellKnown",
            "C_Spell.PickupSpell",
            "C_SuperTrack.GetSuperTrackedQuestID",
            "C_SuperTrack.SetSuperTrackedQuestID",
            "C_SuperTrack.SetSuperTrackedUserWaypoint",
            "C_Timer.After",
            "C_Timer.NewTicker",
            "C_UnitAuras.GetAuraApplicationDisplayCount",
            "C_UnitAuras.GetAuraDataByIndex",
            "C_UnitAuras.GetAuraDuration",
            "C_UnitAuras.GetPlayerAuraBySpellID",
        ])
    })
}

pub fn forbidden_legacy_apis() -> &'static [&'static str] {
    &[
        "GetContainerNumSlots",
        "GetContainerNumFreeSlots",
        "GetContainerItemInfo",
        "UseContainerItem",
        "GetSpellInfo",
        "UnitBuff",
        "UnitDebuff",
        "UnitAura",
        "IsAddOnLoaded",
        "GetAddOnInfo",
        "InterfaceOptions_AddCategory",
        "UIDropDownMenu_Initialize",
        "UIDropDownMenu_CreateInfo",
    ]
}

pub fn forbidden_combat_apis() -> &'static [&'static str] {
    &[
        "CastSpellByName",
        "CastSpellByID",
        "CastSpell",
        "TargetUnit",
        "TargetNearestEnemy",
        "UseAction",
        "RunMacroText",
        "RunMacro",
        "AttackTarget",
    ]
}

#[derive(Debug)]
pub struct TocManifest {
    pub addon_name: String,
    pub version: Option<String>,
    pub interfaces: Vec<String>,
    pub load_on_demand: bool,
    pub files: Vec<PathBuf>,
}

pub fn parse_toc(addon_dir: &Path) -> Result<TocManifest> {
    let addon_name = addon_dir
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid addon directory name")?
        .to_string();
    let toc_path = addon_dir.join(format!("{addon_name}.toc"));
    if !toc_path.is_file() {
        bail!("Missing TOC file: {}", toc_path.display());
    }
    let content = fs::read_to_string(&toc_path)
        .with_context(|| format!("Failed to read TOC: {}", toc_path.display()))?;

    let mut version: Option<String> = None;
    let mut interfaces = Vec::new();
    let mut load_on_demand = false;
    let mut files = Vec::new();

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("##") {
            let header = rest.trim();
            if let Some(val) = header.strip_prefix("Interface:") {
                for tok in val.split(',') {
                    let t = tok.trim();
                    if !t.is_empty() {
                        interfaces.push(t.to_string());
                    }
                }
            } else if let Some(val) = header.strip_prefix("Version:") {
                let v = val.trim();
                if !v.is_empty() {
                    version = Some(v.to_string());
                }
            } else if let Some(val) = header.strip_prefix("LoadOnDemand:") {
                load_on_demand = val.trim() == "1";
            }
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        let rel = line.replace('\\', "/");
        let p = PathBuf::from(&rel);
        if p.is_absolute()
            || rel.starts_with('/')
            || rel.contains(':')
            || p.components()
                .any(|c| matches!(c, std::path::Component::ParentDir | std::path::Component::RootDir | std::path::Component::Prefix(_)))
        {
            bail!("Unsafe path in {}.toc rejected: '{}'", addon_name, rel);
        }
        files.push(p);
    }

    Ok(TocManifest {
        addon_name,
        version,
        interfaces,
        load_on_demand,
        files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn rejects_parent_absolute_and_drive_paths_in_toc() -> Result<()> {
        for bad in ["../evil.lua", "/etc/passwd", "C:/Windows/win.ini", "a/../../b.lua"] {
            let dir = tempdir()?;
            let addon = dir.path().join("TestAddon");
            fs::create_dir_all(&addon)?;
            fs::write(addon.join("TestAddon.toc"), format!("## Interface: 16001\n{bad}\n"))?;
            assert!(
                parse_toc(&addon).is_err(),
                "expected TOC path '{bad}' to be rejected"
            );
        }
        Ok(())
    }
}
