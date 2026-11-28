use anyhow::{bail, Context, Result};
use mlua::{ChunkMode, Lua, LuaOptions, StdLib, Table, Value};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use zip::ZipArchive;

const SHARD_SIZE: usize = 450;
const MAX_ZIP_ENTRY_BYTES: u64 = 24 * 1024 * 1024;

#[derive(Debug, Serialize)]
struct GjPackProvenance {
    addon_name: String,
    pack_id: String,
    title: String,
    source_files: Vec<String>,
    input_count: usize,
    output_count: usize,
    skipped_count: usize,
    shards: usize,
    output_sha256: String,
}

#[derive(Debug, Serialize)]
struct GjBuildManifest {
    generator: String,
    source_zip: String,
    source_zip_sha256: String,
    packs: Vec<GjPackProvenance>,
}

fn sha256_bytes(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    format!("{:x}", h.finalize())
}

fn lua_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn read_zip_lua<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    exact_path: &str,
) -> Result<Option<String>> {
    if exact_path.contains("..") || exact_path.starts_with('/') {
        bail!("Unsafe zip path rejected: {exact_path}");
    }
    let mut found_idx = None;
    for i in 0..archive.len() {
        let e = archive
            .by_index(i)
            .with_context(|| format!("Failed inspecting ZIP entry #{i}"))?;
        if e.name() == exact_path {
            if e.size() > MAX_ZIP_ENTRY_BYTES {
                bail!(
                    "ZIP entry exceeds safety cap ({} > {} bytes): {}",
                    e.size(),
                    MAX_ZIP_ENTRY_BYTES,
                    exact_path
                );
            }
            found_idx = Some(i);
            break;
        }
    }
    let Some(i) = found_idx else {
        return Ok(None);
    };
    let entry = archive.by_index(i)?;
    let mut buf = Vec::new();
    let mut limited = entry.take(MAX_ZIP_ENTRY_BYTES + 1);
    limited
        .read_to_end(&mut buf)
        .with_context(|| format!("Failed reading {exact_path}"))?;
    if buf.len() as u64 > MAX_ZIP_ENTRY_BYTES {
        bail!("ZIP entry decompressed past safety cap: {exact_path}");
    }
    if buf.starts_with(&[0x1b]) {
        bail!("Binary Lua bytecode rejected in ZIP entry: {exact_path}");
    }
    let s = String::from_utf8(buf)
        .with_context(|| format!("Non-UTF-8 Lua file in ZIP: {exact_path}"))?;
    Ok(Some(s.trim_start_matches('\u{feff}').to_string()))
}

fn create_sandboxed_lua() -> Result<Lua> {
    let lua = Lua::new_with(
        StdLib::TABLE | StdLib::STRING | StdLib::MATH,
        LuaOptions::default(),
    )
    .map_err(|e| anyhow::anyhow!("Failed to create sandboxed Lua VM: {e}"))?;
    lua.set_memory_limit(256 * 1024 * 1024)
        .map_err(|e| anyhow::anyhow!("Failed to enforce sandbox memory limit: {e}"))?;

    let g = lua.globals();
    for banned in ["dofile", "loadfile", "load", "loadstring", "require", "collectgarbage"] {
        g.set(banned, Value::Nil)
            .map_err(|e| anyhow::anyhow!("Failed stripping global '{banned}': {e}"))?;
    }

    lua.load(
        r#"
        GJCompanion = {
            Dungeons = {},
            DungeonInfo = {},
            Quests = {},
            PublicDungeonItems = {},
            PublicDungeonExtras = {},
            DungeonEntranceData4110 = {},
            DungeonPrerequisites = {},
            DungeonInside = {},
            ClassQuestWalkthrough434 = {},
            LazyDungeonRecord5089 = function(t) return t end,
        }
        "#,
    )
    .set_mode(ChunkMode::Text)
    .exec()
    .map_err(|e| anyhow::anyhow!("Sandbox init failed: {e}"))?;
    Ok(lua)
}

fn exec_zip_lua_patched<R: Read + std::io::Seek>(
    lua: &Lua,
    archive: &mut ZipArchive<R>,
    path: &str,
    required: bool,
    loaded_sources: &mut Vec<String>,
    replacements: &[(&str, &str)],
) -> Result<bool> {
    if let Some(mut src) = read_zip_lua(archive, path)? {
        for (from, to) in replacements {
            src = src.replacen(from, to, 1);
        }
        let res = lua.load(&src).set_name(path).set_mode(ChunkMode::Text).exec();
        if let Err(e) = res {
            if required {
                bail!("Sandboxed execution error in required {path}: {e}");
            }
            return Ok(false);
        }
        loaded_sources.push(path.to_string());
        Ok(true)
    } else if required {
        bail!("Required GodJohnson source file missing from ZIP: {path}");
    } else {
        Ok(false)
    }
}

fn exec_zip_lua<R: Read + std::io::Seek>(
    lua: &Lua,
    archive: &mut ZipArchive<R>,
    path: &str,
    required: bool,
    loaded_sources: &mut Vec<String>,
) -> Result<bool> {
    exec_zip_lua_patched(lua, archive, path, required, loaded_sources, &[])
}

fn serialize_lua_entry(tbl: &Table) -> Result<String> {
    let mut kv: BTreeMap<String, String> = BTreeMap::new();
    for pair in tbl.pairs::<Value, Value>() {
        let (k, v) = pair.map_err(|e| anyhow::anyhow!("{e}"))?;
        let key = match k {
            Value::String(s) => s.to_str().map_err(|e| anyhow::anyhow!("{e}"))?.to_string(),
            _ => continue,
        };
        let rendered = match v {
            Value::String(s) => {
                let st = s.to_str().map_err(|e| anyhow::anyhow!("{e}"))?;
                if st.is_empty() {
                    continue;
                }
                lua_escape(&st)
            }
            Value::Integer(n) => n.to_string(),
            Value::Number(f) => {
                if !f.is_finite() {
                    continue;
                }
                if (f - f.round()).abs() < 1e-6 && f.abs() < 1e12 {
                    format!("{}", f.round() as i64)
                } else {
                    format!("{f:.4}")
                }
            }
            Value::Boolean(b) => if b { "true" } else { "false" }.to_string(),
            _ => continue,
        };
        kv.insert(key, rendered);
    }
    let mut parts = Vec::with_capacity(kv.len());
    for (k, v) in kv {
        parts.push(format!("{k}={v}"));
    }
    Ok(format!("{{{}}}", parts.join(",")))
}

struct StagedAddon {
    stage_dir: PathBuf,
    target_dir: PathBuf,
    prev_dir: PathBuf,
}

fn stage_lod_addon(
    v2_root: &Path,
    addon_name: &str,
    toc_title: &str,
    toc_notes: &str,
    packs_data: Vec<(String, String, String, Vec<String>, usize, usize, Vec<String>)>,
) -> Result<(StagedAddon, Vec<GjPackProvenance>)> {
    let target_dir = v2_root.join(addon_name);
    let pid = std::process::id();
    let stage_dir = v2_root.join(format!(".{addon_name}.stage.{pid}"));
    let prev_dir = v2_root.join(format!(".{addon_name}.prev.{pid}"));
    if stage_dir.exists() {
        fs::remove_dir_all(&stage_dir)?;
    }
    fs::create_dir_all(&stage_dir)?;

    let mut toc_files: Vec<String> = Vec::new();
    let mut prov_out: Vec<GjPackProvenance> = Vec::new();

    for (pack_id, title, category, sources, input_count, skipped_count, serialized_entries) in packs_data {
        let output_count = serialized_entries.len();
        if output_count == 0 {
            let _ = fs::remove_dir_all(&stage_dir);
            bail!("Refusing to emit empty LoD pack '{pack_id}' in {addon_name} (input={input_count}, skipped={skipped_count})");
        }
        let total_shards = (output_count + SHARD_SIZE - 1) / SHARD_SIZE;
        let mut combined_hasher = Sha256::new();

        for shard_idx in 0..total_shards {
            let start = shard_idx * SHARD_SIZE;
            let end = std::cmp::min(output_count, start + SHARD_SIZE);
            let slice = &serialized_entries[start..end];

            let file_name = format!("Pack_{pack_id}_{:02}.lua", shard_idx + 1);
            let mut body = String::with_capacity(slice.len() * 140 + 256);
            body.push_str(&format!(
                "-- Auto-generated LoadOnDemand shard ({}/{}) by fsx data compile-gj\n",
                shard_idx + 1,
                total_shards
            ));
            body.push_str(&format!(
                "ForeverSuite_RegisterPack({}, 2, {{ title = {}, category = {}, source = \"Extracted from Local GodJohnson Backup\", license = \"Personal-Local-Only\" }}, {}, {}, {{\n",
                lua_escape(&pack_id),
                lua_escape(&title),
                lua_escape(&category),
                shard_idx + 1,
                total_shards
            ));
            for entry in slice {
                body.push_str(entry);
                body.push_str(",\n");
            }
            body.push_str("})\n");

            if body.contains("GJCompanion") || body.contains("GodJohnsonGoldBorder") {
                let _ = fs::remove_dir_all(&stage_dir);
                bail!("Forbidden legacy token leaked into {addon_name}/{file_name}");
            }
            if body.contains("table: 0x") || body.contains("function: 0x") {
                let _ = fs::remove_dir_all(&stage_dir);
                bail!("Corrupted Lua memory address leaked into {addon_name}/{file_name}");
            }
            full_moon::parse(&body).map_err(|errs| {
                let _ = fs::remove_dir_all(&stage_dir);
                anyhow::anyhow!("Generated Lua syntax error in {addon_name}/{file_name}: {errs:?}")
            })?;

            combined_hasher.update(body.as_bytes());
            fs::write(stage_dir.join(&file_name), body.as_bytes())?;
            toc_files.push(file_name);
        }

        prov_out.push(GjPackProvenance {
            addon_name: addon_name.to_string(),
            pack_id,
            title,
            source_files: sources,
            input_count,
            output_count,
            skipped_count,
            shards: total_shards,
            output_sha256: format!("{:x}", combined_hasher.finalize()),
        });
    }

    let mut toc = format!(
        "## Interface: 16001, 120105\n\
## Title: |cffd4af37Forever|rSuite · {toc_title} (LoD)\n\
## Notes: {toc_notes}\n\
## Author: Youngseo Cho (Derived from local personal archive)\n\
## Version: 4.0.0\n\
## LoadOnDemand: 1\n\
## Dependencies: ForeverSuite\n\n"
    );
    for f in &toc_files {
        toc.push_str(f);
        toc.push('\n');
    }
    fs::write(stage_dir.join(format!("{addon_name}.toc")), toc.as_bytes())?;

    Ok((
        StagedAddon {
            stage_dir,
            target_dir,
            prev_dir,
        },
        prov_out,
    ))
}

fn commit_staged_addons(staged: Vec<StagedAddon>) -> Result<()> {
    let mut swapped: Vec<(StagedAddon, bool)> = Vec::new();
    let res: Result<()> = (|| {
        for s in staged {
            if s.prev_dir.exists() {
                fs::remove_dir_all(&s.prev_dir)?;
            }
            let had_prev = s.target_dir.exists();
            if had_prev {
                fs::rename(&s.target_dir, &s.prev_dir)?;
            }
            if let Err(e) = fs::rename(&s.stage_dir, &s.target_dir) {
                if had_prev {
                    let _ = fs::rename(&s.prev_dir, &s.target_dir);
                }
                let _ = fs::remove_dir_all(&s.stage_dir);
                return Err(e.into());
            }
            swapped.push((s, had_prev));
        }
        Ok(())
    })();

    if let Err(err) = res {
        for (s, had_prev) in swapped.into_iter().rev() {
            let _ = fs::remove_dir_all(&s.target_dir);
            if had_prev {
                let _ = fs::rename(&s.prev_dir, &s.target_dir);
            }
        }
        return Err(err);
    }

    for (s, had_prev) in swapped {
        if had_prev {
            let _ = fs::remove_dir_all(&s.prev_dir);
        }
    }
    Ok(())
}

fn collect_entries_from_lua(lua: &Lua, extractor_script: &str) -> Result<(usize, usize, Vec<String>)> {
    let res: Table = lua
        .load(extractor_script)
        .set_mode(ChunkMode::Text)
        .eval()
        .map_err(|e| anyhow::anyhow!("Extractor Lua failed: {e}"))?;
    let input_count: usize = res.get("input").unwrap_or(0);
    let skipped_count: usize = res.get("skipped").unwrap_or(0);
    let rows: Table = res
        .get("rows")
        .map_err(|e| anyhow::anyhow!("Missing rows table: {e}"))?;
    let mut out = Vec::new();
    for item in rows.sequence_values::<Table>() {
        let t = item.map_err(|e| anyhow::anyhow!("{e}"))?;
        out.push(serialize_lua_entry(&t)?);
    }
    Ok((input_count, skipped_count, out))
}

pub fn compile_gj_lod_packs(zip_path: &Path, v2_root: &Path) -> Result<()> {
    let raw_zip = fs::read(zip_path)
        .with_context(|| format!("Failed to read ZIP: {}", zip_path.display()))?;
    let zip_sha = sha256_bytes(&raw_zip);

    let mut archive = ZipArchive::new(Cursor::new(&raw_zip))
        .with_context(|| format!("Invalid ZIP archive: {}", zip_path.display()))?;
    let mut all_prov: Vec<GjPackProvenance> = Vec::new();
    let mut staged_addons: Vec<StagedAddon> = Vec::new();

    let stage_res: Result<()> = (|| {
        // ---------------------------------------------------------------------
        // 1. ForeverSuite_Data_Dungeon (dungeons + dungeon_bosses + dungeon_quests + dungeon_loot)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonData.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonAlliance.lua", false, &mut src)?;
            lua.load("GJCompanion.QuestFinishLocations = GJCompanion.QuestFinishLocations or {}")
                .set_mode(ChunkMode::Text)
                .exec()
                .map_err(|e| anyhow::anyhow!("QuestFinishLocations init failed: {e}"))?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonExtra.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonGuideData.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonBlueleaf.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonGnomeregan.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonWetlands.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonDalaran468.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonReferenceUpdate.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonEntranceData4110.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/Dungeon196Data.lua", false, &mut src)?;
            lua.load("for _, d in ipairs(GJCompanion.Dungeons or {}) do if d.instance == nil then d.instance = d.key or d.name end end")
                .set_mode(ChunkMode::Text)
                .exec()
                .map_err(|e| anyhow::anyhow!("DungeonData normalization failed: {e}"))?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonPublicReference.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonLootDetails4201.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonLevel60Data4130.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/MapTransportData.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonMaps.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonLevel60Maps4130.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonDalaranMaps468.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonInterior219.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonBossPins.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonBossRouteData223.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonKrolSteps259.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonOtherSteps259.lua", false, &mut src)?;
            exec_zip_lua_patched(
                &lua,
                &mut archive,
                "GodJohnsonGoldBorder/DungeonPortrait221.lua",
                false,
                &mut src,
                &[("local appearances={", "GJCompanion.DungeonPortraits221={")],
            )?;

            let (d_in, d_skip, d_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local byKey, byInst, byTitle = {}, {}, {}
                local entByInst = {}
                for inst, ed in pairs(C.DungeonEntranceData4110 or {}) do
                    if type(ed) == "table" and type(ed.points) == "table" and ed.points[1] then
                        entByInst[inst] = ed
                    end
                end
                for _, er in ipairs(C.MapEntranceRows or {}) do
                    if type(er) == "table" and er[4] and not entByInst[er[4]] then
                        entByInst[er[4]] = { points = { { mapID = er[1], x = er[2], y = er[3], label = "던전 입구" } } }
                    end
                end
                local function normCoord(x, y)
                    if type(x) ~= "number" or type(y) ~= "number" then return nil, nil end
                    if x > 1 or y > 1 then return x / 100.0, y / 100.0 end
                    return x, y
                end
                local function cleanLevels(lv)
                    local s = tostring(lv or "")
                    s = string.gsub(s, "%s*·%s*클래식 참고", "")
                    s = string.gsub(s, "^%s+", "")
                    s = string.gsub(s, "%s+$", "")
                    return s
                end
                local function trimTrailDot(s)
                    while true do
                        local trimmed = string.gsub(s, "%s+$", "")
                        if #trimmed >= 2 and string.sub(trimmed, -2) == "·" then
                            s = string.sub(trimmed, 1, -3)
                        else
                            return trimmed
                        end
                    end
                end
                local function cleanZone(z, entNote, region, pSize)
                    local s = tostring(z or "")
                    if type(entNote) == "string" and entNote ~= "" then
                        local pos = string.find(s, entNote, 1, true)
                        if pos then
                            s = trimTrailDot(string.sub(s, 1, pos - 1))
                        end
                    end
                    if s == "" and type(region) == "string" and region ~= "" then
                        s = region .. (type(pSize) == "number" and pSize > 0 and (" · " .. tostring(pSize) .. "인") or "")
                    end
                    return s
                end
                local function isNumericKey(k)
                    return type(k) == "string" and string.match(k, "^%d+$") ~= nil
                end
                local function addDungeon(d, fallbackKey)
                    if type(d) ~= "table" or type(d.name) ~= "string" or d.name == "" then skip = skip + 1; return end
                    local key = tostring(d.key or fallbackKey or d.instance or d.name)
                    local inst = (type(d.instance) == "number") and d.instance or 0
                    local hasExplicitPartySize = type(d.partySize) == "number" and d.partySize > 0
                    local pSize = hasExplicitPartySize and d.partySize or (d.isRaid and 40 or 5)
                    local qCount = type(d.quests) == "table" and #d.quests or 0
                    local bCount = type(d.bosses) == "table" and #d.bosses or 0
                    local lvClean = cleanLevels(d.levels)
                    local ed = (inst > 0) and entByInst[inst] or nil
                    local entNote = ""
                    local mapID, nx, ny = nil, nil, nil
                    if ed and ed.points and ed.points[1] then
                        local pt = ed.points[1]
                        local tx, ty = normCoord(pt.x, pt.y)
                        if type(pt.mapID) == "number" and tx and ty and tx >= 0 and tx <= 1 and ty >= 0 and ty <= 1 then
                            mapID, nx, ny = pt.mapID, tx, ty
                            entNote = tostring(ed.instructions or pt.description or pt.label or "")
                        end
                    end
                    local rawZone = tostring(d.intro or d.region or d.levels or "")
                    local zoneClean = cleanZone(rawZone, entNote, d.region, pSize)
                    local existing = byKey[key] or (inst > 0 and byInst[inst]) or nil
                    if not existing then
                        local byT = byTitle[d.name]
                        if byT and (inst == 0 or (byT.instance or 0) == 0 or byT.instance == inst) then
                            existing = byT
                        end
                    end
                    if existing then
                        if isNumericKey(existing.id) and (not isNumericKey(key)) then
                            existing.id = key
                        end
                        if inst > 0 and (existing.instance == 0 or existing.instance == nil) then
                            existing.instance = inst
                            byInst[inst] = existing
                        end
                        if bCount > (existing.bossCount or 0) then existing.bossCount = bCount end
                        if qCount > (existing.questCount or 0) then existing.questCount = qCount end
                        if d.isRaid == true then existing.isRaid = true end
                        if hasExplicitPartySize then
                            existing.partySize = d.partySize
                        end
                        if lvClean ~= "" and (existing.levels == "" or #lvClean < #existing.levels) then
                            existing.levels = lvClean
                        end
                        if type(d.route) == "string" and #d.route > #(existing.note or "") then
                            existing.note = d.route
                        end
                        if zoneClean ~= "" and (existing.zone == "" or (#existing.zone > 60 and #zoneClean < #existing.zone)) then
                            existing.zone = zoneClean
                        end
                        if mapID and not existing.mapID then
                            existing.mapID = mapID; existing.x = nx; existing.y = ny
                        end
                        if entNote ~= "" and (not existing.entranceNote or existing.entranceNote == "" or existing.entranceNote == "던전 입구") then
                            existing.entranceNote = entNote
                        end
                        byKey[key] = existing
                        return
                    end
                    local row = {
                        id = key,
                        instance = inst,
                        title = d.name,
                        levels = lvClean,
                        faction = tostring(d.guideFaction or d.faction or "Both"),
                        isRaid = d.isRaid == true,
                        partySize = pSize,
                        zone = zoneClean,
                        note = tostring(d.route or ""),
                        questCount = qCount,
                        bossCount = bCount,
                        category = "dungeon",
                    }
                    if mapID then
                        row.mapID = mapID; row.x = nx; row.y = ny
                        row.entranceNote = entNote
                    end
                    rows[#rows+1] = row
                    byKey[key] = row
                    byTitle[d.name] = row
                    if inst > 0 then byInst[inst] = row end
                end
                for _, d in ipairs(C.Dungeons or {}) do inp = inp + 1; addDungeon(d, nil) end
                for k, d in pairs(C.DungeonInfo or {}) do inp = inp + 1; addDungeon(d, k) end
                for _, row in ipairs(rows) do
                    if row.zone == "" or (row.entranceNote and row.zone == row.entranceNote) then
                        row.zone = tostring(row.partySize or 5) .. "인" .. (row.levels ~= "" and (" · " .. row.levels) or "")
                    end
                end
                table.sort(rows, function(a,b)
                    if tostring(a.title) ~= tostring(b.title) then return tostring(a.title) < tostring(b.title) end
                    return tostring(a.id) < tostring(b.id)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (b_in, b_skip, b_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local seen = {}
                local function scanBosses(d, dKey)
                    if type(d) ~= "table" or type(d.bosses) ~= "table" then return end
                    local dName = tostring(d.name or dKey or "")
                    local inst = type(d.instance) == "number" and d.instance or 0
                    for idx, b in ipairs(d.bosses) do
                        inp = inp + 1
                        if type(b) == "table" and type(b.name) == "string" and b.name ~= "" then
                            local key = dName .. ":" .. b.name
                            if not seen[key] then
                                seen[key] = true
                                local ids = {}
                                for _, iid in ipairs(b.items or {}) do
                                    if type(iid) == "number" then ids[#ids+1] = tostring(iid) end
                                end
                                rows[#rows+1] = {
                                    dungeonKey = tostring(d.key or dKey or dName),
                                    dungeonName = dName,
                                    instance = inst,
                                    order = idx,
                                    title = b.name,
                                    npcID = type(b.npc) == "number" and b.npc or 0,
                                    itemsCsv = table.concat(ids, ","),
                                    itemCount = #ids,
                                    tip = tostring(b.tip or ""),
                                }
                            end
                        else
                            skip = skip + 1
                        end
                    end
                end
                for _, d in ipairs(C.DungeonInfo or {}) do scanBosses(d, d.key or d.instance) end
                for k, d in pairs(C.DungeonInfo or {}) do if type(k) ~= "number" then scanBosses(d, k) end end
                for _, d in ipairs(C.Dungeons or {}) do scanBosses(d, d.key) end
                table.sort(rows, function(a,b)
                    if a.dungeonName ~= b.dungeonName then return a.dungeonName < b.dungeonName end
                    if a.order ~= b.order then return a.order < b.order end
                    return a.title < b.title
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (q_in, q_skip, q_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local seen = {}
                local prereqs = C.DungeonPrerequisites or {}
                local insides = C.DungeonInside or {}
                for _, d in ipairs(C.Dungeons or {}) do
                    local dKey = tostring(d.key or d.name or "")
                    local dName = tostring(d.name or dKey)
                    for _, q in ipairs(d.quests or {}) do
                        inp = inp + 1
                        if type(q) == "table" and type(q.id) == "number" and type(q.name) == "string" then
                            local sk = dKey .. ":" .. tostring(q.id)
                            if not seen[sk] then
                                seen[sk] = true
                                local row = {
                                    dungeonKey = dKey,
                                    dungeonName = dName,
                                    questID = q.id,
                                    title = q.name,
                                    level = type(q.level) == "number" and q.level or 0,
                                    minLevel = type(q.minLevel) == "number" and q.minLevel or 0,
                                    faction = tostring(q.faction or d.guideFaction or d.faction or "Both"),
                                    npc = tostring(q.npc or ""),
                                    objective = tostring(q.objective or ""),
                                    chain = tostring(q.chain or ""),
                                    prereqID = type(prereqs[q.id]) == "number" and prereqs[q.id] or 0,
                                    inside = insides[q.id] == true,
                                }
                                if type(q.location) == "table" and type(q.location.mapID) == "number" and type(q.location.x) == "number" and type(q.location.y) == "number" then
                                    local lx, ly = q.location.x, q.location.y
                                    if lx > 1 or ly > 1 then lx, ly = lx / 100.0, ly / 100.0 end
                                    if lx >= 0 and lx <= 1 and ly >= 0 and ly <= 1 then
                                        row.mapID = q.location.mapID; row.x = lx; row.y = ly
                                    end
                                end
                                rows[#rows+1] = row
                            end
                        else
                            skip = skip + 1
                        end
                    end
                end
                table.sort(rows, function(a,b)
                    if a.dungeonName ~= b.dungeonName then return a.dungeonName < b.dungeonName end
                    if a.level ~= b.level then return a.level < b.level end
                    return a.questID < b.questID
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (l_in, l_skip, l_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local merged = {}
                local bossByItem = {}
                for _, d in ipairs(C.DungeonInfo or {}) do
                    for _, b in ipairs(d.bosses or {}) do
                        for _, iid in ipairs(b.items or {}) do
                            if type(iid) == "number" and not bossByItem[iid] then
                                bossByItem[iid] = { dungeon = d.name, boss = b.name }
                            end
                        end
                    end
                end
                for id, it in pairs(C.PublicDungeonItems or {}) do
                    if type(id) == "number" and type(it) == "table" then merged[id] = it end
                end
                for id, it in pairs(C.DungeonLootDetails4201 or {}) do
                    if type(id) == "number" and type(it) == "table" and not merged[id] then merged[id] = it end
                end
                local SLOT_TO_INV = {
                    ["머리"] = 1, ["목"] = 2, ["어깨"] = 3, ["가슴"] = 5, ["허리"] = 6,
                    ["다리"] = 7, ["발"] = 8, ["손목"] = 9, ["손"] = 10, ["손가락"] = 11,
                    ["장신구"] = 13, ["등"] = 15, ["망토"] = 15, ["주장비"] = 16, ["한손"] = 16,
                    ["한손 장비"] = 16, ["양손"] = 16, ["양손 장비"] = 16, ["보조장비"] = 17,
                    ["방패"] = 17, ["원거리"] = 18, ["원거리 장비"] = 18, ["마법봉"] = 18,
                    ["투척"] = 18, ["성물"] = 18, ["성서"] = 18,
                }
                local ids = {}
                for id in pairs(merged) do ids[#ids+1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local it = merged[id]
                    local name = type(it.name) == "string" and it.name or nil
                    if name and name ~= "" then
                        local src = bossByItem[id]
                        local slotName = type(it.slot) == "string" and it.slot or ""
                        local row = {
                            itemID = id,
                            title = name,
                            altName = type(it.altName) == "string" and it.altName or "",
                            quality = type(it.quality) == "number" and it.quality or 1,
                            itemLevel = type(it.itemLevel) == "number" and it.itemLevel or 0,
                            reqLevel = type(it.requiredLevel) == "number" and it.requiredLevel or 0,
                            slot = slotName,
                            equipSlot = SLOT_TO_INV[slotName] or 0,
                            itemType = type(it.type) == "string" and it.type or "",
                            dungeon = src and src.dungeon or "",
                            boss = src and src.boss or "",
                            zone = src and (src.dungeon .. " · " .. src.boss) or ((slotName ~= "" and slotName) or (type(it.type) == "string" and it.type or "던전 드랍")),
                        }
                        rows[#rows+1] = row
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (st_in, st_skip, st_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local qids = {}
                for qid in pairs(C.DungeonVerifiedSteps259 or {}) do
                    if type(qid) == "number" then qids[#qids+1] = qid end
                end
                table.sort(qids)
                for _, qid in ipairs(qids) do
                    inp = inp + 1
                    local s = C.DungeonVerifiedSteps259[qid]
                    if type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
                        local reqs = {}
                        for _, r in ipairs(s.requires or {}) do
                            if type(r) == "number" then reqs[#reqs+1] = tostring(r) end
                        end
                        local row = {
                            questID = qid,
                            title = s.name,
                            faction = tostring(s.faction or "Both"),
                            minLevel = type(s.minLevel) == "number" and s.minLevel or 0,
                            questLevel = type(s.questLevel) == "number" and s.questLevel or 0,
                            giver = tostring(s.giver or ""),
                            npcID = type(s.npcID) == "number" and s.npcID or 0,
                            source = tostring(s.source or s.note or ""),
                            dungeon = tostring(s.dungeon or ""),
                            requiresCsv = table.concat(reqs, ","),
                            supersededBy = type(s.supersededBy) == "number" and s.supersededBy or 0,
                        }
                        if type(s.mapID) == "number" and type(s.x) == "number" and type(s.y) == "number" then
                            local nx, ny = s.x, s.y
                            if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                            if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                                row.mapID = s.mapID; row.x = nx; row.y = ny
                            end
                        end
                        rows[#rows+1] = row
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (pt_in, pt_skip, pt_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local nids = {}
                for nid in pairs(C.DungeonPortraits221 or {}) do
                    if type(nid) == "number" then nids[#nids+1] = nid end
                end
                table.sort(nids)
                for _, nid in ipairs(nids) do
                    inp = inp + 1
                    local p = C.DungeonPortraits221[nid]
                    if type(p) == "table" and type(p[1]) == "number" then
                        rows[#rows+1] = {
                            npcID = nid,
                            displayID = p[1],
                            fileDataID = type(p[2]) == "number" and p[2] or 0,
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (mm_in, mm_skip, mm_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local labels = C.DungeonMapArtworkLabels or {}
                local bossPts = C.DungeonArtworkBossPoints or {}
                local cat = C.DungeonMapCatalog or {}
                local instIds = {}
                for inst in pairs(cat) do
                    if type(inst) == "number" then instIds[#instIds+1] = inst end
                end
                table.sort(instIds)
                local seenTex = {}
                local function formatPins(tex)
                    local pts = bossPts[tex]
                    if type(pts) ~= "table" then return "" end
                    local keys = {}
                    for k in pairs(pts) do keys[#keys+1] = tostring(k) end
                    table.sort(keys)
                    local acc = {}
                    for _, ks in ipairs(keys) do
                        local v = pts[tonumber(ks) or ks]
                        if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
                            acc[#acc+1] = ks .. ":" .. tostring(v[1]) .. ":" .. tostring(v[2])
                        end
                    end
                    return table.concat(acc, "|")
                end
                for _, inst in ipairs(instIds) do
                    local c = cat[inst]
                    if type(c) == "table" then
                        local pages = c.pages or {}
                        if #pages == 0 and type(c.texture) == "string" then
                            pages = { { name = c.name or "", texture = c.texture, extension = c.extension or "tga" } }
                        end
                        for idx, pg in ipairs(pages) do
                            inp = inp + 1
                            if type(pg) == "table" and type(pg.texture) == "string" and pg.texture ~= "" then
                                local ext = tostring(pg.extension or "tga")
                                local lbl = labels[pg.texture]
                                local title = (type(lbl) == "table" and type(lbl.title) == "string" and lbl.title) or tostring(pg.name or c.name or pg.texture)
                                seenTex[pg.texture] = true
                                rows[#rows+1] = {
                                    instance = inst,
                                    pageIndex = idx,
                                    texture = pg.texture,
                                    extension = ext,
                                    title = title,
                                    pageName = tostring(pg.name or ""),
                                    note = tostring(pg.note or ""),
                                    bossPinsCsv = formatPins(pg.texture),
                                }
                            else
                                skip = skip + 1
                            end
                        end
                    end
                end
                -- Also include standalone artwork label sheets not already in DungeonMapCatalog
                local texNames = {}
                for tex in pairs(labels) do if not seenTex[tex] then texNames[#texNames+1] = tex end end
                table.sort(texNames)
                for _, tex in ipairs(texNames) do
                    inp = inp + 1
                    local lbl = labels[tex]
                    if type(lbl) == "table" and type(lbl.title) == "string" then
                        rows[#rows+1] = {
                            instance = 0,
                            pageIndex = 1,
                            texture = tex,
                            extension = "tga",
                            title = lbl.title,
                            pageName = "",
                            note = "",
                            bossPinsCsv = formatPins(tex),
                        }
                    else
                        skip = skip + 1
                    end
                end
                -- Also include Maraudon boss route guide notes
                local mIds = {}
                for nid in pairs(C.MaraudonBossGuide311 or {}) do if type(nid) == "number" then mIds[#mIds+1] = nid end end
                table.sort(mIds)
                for _, nid in ipairs(mIds) do
                    inp = inp + 1
                    local mg = C.MaraudonBossGuide311[nid]
                    if type(mg) == "table" then
                        rows[#rows+1] = {
                            instance = 349,
                            pageIndex = 99,
                            texture = "CL_Maraudon_GJ4131",
                            extension = "tga",
                            npcID = nid,
                            title = tostring(mg.location or ""),
                            note = tostring(mg.tip or ""),
                            outside = mg.outside == true,
                        }
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut d_packs = vec![
                ("dungeons".into(), "던전 가이드 전체".into(), "dungeon".into(), src.clone(), d_in, d_skip, d_rows),
                ("dungeon_bosses".into(), "던전 보스 및 드랍 매핑".into(), "dungeon".into(), src.clone(), b_in, b_skip, b_rows),
                ("dungeon_quests".into(), "던전 퀘스트 준비 목록".into(), "dungeon".into(), src.clone(), q_in, q_skip, q_rows),
                ("dungeon_loot".into(), "던전 드랍 아이템 전체".into(), "dungeon".into(), src.clone(), l_in, l_skip, l_rows),
            ];
            if !st_rows.is_empty() {
                d_packs.push(("dungeon_steps".into(), "던전 단계별 진행 체크리스트".into(), "dungeon".into(), src.clone(), st_in, st_skip, st_rows));
            }
            if !pt_rows.is_empty() {
                d_packs.push(("dungeon_portraits".into(), "던전 보스 초상화·모델 매핑".into(), "dungeon".into(), src.clone(), pt_in, pt_skip, pt_rows));
            }
            if !mm_rows.is_empty() {
                d_packs.push(("dungeon_map_meta".into(), "던전 내부 지도·보스 핀·루트 메타".into(), "dungeon".into(), src, mm_in, mm_skip, mm_rows));
            }

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Dungeon",
                "Dungeon & Loot DB",
                "ForeverSuite LoadOnDemand 던전·보스·퀘스트·드랍·내부지도·단계별 체크리스트 전체 DB",
                d_packs,
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 2. ForeverSuite_Data_BiS (bis + real Acquisitions408 + equipSlot mapping)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonBiSData/BiSData.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonBiSData/Acquisitions408.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonBiSData/BiSQuestRewards452.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/BiSEvidence.lua", false, &mut src)?;

            let (inp, skip, rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local items = (type(C.BiSData) == "table" and type(C.BiSData.items) == "table") and C.BiSData.items or {}
                local recipes = (type(C.AcquisitionFacts408) == "table" and type(C.AcquisitionFacts408.recipes) == "table") and C.AcquisitionFacts408.recipes or {}
                local sourcesMap = (type(C.AcquisitionFacts408) == "table" and type(C.AcquisitionFacts408.sources) == "table") and C.AcquisitionFacts408.sources or {}
                local function flattenText(v)
                    if type(v) == "string" then return v end
                    if type(v) == "number" then return tostring(v) end
                    if type(v) == "table" then
                        local acc = {}
                        for _, item in ipairs(v) do
                            local s = flattenText(item)
                            if s ~= "" then acc[#acc+1] = s end
                        end
                        if #acc > 0 then return table.concat(acc, " / ") end
                        if type(v.where) == "string" and v.where ~= "" then return v.where end
                        if type(v.text) == "string" and v.text ~= "" then return v.text end
                        if type(v.name) == "string" and v.name ~= "" then return v.name end
                    end
                    return ""
                end
                local SLOT_TO_INV = {
                    ["머리"] = 1, ["목"] = 2, ["어깨"] = 3, ["가슴"] = 5, ["허리"] = 6,
                    ["다리"] = 7, ["발"] = 8, ["손목"] = 9, ["손"] = 10, ["손가락"] = 11,
                    ["장신구"] = 13, ["등"] = 15, ["망토"] = 15, ["주장비"] = 16, ["한손"] = 16,
                    ["한손 장비"] = 16, ["양손"] = 16, ["양손 장비"] = 16, ["보조장비"] = 17,
                    ["방패"] = 17, ["원거리"] = 18, ["원거리 장비"] = 18, ["마법봉"] = 18,
                    ["투척"] = 18, ["성물"] = 18, ["성서"] = 18,
                }
                local ids = {}
                for id in pairs(items) do if type(id) == "number" then ids[#ids+1] = id end end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local it = items[id]
                    if type(it) == "table" and type(it.name) == "string" and it.name ~= "" then
                        local statParts = {}
                        for _, st in ipairs(it.stats or {}) do
                            if type(st) == "table" and st.label and st.value then
                                statParts[#statParts+1] = tostring(st.label) .. " +" .. tostring(st.value)
                            end
                        end
                        for _, ef in ipairs(it.effects or {}) do
                            if type(ef) == "table" and ef.text then
                                statParts[#statParts+1] = tostring(ef.text)
                            end
                        end
                        local acqParts = {}
                        local recs = recipes[id]
                        if type(recs) == "table" then
                            for _, r in ipairs(recs) do
                                if type(r) == "table" and r.profession then
                                    local skVal = r.skill or r.skillEstimate
                                    local skStr = (skVal ~= nil) and (" " .. tostring(skVal)) or ""
                                    local srcStr = flattenText(r.source)
                                    acqParts[#acqParts+1] = "제작(" .. tostring(r.profession) .. skStr .. ")" .. (srcStr ~= "" and (": " .. srcStr) or "")
                                end
                            end
                        end
                        local srcs = sourcesMap[id]
                        if type(srcs) == "table" then
                            for _, sItem in ipairs(srcs) do
                                local stxt = flattenText(sItem)
                                if stxt ~= "" then acqParts[#acqParts+1] = stxt end
                            end
                        end
                        if type(it.obtain) == "string" and it.obtain ~= "" then acqParts[#acqParts+1] = it.obtain end
                        if type(it.dropSource) == "string" and it.dropSource ~= "" then acqParts[#acqParts+1] = it.dropSource end
                        if type(it.questName) == "string" and it.questName ~= "" then acqParts[#acqParts+1] = "퀘스트: " .. it.questName end
                        local slotName = type(it.slot) == "string" and it.slot or "장비"
                        rows[#rows+1] = {
                            itemID = id,
                            title = it.name,
                            altName = type(it.altName) == "string" and it.altName or "",
                            quality = type(it.quality) == "number" and it.quality or 1,
                            itemLevel = type(it.itemLevel) == "number" and it.itemLevel or 0,
                            reqLevel = type(it.requiredLevel) == "number" and it.requiredLevel or 0,
                            slot = slotName,
                            equipSlot = SLOT_TO_INV[slotName] or 0,
                            itemType = type(it.type) == "string" and it.type or "",
                            acq = table.concat(acqParts, " · "),
                            zone = slotName .. (type(it.itemLevel) == "number" and it.itemLevel > 0 and (" · iLvl " .. tostring(it.itemLevel)) or ""),
                            note = table.concat(statParts, " / "),
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (ev_in, ev_skip, ev_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local classes = (type(C.BiSEvidence) == "table" and type(C.BiSEvidence.classes) == "table") and C.BiSEvidence.classes or {}
                local cNames = {}
                for cls in pairs(classes) do cNames[#cNames+1] = cls end
                table.sort(cNames)
                for _, cls in ipairs(cNames) do
                    local cTbl = classes[cls]
                    if type(cTbl) == "table" and type(cTbl.specs) == "table" then
                        for _, sp in ipairs(cTbl.specs) do
                            inp = inp + 1
                            if type(sp) == "table" and type(sp.key) == "string" then
                                local prio = {}
                                for _, p in ipairs(sp.priorities or {}) do
                                    if type(p) == "string" then prio[#prio+1] = p end
                                end
                                local statNotes = {}
                                if type(sp.effects) == "table" then
                                    local sk = {}
                                    for k in pairs(sp.effects) do sk[#sk+1] = tostring(k) end
                                    table.sort(sk)
                                    for _, k in ipairs(sk) do
                                        if type(sp.effects[k]) == "string" then
                                            statNotes[#statNotes+1] = k .. ": " .. sp.effects[k]
                                        end
                                    end
                                end
                                rows[#rows+1] = {
                                    class = cls,
                                    spec = sp.key,
                                    title = tostring(sp.name or sp.key),
                                    role = tostring(sp.role or ""),
                                    summary = tostring(sp.summary or ""),
                                    priorities = table.concat(prio, " | "),
                                    statNotes = table.concat(statNotes, "\n"),
                                }
                            else
                                skip = skip + 1
                            end
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut bis_packs = vec![("bis".into(), "BiS 장비 및 획득처 전체".into(), "bis".into(), src.clone(), inp, skip, rows)];
            if !ev_rows.is_empty() {
                bis_packs.push(("bis_evidence".into(), "직업·전문화별 BiS 능력치 우선순위 가이드".into(), "bis".into(), src, ev_in, ev_skip, ev_rows));
            }
            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_BiS",
                "BiS Gear DB",
                "ForeverSuite LoadOnDemand BiS 장비·비교·전문화 가중치·획득처 전체 DB",
                bis_packs,
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 3. ForeverSuite_Data_Profession (prof_guides + professions + prof_trainers + Rogue Poison)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/ProfessionData472.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/ProfessionPracticalData5165.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/RoguePoisonCatalogue204.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/FishingDirections205.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/CookingDirections205.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonProfessionData/ProfessionMasters279.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ProfessionMaterialData.lua", false, &mut src)?;
            exec_zip_lua_patched(
                &lua,
                &mut archive,
                "GodJohnsonGoldBorder/ProfessionRecommendations419.lua",
                false,
                &mut src,
                &[("local picks={", "GJCompanion.ProfPicks419={")],
            )?;

            let (g_in, g_skip, g_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local profs = (type(C.ProfessionData472) == "table" and C.ProfessionData472.professions) or {}
                local pract = C.ProfessionPracticalData5165 or {}
                for _, p in ipairs(profs) do
                    inp = inp + 1
                    local pid = p.id
                    local pname = tostring(p.name or ("전문기술 #" .. tostring(pid or 0)))
                    local pr = pract[pid] or {}
                    local routeParts = {}
                    for _, rt in ipairs(pr.routes or {}) do
                        if type(rt) == "table" then
                            routeParts[#routeParts+1] =
                                tostring(rt.min or 1) .. "-" .. tostring(rt.max or 300) .. " " .. tostring(rt.title or "")
                                .. " | " .. tostring(rt.action or "") .. " (" .. tostring(rt.where or "") .. ")"
                        end
                    end
                    rows[#rows+1] = {
                        profID = type(pid) == "number" and pid or 0,
                        title = pname,
                        kind = tostring(p.kind or "primary"),
                        summary = tostring(pr.summary or p.summary or ""),
                        startGuide = tostring(pr.start or p.classSkillGuide or ""),
                        tips = tostring(pr.tips or ""),
                        masterGuide = tostring(p.masterGuidance279 or ""),
                        routesText = table.concat(routeParts, "\n"),
                        recipeCount = type(p.recipes) == "table" and #p.recipes or 0,
                        npcCount = type(p.npcs) == "table" and #p.npcs or 0,
                    }
                end
                table.sort(rows, function(a,b) return a.title < b.title end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (r_in, r_skip, r_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local profs = (type(C.ProfessionData472) == "table" and C.ProfessionData472.professions) or {}
                for _, p in ipairs(profs) do
                    local pname = tostring(p.name or ("전문기술 #" .. tostring(p.id or 0)))
                    for _, rec in ipairs(p.recipes or {}) do
                        inp = inp + 1
                        local rname = type(rec.name) == "string" and rec.name or nil
                        if rname and rname ~= "" then
                            local sk = type(rec.skill) == "number" and rec.skill or (type(rec.clientMinSkill) == "number" and rec.clientMinSkill or 0)
                            rows[#rows+1] = {
                                title = rname,
                                itemID = type(rec.itemID) == "number" and rec.itemID or (type(rec.craftedItemID) == "number" and rec.craftedItemID or 0),
                                spellID = type(rec.spellID) == "number" and rec.spellID or 0,
                                profID = type(p.id) == "number" and p.id or 0,
                                prof = pname,
                                skill = sk,
                                zone = pname .. " · 숙련 " .. tostring(sk),
                                note = tostring(rec.source or rec.sourceType or ""),
                            }
                        else
                            skip = skip + 1
                        end
                    end
                end
                table.sort(rows, function(a,b)
                    if a.prof ~= b.prof then return a.prof < b.prof end
                    if a.skill ~= b.skill then return a.skill < b.skill end
                    return a.title < b.title
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (t_in, t_skip, t_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local seen = {}
                local profs = (type(C.ProfessionData472) == "table" and C.ProfessionData472.professions) or {}
                for _, p in ipairs(profs) do
                    local pname = tostring(p.name or ("전문기술 #" .. tostring(p.id or 0)))
                    for _, npc in ipairs(p.npcs or {}) do
                        inp = inp + 1
                        local name = type(npc.name) == "string" and npc.name or nil
                        local mapID = type(npc.mapID) == "number" and npc.mapID or nil
                        local x = type(npc.x) == "number" and npc.x or nil
                        local y = type(npc.y) == "number" and npc.y or nil
                        if name and mapID and x and y then
                            local nx, ny = x, y
                            if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                            if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                                local key = pname .. ":" .. tostring(npc.npcID or name) .. ":" .. tostring(mapID)
                                if not seen[key] then
                                    seen[key] = true
                                    rows[#rows+1] = {
                                        title = name .. " (" .. pname .. ")",
                                        zone = tostring(npc.zone or "") .. (npc.faction and (" · " .. tostring(npc.faction)) or ""),
                                        mapID = mapID,
                                        x = nx,
                                        y = ny,
                                        profID = type(p.id) == "number" and p.id or 0,
                                        prof = pname,
                                        note = tostring(npc.note or npc.role or ""),
                                        category = "trainer",
                                    }
                                end
                            else
                                skip = skip + 1
                            end
                        else
                            skip = skip + 1
                        end
                    end
                end
                table.sort(rows, function(a,b) return a.title < b.title end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (m_in, m_skip, m_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local ids = {}
                for id in pairs(C.ProfessionMaterialData or {}) do
                    if type(id) == "number" then ids[#ids+1] = id end
                end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local rec = C.ProfessionMaterialData[id]
                    if type(rec) == "table" and type(rec[1]) == "string" then
                        rows[#rows+1] = {
                            itemID = id,
                            kind = rec[1],
                            profMask = type(rec[2]) == "number" and rec[2] or 0,
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (pr_in, pr_skip, pr_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local ids = {}
                for id in pairs(C.ProfPicks419 or {}) do
                    if type(id) == "number" then ids[#ids+1] = id end
                end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local p = C.ProfPicks419[id]
                    if type(p) == "table" and type(p.label) == "string" then
                        rows[#rows+1] = {
                            itemID = id,
                            label = p.label,
                            reason = tostring(p.reason or ""),
                            condition = tostring(p.condition or ""),
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut prof_packs = vec![
                ("prof_guides".into(), "전문기술 구간별 육성 가이드".into(), "profession".into(), src.clone(), g_in, g_skip, g_rows),
                ("professions".into(), "전문기술 제조법 전체".into(), "profession".into(), src.clone(), r_in, r_skip, r_rows),
                ("prof_trainers".into(), "전문기술 교관·대가·낚시/요리 길안내".into(), "profession".into(), src.clone(), t_in, t_skip, t_rows),
            ];
            if !m_rows.is_empty() {
                prof_packs.push(("prof_materials".into(), "전문기술 재료 역추적 인덱스".into(), "profession".into(), src.clone(), m_in, m_skip, m_rows));
            }
            if !pr_rows.is_empty() {
                prof_packs.push(("prof_recommendations".into(), "전문기술 실전 추천 품목".into(), "profession".into(), src, pr_in, pr_skip, pr_rows));
            }

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Profession",
                "Profession DB",
                "ForeverSuite LoadOnDemand 12대 전문기술(독 제조 포함) 육성 가이드·제조법·재료·추천·교관 전체 DB",
                prof_packs,
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 4. ForeverSuite_Data_Reward (rewards + merchant_crates)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonRewardData/Data416.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonRewardData/MerchantGuideData4111.lua", false, &mut src)?;

            let (inp, skip, rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local data = C.RewardCatalogData416 or {}
                local items = data.items or {}
                for _, off in ipairs(data.offers or {}) do
                    inp = inp + 1
                    local iid = type(off.itemID) == "number" and off.itemID or 0
                    local it = items[iid] or {}
                    local name = (type(it.name) == "string" and it.name ~= "") and it.name or nil
                    if name then
                        local v = (type(off.vendors) == "table" and off.vendors[1]) or nil
                        local mapID = v and type(v.mapID) == "number" and v.mapID or 0
                        local vx, vy = -1, -1
                        if v and type(v.x) == "number" and type(v.y) == "number" then
                            vx, vy = v.x, v.y
                            if vx > 1 or vy > 1 then vx, vy = vx / 100.0, vy / 100.0 end
                        end
                        local row = {
                            itemID = iid,
                            title = name,
                            altName = type(it.altName) == "string" and it.altName or "",
                            quality = type(it.quality) == "number" and it.quality or 1,
                            itemLevel = type(it.itemLevel) == "number" and it.itemLevel or 0,
                            mode = tostring(off.mode or "reward"),
                            team = tostring(off.team or "Neutral"),
                            costText = tostring(off.costText or off.priceText or off.reputation or ""),
                            availability = tostring(off.availability or ""),
                            zone = tostring(off.mode or "보상") .. (off.team and (" · " .. tostring(off.team)) or ""),
                            note = tostring(off.sourceText or (v and (tostring(v.name or "") .. " (" .. tostring(v.zone or "") .. ")")) or ""),
                        }
                        if mapID > 0 and vx >= 0 and vx <= 1 and vy >= 0 and vy <= 1 then
                            row.mapID = mapID; row.x = vx; row.y = vy
                        end
                        rows[#rows+1] = row
                    else
                        skip = skip + 1
                    end
                end
                for _, cr in ipairs((C.MerchantGuideData4111 and C.MerchantGuideData4111.crates) or {}) do
                    inp = inp + 1
                    if type(cr.name) == "string" then
                        local opts = {}
                        for _, o in ipairs(cr.options or {}) do
                            if o.name then opts[#opts+1] = tostring(o.name) .. "x" .. tostring(o.count or 1) end
                        end
                        rows[#rows+1] = {
                            itemID = type(cr.id) == "number" and cr.id or 0,
                            title = "[상인 상자] " .. cr.name,
                            zone = "상인 가이드 · Lv." .. tostring(cr.level or 1),
                            mode = "merchant",
                            team = "Neutral",
                            note = table.concat(opts, ", "),
                        }
                    end
                end
                table.sort(rows, function(a,b)
                    if tostring(a.title) ~= tostring(b.title) then return tostring(a.title) < tostring(b.title) end
                    return (a.itemID or 0) < (b.itemID or 0)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Reward",
                "Rewards & Merchant DB",
                "ForeverSuite LoadOnDemand 포에버 명예/평판/상인 보상 전체 DB",
                vec![("rewards".into(), "포에버 보상·상인 전체".into(), "reward".into(), src, inp, skip, rows)],
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 5. ForeverSuite_Data_Pet (hunter_pets with multi-spawn allLocs & abilities)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonHunterPetData/Data4114.lua", true, &mut src)?;

            let (inp, skip, rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local data = C.HunterPetData4114 or {}
                local famNames = {}
                for _, f in ipairs(data.families or {}) do
                    if type(f) == "table" and f.id then famNames[f.id] = tostring(f.name or f.id) end
                end
                for _, b in ipairs(data.beasts or data.pets or {}) do
                    inp = inp + 1
                    if type(b) == "table" and type(b.name) == "string" and b.name ~= "" then
                        local fam = famNames[b.familyID] or tostring(b.family or "야수")
                        local minL = type(b.minLevel) == "number" and b.minLevel or 0
                        local maxL = type(b.maxLevel) == "number" and b.maxLevel or minL
                        local locs = type(b.locations) == "table" and b.locations or {}
                        local loc = locs[1]
                        local multi = {}
                        for i = 1, math.min(#locs, 6) do
                            local l = locs[i]
                            if type(l) == "table" and type(l.mapID) == "number" and type(l.x) == "number" and type(l.y) == "number" then
                                local lx, ly = l.x, l.y
                                if lx > 1 or ly > 1 then lx, ly = lx / 100.0, ly / 100.0 end
                                if lx >= 0 and lx <= 1 and ly >= 0 and ly <= 1 then
                                    multi[#multi+1] = string.format("%d:%.3f:%.3f:%s", l.mapID, lx, ly, tostring(l.zone or ""))
                                end
                            end
                        end
                        local abIds = {}
                        for _, aid in ipairs(b.learnedAbilityIDs or {}) do
                            if type(aid) == "number" then abIds[#abIds+1] = tostring(aid) end
                        end
                        local row = {
                            npcID = type(b.npcID) == "number" and b.npcID or 0,
                            title = b.name .. (b.rare and " ★희귀" or ""),
                            altName = type(b.englishName) == "string" and b.englishName or "",
                            family = fam,
                            minLevel = minL,
                            maxLevel = maxL,
                            zone = fam .. " · Lv." .. tostring(minL) .. (maxL > minL and ("-" .. tostring(maxL)) or "") .. (loc and loc.zone and (" · " .. tostring(loc.zone)) or ""),
                            rare = b.rare == true,
                            allLocs = table.concat(multi, "|"),
                            abilitiesCsv = table.concat(abIds, ","),
                            locCount = #locs,
                        }
                        if loc and type(loc.mapID) == "number" and type(loc.x) == "number" and type(loc.y) == "number" then
                            local lx, ly = loc.x, loc.y
                            if lx > 1 or ly > 1 then lx, ly = lx / 100.0, ly / 100.0 end
                            if lx >= 0 and lx <= 1 and ly >= 0 and ly <= 1 then
                                row.mapID = loc.mapID; row.x = lx; row.y = ly
                            end
                        end
                        rows[#rows+1] = row
                    else
                        skip = skip + 1
                    end
                end
                table.sort(rows, function(a,b)
                    if tostring(a.title) ~= tostring(b.title) then return tostring(a.title) < tostring(b.title) end
                    return (a.npcID or 0) < (b.npcID or 0)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (ab_in, ab_skip, ab_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local data = C.HunterPetData4114 or {}
                local abs = data.abilities or {}
                local function addAb(a, fallbackId)
                    inp = inp + 1
                    if type(a) == "table" and type(a.name) == "string" and a.name ~= "" then
                        rows[#rows+1] = {
                            abilityID = type(a.id) == "number" and a.id or (type(fallbackId) == "number" and fallbackId or 0),
                            title = a.name,
                            rank = type(a.rank) == "number" and a.rank or 0,
                            spellID = type(a.spellID) == "number" and a.spellID or 0,
                            family = tostring(a.family or ""),
                            note = tostring(a.description or a.summary or ""),
                        }
                    else
                        skip = skip + 1
                    end
                end
                if #abs > 0 then
                    for idx, a in ipairs(abs) do addAb(a, idx) end
                else
                    local ids = {}
                    for k in pairs(abs) do if type(k) == "number" then ids[#ids+1] = k end end
                    table.sort(ids)
                    for _, k in ipairs(ids) do addAb(abs[k], k) end
                end
                table.sort(rows, function(a,b)
                    if a.title ~= b.title then return a.title < b.title end
                    return (a.rank or 0) < (b.rank or 0)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut pet_packs = vec![("hunter_pets".into(), "사냥꾼 야수 도감 전체".into(), "pet".into(), src.clone(), inp, skip, rows)];
            if !ab_rows.is_empty() {
                pet_packs.push(("pet_abilities".into(), "사냥꾼 야수 기술·등급 전체".into(), "pet".into(), src, ab_in, ab_skip, ab_rows));
            }

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Pet",
                "Hunter Pet DB",
                "ForeverSuite LoadOnDemand 사냥꾼 야수 길들이기·다중 서식지·기술·등급 전체 DB",
                pet_packs,
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 6. ForeverSuite_Data_Atlas (atlas_npcs + class_quests with walkthroughs + quest_chains + training_spells)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/MapServiceNPCData.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassTrainerLocations.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/MapTransportData.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/LibraryBooksData450.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestData.lua", true, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestRewardData433.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestWalkthroughData434.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestMartialGuide434.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestHunterPriestGuide434.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ClassQuestDruidGuide434.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/QuestChainData270.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/TrainingData.lua", true, &mut src)?;

            let (n_in, n_skip, n_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local seen = {}
                local mapIDs = {}
                for mid in pairs(C.MapServiceNPCs or {}) do if type(mid) == "number" then mapIDs[#mapIDs+1] = mid end end
                table.sort(mapIDs)
                for _, mid in ipairs(mapIDs) do
                    for _, npc in ipairs(C.MapServiceNPCs[mid] or {}) do
                        inp = inp + 1
                        if type(npc) == "table" and type(npc.name) == "string" and type(npc.x) == "number" and type(npc.y) == "number" then
                            local nx, ny = npc.x, npc.y
                            if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                            if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                                local key = tostring(mid) .. ":" .. tostring(npc.id or npc.name)
                                if not seen[key] then
                                    seen[key] = true
                                    local cat = (npc.kind == "classNPC") and "trainer" or "service"
                                    rows[#rows+1] = {
                                        mapID = mid, x = nx, y = ny,
                                        name = npc.name .. (npc.service and (" (" .. tostring(npc.service) .. ")") or ""),
                                        title = npc.name .. (npc.service and (" (" .. tostring(npc.service) .. ")") or ""),
                                        service = tostring(npc.service or ""),
                                        zone = tostring(npc.service or "서비스 NPC") .. (npc.faction and (" · " .. tostring(npc.faction)) or ""),
                                        category = cat,
                                        class = type(npc.class) == "string" and npc.class or "",
                                        faction = type(npc.faction) == "string" and npc.faction or "",
                                    }
                                end
                            else skip = skip + 1 end
                        else skip = skip + 1 end
                    end
                end
                for _, tr in ipairs(C.ClassTrainerLocations or {}) do
                    inp = inp + 1
                    if type(tr) == "table" and type(tr.mapID) == "number" and type(tr.x) == "number" and type(tr.y) == "number" then
                        local nx, ny = tr.x, tr.y
                        if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                        local key = tostring(tr.mapID) .. ":" .. tostring(tr.id or tr.name)
                        if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 and not seen[key] then
                            seen[key] = true
                            rows[#rows+1] = {
                                mapID = tr.mapID, x = nx, y = ny,
                                name = tostring(tr.name) .. " (" .. tostring(tr.class or "직업") .. " 상급자)",
                                title = tostring(tr.name) .. " (" .. tostring(tr.class or "직업") .. " 상급자)",
                                zone = tostring(tr.region or "") .. " · " .. tostring(tr.class or ""),
                                category = "trainer",
                                class = tostring(tr.class or ""),
                                faction = tostring(tr.faction or ""),
                            }
                        end
                    end
                end
                for mid, docks in pairs(C.MapTransitDocks or {}) do
                    if type(mid) == "number" and type(docks) == "table" then
                        for _, dk in ipairs(docks) do
                            inp = inp + 1
                            if type(dk) == "table" and type(dk[1]) == "number" and type(dk[2]) == "number" and type(dk[3]) == "string" then
                                local nx, ny = dk[1], dk[2]
                                if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                                local key = "transit:" .. tostring(mid) .. ":" .. dk[3]
                                if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 and not seen[key] then
                                    seen[key] = true
                                    rows[#rows+1] = {
                                        mapID = mid, x = nx, y = ny,
                                        name = dk[3],
                                        title = dk[3],
                                        service = "교통편",
                                        zone = "배 · 비행선 · 지하철",
                                        category = "transport",
                                        class = "",
                                        faction = "",
                                    }
                                end
                            end
                        end
                    end
                end
                table.sort(rows, function(a,b)
                    if a.mapID ~= b.mapID then return a.mapID < b.mapID end
                    return tostring(a.name) < tostring(b.name)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (q_in, q_skip, q_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local walks = C.ClassQuestWalkthrough434 or {}
                local chains = C.QuestChainStarts270 or {}
                local rewards = C.ClassQuestRewardData433 or {}
                local ids = {}
                for id in pairs(C.ClassQuests or {}) do if type(id) == "number" then ids[#ids+1] = id end end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local q = C.ClassQuests[id]
                    if type(q) == "table" and type(q.name) == "string" and q.name ~= "" then
                        local st = (type(q.starts) == "table" and q.starts[1]) or nil
                        local stepLines = {}
                        local w = walks[id]
                        if type(w) == "table" and type(w.steps) == "table" then
                            for idx, s in ipairs(w.steps) do
                                if type(s) == "table" and s.text then
                                    stepLines[#stepLines+1] = tostring(idx) .. ". " .. (s.title and ("[" .. tostring(s.title) .. "] ") or "") .. tostring(s.text)
                                end
                            end
                        end
                        local nextIds = {}
                        if type(chains[id]) == "table" then
                            for _, nid in ipairs(chains[id]) do
                                if type(nid) == "number" then nextIds[#nextIds+1] = tostring(nid) end
                            end
                        end
                        local rewSummaryParts, rewItemIds = {}, {}
                        local rw = rewards[id]
                        if type(rw) == "table" and type(rw.items) == "table" then
                            for _, ri in ipairs(rw.items) do
                                if type(ri) == "table" and type(ri.name) == "string" and ri.name ~= "" then
                                    local tag = ri.choice and "[선택] " or ""
                                    local desc = (type(ri.description) == "string" and ri.description ~= "") and (" (" .. ri.description .. ")") or ""
                                    rewSummaryParts[#rewSummaryParts+1] = tag .. ri.name .. desc
                                    if type(ri.id) == "number" and ri.id > 0 then
                                        rewItemIds[#rewItemIds+1] = tostring(ri.id)
                                    end
                                end
                            end
                        end
                        local row = {
                            questID = id,
                            title = q.name,
                            altName = type(q.en) == "string" and q.en or "",
                            level = type(q.level) == "number" and q.level or 0,
                            minLevel = type(q.minLevel) == "number" and q.minLevel or 0,
                            classMask = type(q.classMask) == "number" and q.classMask or 0,
                            side = type(q.side) == "number" and q.side or 3,
                            zone = "Lv." .. tostring(q.level or 0) .. " (최소 " .. tostring(q.minLevel or 0) .. ")",
                            walkthrough = table.concat(stepLines, "\n"),
                            chainCsv = table.concat(nextIds, ","),
                            rewardSummary = table.concat(rewSummaryParts, "\n"),
                            rewardItemIDs = table.concat(rewItemIds, ","),
                        }
                        if st and type(st.mapID) == "number" and type(st.x) == "number" and type(st.y) == "number" then
                            local sx, sy = st.x, st.y
                            if sx > 1 or sy > 1 then sx, sy = sx / 100.0, sy / 100.0 end
                            if sx >= 0 and sx <= 1 and sy >= 0 and sy <= 1 then
                                row.mapID = st.mapID; row.x = sx; row.y = sy
                            end
                        end
                        rows[#rows+1] = row
                    else skip = skip + 1 end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (s_in, s_skip, s_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local classes = {}
                for cls in pairs(C.TrainingData or {}) do classes[#classes+1] = cls end
                table.sort(classes)
                for _, cls in ipairs(classes) do
                    for _, sp in ipairs(C.TrainingData[cls] or {}) do
                        inp = inp + 1
                        if type(sp) == "table" and type(sp.id) == "number" and type(sp.level) == "number" then
                            rows[#rows+1] = {
                                class = cls, spellID = sp.id, level = sp.level,
                                cost = type(sp.cost) == "number" and sp.cost or 0,
                            }
                        else skip = skip + 1 end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (b_in, b_skip, b_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local books = (type(C.LibraryBooksData450) == "table" and C.LibraryBooksData450.books) or {}
                for _, bk in ipairs(books) do
                    inp = inp + 1
                    if type(bk) == "table" and type(bk.name) == "string" and bk.name ~= "" then
                        local loc = (type(bk.locations) == "table" and bk.locations[1]) or nil
                        local row = {
                            kind = "book",
                            itemID = type(bk.itemID) == "number" and bk.itemID or 0,
                            questID = type(bk.questID) == "number" and bk.questID or 0,
                            title = "[도서관 책] " .. bk.name,
                            altName = tostring(bk.en or ""),
                            set = tostring(bk.set or ""),
                            zone = loc and tostring(loc.region or "") or "",
                            note = loc and tostring(loc.landmark or "") or "",
                        }
                        if loc and type(loc.mapID) == "number" and type(loc.x) == "number" and type(loc.y) == "number" then
                            local nx, ny = loc.x, loc.y
                            if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                            if nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                                row.mapID = loc.mapID; row.x = nx; row.y = ny
                            end
                        end
                        rows[#rows+1] = row
                    else skip = skip + 1 end
                end
                local specials = {
                    { kind = "special", itemID = 280612, questID = 0, title = "[특수] 밤의 감시자의 횃불", zone = "그늘숲 · 까마귀 언덕", mapID = 1431, x = 0.172, y = 0.538, note = "까마귀 언덕 마을 큰 집 뒤편 야외 화장실 옆 쓰러진 경비병 (추가 제보: 47.7, 59.4 / 66.1, 34.0 / 45.6, 79.1)" },
                    { kind = "special", itemID = 221498, questID = 79192, title = "[특수] 12칸 가방 · 디딤돌", zone = "불모의 땅 / 서부 몰락지대 → 돌발톱 산맥", mapID = 1442, x = 0.408, y = 0.526, note = "불모의 땅(46.4, 73.9) 또는 서부 몰락지대(37.0, 50.0) 불타버린 잔해 시작 → 돌발톱 산맥 샛길(51.4, 52.4) → 숨은 야영지(40.8, 52.6) 휴대용 쓰레기통" },
                    { kind = "special", itemID = 211527, questID = 79192, title = "[특수] 아늑한 침낭 (휴식 경험치 버프)", zone = "돌발톱 산맥 → 소라딘의 성벽", mapID = 1442, x = 0.396, y = 0.498, note = "돌발톱 야영지 북쪽 절벽 흙무더기(39.6, 49.8) 연계 후 아라시 고원 소라딘의 성벽에서 완료" },
                    { kind = "special", itemID = 280700, questID = 95647, title = "[특수] 물약 가방 장신구 (저습지 발굴현장)", zone = "저습지 (Lv.24+)", mapID = 1437, x = 0.478, y = 0.562, note = "호드: 랩터 고기 4개 선택 보상(#95697) / 얼라이언스: 아딘 찾기(#95647) → 귀환 보고(#95809) 확정 지급" },
                }
                for _, sp in ipairs(specials) do
                    inp = inp + 1
                    rows[#rows+1] = sp
                end
                table.sort(rows, function(a,b)
                    if a.kind ~= b.kind then return a.kind < b.kind end
                    return tostring(a.title) < tostring(b.title)
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/GameSettingsPresetData5139.lua", false, &mut src)?;
            let (gp_in, gp_skip, gp_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local blocked = {
                    accessibilityScreenNarrationEnabled = true,
                    accessibilityScreenNarrationSpeechRate = true,
                    accessibilityScreenNarrationVoice = true,
                    Sound_EnableAllSound = true,
                    Sound_MasterVolume = true,
                    Sound_MusicVolume = true,
                    Sound_SFXVolume = true,
                    Sound_AmbienceVolume = true,
                    Sound_DialogVolume = true,
                    gxMonitor = true,
                    gxWindow = true,
                    gxMaximize = true,
                }
                local pd = C.GameSettingsPresetData5139
                if type(pd) == "table" and type(pd.cvars) == "table" then
                    for _, cv in ipairs(pd.cvars) do
                        inp = inp + 1
                        if type(cv) == "table" and type(cv.name) == "string" and cv.name ~= "" and type(cv.value) == "string" and not blocked[cv.name] then
                            local nm = cv.name
                            local cat = "general"
                            if string.find(nm, "camera", 1, true) or string.find(nm, "Camera", 1, true) then cat = "camera"
                            elseif string.find(nm, "chat", 1, true) or string.find(nm, "Chat", 1, true) then cat = "chat"
                            elseif string.find(nm, "combat", 1, true) or string.find(nm, "Combat", 1, true) or string.find(nm, "floatingCombat", 1, true) then cat = "combat"
                            elseif string.find(nm, "nameplate", 1, true) or string.find(nm, "Nameplate", 1, true) then cat = "nameplate"
                            end
                            -- Exclude enemy nameplate CVars to respect Platynator isolation
                            if cat ~= "nameplate" then
                                rows[#rows+1] = { name = nm, value = cv.value, category = cat }
                            else
                                skip = skip + 1
                            end
                        else
                            skip = skip + 1
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut atlas_packs = vec![
                ("atlas_npcs".into(), "서비스 NPC · 직업 상급자 · 교통편 전체".into(), "atlas".into(), src.clone(), n_in, n_skip, n_rows),
                ("class_quests".into(), "직업 퀘스트 및 단계별 공략서 전체".into(), "quest".into(), src.clone(), q_in, q_skip, q_rows),
                ("special_guides".into(), "특수 퀘스트 · 포에버 도서관 책 전체".into(), "quest".into(), src.clone(), b_in, b_skip, b_rows),
                ("training_spells".into(), "직업별 스킬 습득 테이블".into(), "character".into(), src.clone(), s_in, s_skip, s_rows),
            ];
            if !gp_rows.is_empty() {
                atlas_packs.push(("game_presets".into(), "갓존슨 권장 게임 CVar 프리셋 전체".into(), "preset".into(), src, gp_in, gp_skip, gp_rows));
            }

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Atlas",
                "Atlas, Quests & Training DB",
                "ForeverSuite LoadOnDemand 서비스 NPC·교통편·직업 퀘스트·특수 퀘스트·도서관 책·스킬·게임 프리셋 DB",
                atlas_packs,
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 7. ForeverSuite_Data_MapPins (WorldMap Quest Start `!` pins from MapQuestStartData.lua 940KB)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/MapQuestStartData.lua", true, &mut src)?;
            lua.load("if type(GJCompanion.LoadMapQuestPins) == 'function' then GJCompanion.LoadMapQuestPins() end")
                .set_mode(ChunkMode::Text)
                .exec()
                .map_err(|e| anyhow::anyhow!("LoadMapQuestPins failed: {e}"))?;

            let (p_in, p_skip, p_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local mids = {}
                for mid in pairs(C.MapQuestStartZones or {}) do
                    if type(mid) == "number" then mids[#mids+1] = mid end
                end
                table.sort(mids)
                for _, mid in ipairs(mids) do
                    local blob = C.MapQuestStartZones[mid]
                    if type(blob) == "string" then
                        for line in string.gmatch(blob, "[^\r\n]+") do
                            inp = inp + 1
                            local f = {}
                            local start = 1
                            while true do
                                local sep = string.find(line, "|", start, true)
                                if sep then
                                    f[#f+1] = string.sub(line, start, sep - 1)
                                    start = sep + 1
                                else
                                    f[#f+1] = string.sub(line, start)
                                    break
                                end
                            end
                            local qid = tonumber(f[1])
                            local rx = tonumber(f[2])
                            local ry = tonumber(f[3])
                            if qid and rx and ry and rx >= 0 and rx <= 10000 and ry >= 0 and ry <= 10000 then
                                local minL = tonumber(f[4]) or 0
                                local faction = (f[5] and f[5] ~= "") and f[5] or "Both"
                                local prereq = tonumber(f[9]) or 0
                                local lvl = tonumber(f[13]) or minL
                                local npc = (f[14] and f[14] ~= "") and f[14] or ("퀘스트 #" .. tostring(qid))
                                rows[#rows+1] = {
                                    mapID = mid,
                                    questID = qid,
                                    x = rx / 10000.0,
                                    y = ry / 10000.0,
                                    level = lvl,
                                    minLevel = minL,
                                    faction = faction,
                                    prereqID = prereq,
                                    npc = npc,
                                }
                            else
                                skip = skip + 1
                            end
                        end
                    end
                end
                table.sort(rows, function(a,b)
                    if a.mapID ~= b.mapID then return a.mapID < b.mapID end
                    return a.questID < b.questID
                end)
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_MapPins",
                "WorldMap Quest Pins DB",
                "ForeverSuite LoadOnDemand 전 지역 월드맵 미수락 퀘스트(!) 시작 핀 DB",
                vec![("map_quest_starts".into(), "월드맵 미수락 퀘스트 시작 핀".into(), "map".into(), src, p_in, p_skip, p_rows)],
            )?;
            staged_addons.push(st);
            all_prov.extend(prov);
        }

        // ---------------------------------------------------------------------
        // 8. ForeverSuite_Data_Items (Full 1.56 MB ItemReferenceData5089 + EN<->KR Translation Tables)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            let has_ref = exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ItemReferenceData5089.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/ItemTranslation445.lua", false, &mut src)?;
            exec_zip_lua_patched(
                &lua,
                &mut archive,
                "GodJohnsonGoldBorder/TooltipTranslation438.lua",
                false,
                &mut src,
                &[("local exact={", "GJCompanion.TooltipExact438={")],
            )?;

            let mut item_packs = Vec::new();
            if has_ref {
                let (c_in, c_skip, c_rows) = collect_entries_from_lua(
                    &lua,
                    r#"
                    local C = GJCompanion
                    local data = (type(C.PrepareItemReferenceCatalog5089) == "function") and C.PrepareItemReferenceCatalog5089() or {}
                    local items = (type(data) == "table" and type(data.items) == "table") and data.items or {}
                    local trans = (type(C.ItemTranslations445) == "table" and type(C.ItemTranslations445.names) == "table") and C.ItemTranslations445.names or {}
                    local rows, inp, skip = {}, 0, 0
                    local ids = {}
                    for id in pairs(items) do if type(id) == "number" then ids[#ids+1] = id end end
                    table.sort(ids)
                    local INV_NAME = {
                        [1]="머리",[2]="목",[3]="어깨",[4]="속옷",[5]="가슴",[6]="허리",[7]="다리",[8]="발",
                        [9]="손목",[10]="손",[11]="손가락",[12]="장신구",[13]="한손",[14]="방패",[15]="원거리",
                        [16]="등",[17]="양손",[18]="가방",[19]="휘장",[20]="가슴",[21]="주장비",[22]="보조장비",
                        [23]="보조장비",[25]="투척",[26]="원거리",[28]="성물",
                    }
                    for _, id in ipairs(ids) do
                        inp = inp + 1
                        local it = items[id]
                        local koName = trans[id] or (type(it) == "table" and (it.koName or it.name)) or nil
                        local enName = (type(it) == "table" and type(it.enName) == "string") and it.enName or ((type(it) == "table" and type(it.altName) == "string") and it.altName or "")
                        local title = (type(koName) == "string" and koName ~= "") and koName or ((enName ~= "") and enName or nil)
                        if type(it) == "table" and title then
                            local inv = type(it.inventoryType) == "number" and it.inventoryType or 0
                            local slotName = INV_NAME[inv] or ""
                            rows[#rows+1] = {
                                itemID = id,
                                title = title,
                                altName = enName,
                                quality = type(it.quality) == "number" and it.quality or 1,
                                itemLevel = type(it.itemLevel) == "number" and it.itemLevel or 0,
                                icon = type(it.icon) == "number" and it.icon or 0,
                                slot = slotName,
                                equipSlot = inv,
                                classID = type(it.classID) == "number" and it.classID or 0,
                                setName = type(it.setName) == "string" and it.setName or "",
                                zone = (type(it.setName) == "string" and it.setName ~= "") and ("세트 · " .. it.setName) or (slotName ~= "" and slotName or "아이템 도감"),
                            }
                        else
                            skip = skip + 1
                        end
                    end
                    return { input = inp, skipped = skip, rows = rows }
                    "#,
                )?;
                if !c_rows.is_empty() {
                    item_packs.push(("item_catalog".into(), "전체 아이템 레퍼런스 카탈로그".into(), "item".into(), src.clone(), c_in, c_skip, c_rows));
                }
            }

            let (tr_in, tr_skip, tr_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local names = (type(C.ItemTranslations445) == "table" and type(C.ItemTranslations445.names) == "table") and C.ItemTranslations445.names or {}
                local nids = {}
                for id in pairs(names) do if type(id) == "number" then nids[#nids+1] = id end end
                table.sort(nids)
                for _, id in ipairs(nids) do
                    inp = inp + 1
                    local ko = names[id]
                    if type(ko) == "string" and ko ~= "" then
                        rows[#rows+1] = { kind = "item", itemID = id, ko = ko }
                    else
                        skip = skip + 1
                    end
                end
                local exact = C.TooltipExact438 or {}
                local eKeys = {}
                for k in pairs(exact) do if type(k) == "string" then eKeys[#eKeys+1] = k end end
                table.sort(eKeys)
                for _, k in ipairs(eKeys) do
                    inp = inp + 1
                    local v = exact[k]
                    if type(v) == "string" and v ~= "" then
                        rows[#rows+1] = { kind = "clause", en = k, ko = v }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;
            if !tr_rows.is_empty() {
                item_packs.push(("item_translations".into(), "아이템·툴팁 영한 번역 사전".into(), "item".into(), src, tr_in, tr_skip, tr_rows));
            }
            if !item_packs.is_empty() {
                let (st, prov) = stage_lod_addon(
                    v2_root,
                    "ForeverSuite_Data_Items",
                    "Full Item Catalog & Translation DB",
                    "ForeverSuite LoadOnDemand 전체 아이템 레퍼런스 카탈로그(1.56MB) 및 영한 툴팁 번역 사전",
                    item_packs,
                )?;
                staged_addons.push(st);
                all_prov.extend(prov);
            }
        }

        // ---------------------------------------------------------------------
        // 9. ForeverSuite_Data_QuestExtra (Dialogue Routes, Interaction Targets, Collection, Starters, Escorts, QuickTips, Growth)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            lua.load("GJCompanion.QuestObjectiveTargets = {}").set_mode(ChunkMode::Text).exec().ok();
            exec_zip_lua_patched(
                &lua, &mut archive, "GodJohnsonGoldBorder/QuestDialogueRoutes.lua", false, &mut src,
                &[("local finish={", "GJCompanion.QuestDialogueFinish={")],
            )?;
            exec_zip_lua_patched(
                &lua, &mut archive, "GodJohnsonGoldBorder/QuestInteractionTargets196.lua", false, &mut src,
                &[("local additions={", "GJCompanion.QuestInteractionAdditions={")],
            )?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/QuestCollectionData447.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/QuestStarterData424.lua", false, &mut src)?;
            exec_zip_lua_patched(
                &lua, &mut archive, "GodJohnsonGoldBorder/EscortQuests249.lua", false, &mut src,
                &[("local escorts = {", "GJCompanion.EscortQuestsMap = {")],
            )?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/QuestPracticalTips279.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/QuickTipsData428.lua", false, &mut src)?;
            exec_zip_lua_patched(
                &lua, &mut archive, "GodJohnsonGoldBorder/GrowthGuideData5042.lua", false, &mut src,
                &[("local tips={", "GJCompanion.GrowthTips5042={")],
            )?;

            let (qr_in, qr_skip, qr_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local fIds = {}
                for qid in pairs(C.QuestDialogueFinish or {}) do if type(qid) == "number" then fIds[#fIds+1] = qid end end
                table.sort(fIds)
                for _, qid in ipairs(fIds) do
                    inp = inp + 1
                    local f = C.QuestDialogueFinish[qid]
                    if type(f) == "table" and type(f[1]) == "number" and type(f[2]) == "number" and type(f[3]) == "number" then
                        local nx, ny = f[2], f[3]
                        if nx > 1 or ny > 1 then nx, ny = nx / 100.0, ny / 100.0 end
                        rows[#rows+1] = {
                            kind = "dialogue",
                            questID = qid,
                            mapID = f[1],
                            x = nx,
                            y = ny,
                            title = tostring(f[4] or ("퀘스트 #" .. tostring(qid))),
                        }
                    else
                        skip = skip + 1
                    end
                end
                local aIds = {}
                for qid in pairs(C.QuestInteractionAdditions or {}) do if type(qid) == "number" then aIds[#aIds+1] = qid end end
                table.sort(aIds)
                for _, qid in ipairs(aIds) do
                    for _, obj in ipairs(C.QuestInteractionAdditions[qid] or {}) do
                        inp = inp + 1
                        if type(obj) == "table" and type(obj.name) == "string" and obj.name ~= "" then
                            local tLabels = {}
                            for _, tg in ipairs(obj.targets or {}) do
                                if type(tg) == "table" and tg.label then tLabels[#tLabels+1] = tostring(tg.label) end
                            end
                            rows[#rows+1] = {
                                kind = "interact",
                                questID = qid,
                                itemID = type(obj.itemID) == "number" and obj.itemID or 0,
                                count = type(obj.count) == "number" and obj.count or 1,
                                action = tostring(obj.action or "interact"),
                                title = obj.name,
                                note = table.concat(tLabels, " / "),
                            }
                        else
                            skip = skip + 1
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (qc_in, qc_skip, qc_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local items = (type(C.QuestCollectionData447) == "table" and type(C.QuestCollectionData447.items) == "table") and C.QuestCollectionData447.items or {}
                local ids = {}
                for id in pairs(items) do if type(id) == "number" then ids[#ids+1] = id end end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local it = items[id]
                    if type(it) == "table" and type(it.name) == "string" and it.name ~= "" then
                        local qList, iList = {}, {}
                        for qid in pairs(it.quests or {}) do if type(qid) == "number" then qList[#qList+1] = tostring(qid) end end
                        for iid in pairs(it.instances or {}) do if type(iid) == "number" then iList[#iList+1] = tostring(iid) end end
                        table.sort(qList); table.sort(iList)
                        rows[#rows+1] = {
                            itemID = id,
                            title = it.name,
                            altName = tostring(it.en or ""),
                            questsCsv = table.concat(qList, ","),
                            instancesCsv = table.concat(iList, ","),
                            generalDrop = it.generalDrop == true,
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (qs_in, qs_skip, qs_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                for _, r in ipairs(C.QuestStarterRecords4024 or {}) do
                    inp = inp + 1
                    if type(r) == "table" and type(r.itemID) == "number" then
                        local qList, nList = {}, {}
                        for _, qid in ipairs(r.quests or {}) do qList[#qList+1] = tostring(qid) end
                        for _, nid in ipairs(r.npcs or {}) do nList[#nList+1] = tostring(nid) end
                        rows[#rows+1] = {
                            itemID = r.itemID,
                            minLevel = type(r.minLevel) == "number" and r.minLevel or 0,
                            faction = tostring(r.faction or "Both"),
                            questsCsv = table.concat(qList, ","),
                            npcsCsv = table.concat(nList, ","),
                        }
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            // Extract real inline escort names/notes from EscortQuests249.lua comments so ZERO synthetic placeholder copy is generated
            {
                let mut escort_comment_lua = String::from("GJCompanion.EscortComments = {\n");
                if let Ok(mut f) = archive.by_name("GodJohnsonGoldBorder/EscortQuests249.lua") {
                    let mut raw = String::new();
                    let _ = f.read_to_string(&mut raw);
                    for line in raw.lines() {
                        let trimmed = line.trim();
                        if let Some(rest) = trimmed.strip_prefix('[') {
                            if let Some((id_str, after_id)) = rest.split_once(']') {
                                if let Ok(qid) = id_str.trim().parse::<u32>() {
                                    if let Some((_, comment)) = after_id.split_once("--") {
                                        let clean = comment.trim().replace('\\', "\\\\").replace('"', "\\\"");
                                        if !clean.is_empty() {
                                            escort_comment_lua.push_str(&format!("  [{qid}] = \"{clean}\",\n"));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                escort_comment_lua.push_str("}\n");
                lua.load(&escort_comment_lua).set_mode(ChunkMode::Text).exec().ok();
            }

            let (qt_in, qt_skip, qt_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local comments = C.EscortComments or {}
                local eIds = {}
                for qid in pairs(C.EscortQuestsMap or {}) do if type(qid) == "number" then eIds[#eIds+1] = qid end end
                table.sort(eIds)
                for _, qid in ipairs(eIds) do
                    inp = inp + 1
                    local desc = comments[qid]
                    if type(desc) == "string" and desc ~= "" then
                        rows[#rows+1] = {
                            kind = "escort",
                            questID = qid,
                            title = "[호위] " .. desc,
                            category = "escort",
                            summary = "호위 대상: " .. desc .. " (퀘스트 #" .. tostring(qid) .. ")",
                            note = "호위 대상: " .. desc .. " · 퀘스트 #" .. tostring(qid) .. " (Forever 1.60.1 검증 호위 단계). 선행 몹 정리 및 파티 동행을 권장합니다.",
                        }
                    else
                        skip = skip + 1
                    end
                end
                for _, qt in ipairs(C.QuickTipsData428 or {}) do
                    inp = inp + 1
                    if type(qt) == "table" and type(qt.title) == "string" then
                        local loc = (type(qt.locations) == "table" and type(qt.locations[1]) == "table") and qt.locations[1] or nil
                        local mapID = (loc and type(loc.mapID) == "number") and loc.mapID or nil
                        local lx = (loc and type(loc.x) == "number") and (loc.x > 1 and (loc.x / 100.0) or loc.x) or nil
                        local ly = (loc and type(loc.y) == "number") and (loc.y > 1 and (loc.y / 100.0) or loc.y) or nil
                        local row = {
                            kind = "quicktip",
                            key = tostring(qt.key or ""),
                            category = tostring(qt.category or "general"),
                            title = qt.title,
                            summary = tostring(qt.summary or ""),
                            meta = tostring(qt.meta or ""),
                            note = tostring(qt.body or ""),
                        }
                        if mapID and lx and ly then
                            row.mapID = mapID
                            row.x = lx
                            row.y = ly
                        end
                        rows[#rows+1] = row
                    end
                end
                local gKeys = {}
                for k in pairs(C.GrowthTips5042 or {}) do gKeys[#gKeys+1] = tostring(k) end
                table.sort(gKeys)
                for _, k in ipairs(gKeys) do
                    inp = inp + 1
                    local g = C.GrowthTips5042[k]
                    if type(g) == "table" and type(g.title) == "string" then
                        rows[#rows+1] = {
                            kind = "growth",
                            key = k,
                            category = "growth",
                            title = g.title,
                            note = table.concat(g.lines or {}, "\n"),
                        }
                    end
                end
                if type(C.KrolPreparationWarning279) == "string" and C.KrolPreparationWarning279 ~= "" then
                    inp = inp + 1
                    rows[#rows+1] = { kind = "practical", key = "krol_warn", category = "dungeon", title = "크롤도크 보루 사전 준비 주의", note = C.KrolPreparationWarning279 }
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut qx_packs = Vec::new();
            if !qr_rows.is_empty() { qx_packs.push(("quest_routes".into(), "퀘스트 대화 루트·상호작용 대상".into(), "quest".into(), src.clone(), qr_in, qr_skip, qr_rows)); }
            if !qc_rows.is_empty() { qx_packs.push(("quest_collection".into(), "퀘스트 수집 완료 알림 데이터".into(), "quest".into(), src.clone(), qc_in, qc_skip, qc_rows)); }
            if !qs_rows.is_empty() { qx_packs.push(("quest_starters".into(), "퀘스트 시작 아이템·드랍처 힌트".into(), "quest".into(), src.clone(), qs_in, qs_skip, qs_rows)); }
            if !qt_rows.is_empty() { qx_packs.push(("quest_tips".into(), "호위 퀘스트·퀵 팁·성장 가이드".into(), "quest".into(), src, qt_in, qt_skip, qt_rows)); }
            if !qx_packs.is_empty() {
                let (st, prov) = stage_lod_addon(
                    v2_root,
                    "ForeverSuite_Data_QuestExtra",
                    "Quest Routes, Tips & Growth DB",
                    "ForeverSuite LoadOnDemand 퀘스트 대화 루트·상호작용·수집 알림·호위·퀵팁·성장 가이드 전체 DB",
                    qx_packs,
                )?;
                staged_addons.push(st);
                all_prov.extend(prov);
            }
        }

        // ---------------------------------------------------------------------
        // 10. ForeverSuite_Data_MapExtra (WorldMap Fog-of-War Reveal + Gather & Pet Heatmaps)
        // ---------------------------------------------------------------------
        {
            let lua = create_sandboxed_lua()?;
            let mut src = Vec::new();
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/MapRevealData.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonAtlasData/GatherHeatmapData411.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonHunterPetData/PetHeatmapData4115.lua", false, &mut src)?;

            let (mr_in, mr_skip, mr_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local mids = {}
                for mid in pairs(C.MapRevealData or {}) do if type(mid) == "number" then mids[#mids+1] = mid end end
                table.sort(mids)
                for _, mid in ipairs(mids) do
                    for _, ov in ipairs(C.MapRevealData[mid] or {}) do
                        inp = inp + 1
                        if type(ov) == "table" and type(ov.files) == "table" and #ov.files > 0 then
                            local fl = {}
                            for _, fid in ipairs(ov.files) do fl[#fl+1] = tostring(fid) end
                            rows[#rows+1] = {
                                mapID = mid,
                                w = type(ov.w) == "number" and ov.w or 256,
                                h = type(ov.h) == "number" and ov.h or 256,
                                x = type(ov.x) == "number" and ov.x or 0,
                                y = type(ov.y) == "number" and ov.y or 0,
                                filesCsv = table.concat(fl, ","),
                            }
                        else
                            skip = skip + 1
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (gh_in, gh_skip, gh_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local function rewriteMedia(p)
                    if type(p) ~= "string" then return "" end
                    return (string.gsub(p, "Interface\\AddOns\\GodJohnsonGoldBorder\\Media\\", "Interface\\AddOns\\ForeverSuite_Media_Assets\\"))
                end
                local iIds = {}
                for iid in pairs(C.GatherHeatmapData411 or {}) do if type(iid) == "number" then iIds[#iIds+1] = iid end end
                table.sort(iIds)
                for _, iid in ipairs(iIds) do
                    local byMap = C.GatherHeatmapData411[iid]
                    local mIds = {}
                    for mid in pairs(byMap or {}) do if type(mid) == "number" then mIds[#mIds+1] = mid end end
                    table.sort(mIds)
                    for _, mid in ipairs(mIds) do
                        inp = inp + 1
                        local rec = byMap[mid]
                        if type(rec) == "table" and type(rec.file) == "string" then
                            local tc = rec.texCoord or {0,1,0,1}
                            rows[#rows+1] = {
                                itemID = iid,
                                mapID = mid,
                                points = type(rec.points) == "number" and rec.points or 0,
                                file = rewriteMedia(rec.file),
                                u1 = type(tc[1]) == "number" and tc[1] or 0,
                                u2 = type(tc[2]) == "number" and tc[2] or 1,
                                v1 = type(tc[3]) == "number" and tc[3] or 0,
                                v2 = type(tc[4]) == "number" and tc[4] or 1,
                            }
                        else
                            skip = skip + 1
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (ph_in, ph_skip, ph_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local function rewriteMedia(p)
                    if type(p) ~= "string" then return "" end
                    return (string.gsub(p, "Interface\\AddOns\\GodJohnsonGoldBorder\\Media\\", "Interface\\AddOns\\ForeverSuite_Media_Assets\\"))
                end
                local ph = C.PetHeatmapData4115 or {}
                local sprites = ph.sprites or {}
                local petsMap = ph.pets or {}
                local npcIds = {}
                for nid in pairs(petsMap) do if type(nid) == "number" then npcIds[#npcIds+1] = nid end end
                table.sort(npcIds)
                for _, nid in ipairs(npcIds) do
                    for _, rec in ipairs(petsMap[nid] or {}) do
                        inp = inp + 1
                        local sp = (type(rec) == "table" and type(rec.sprite) == "number") and sprites[rec.sprite] or nil
                        if sp and type(sp.file) == "string" and type(rec.mapID) == "number" and type(rec.rect) == "table" then
                            local uv = sp.uv or {0,1,0,1}
                            local rc = rec.rect
                            rows[#rows+1] = {
                                npcID = nid,
                                mapID = rec.mapID,
                                points = type(rec.points) == "number" and rec.points or 0,
                                file = rewriteMedia(sp.file),
                                u1 = type(uv[1]) == "number" and uv[1] or 0,
                                u2 = type(uv[2]) == "number" and uv[2] or 1,
                                v1 = type(uv[3]) == "number" and uv[3] or 0,
                                v2 = type(uv[4]) == "number" and uv[4] or 1,
                                x0 = type(rc[1]) == "number" and rc[1] or 0,
                                x1 = type(rc[2]) == "number" and rc[2] or 1,
                                y0 = type(rc[3]) == "number" and rc[3] or 0,
                                y1 = type(rc[4]) == "number" and rc[4] or 1,
                            }
                        else
                            skip = skip + 1
                        end
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let mut mx_packs = Vec::new();
            if !mr_rows.is_empty() { mx_packs.push(("map_reveal".into(), "월드맵 미탐험 지역 밝히기 오버레이".into(), "map".into(), src.clone(), mr_in, mr_skip, mr_rows)); }
            if !gh_rows.is_empty() { mx_packs.push(("gather_heatmap".into(), "채집물(약초·광맥) 밀도 히트맵".into(), "map".into(), src.clone(), gh_in, gh_skip, gh_rows)); }
            if !ph_rows.is_empty() { mx_packs.push(("pet_heatmap".into(), "사냥꾼 야수 출현 밀도 히트맵".into(), "map".into(), src, ph_in, ph_skip, ph_rows)); }
            if !mx_packs.is_empty() {
                let (st, prov) = stage_lod_addon(
                    v2_root,
                    "ForeverSuite_Data_MapExtra",
                    "WorldMap Reveal & Heatmaps DB",
                    "ForeverSuite LoadOnDemand 월드맵 미탐험 밝히기·채집 히트맵·야수 히트맵 전체 DB",
                    mx_packs,
                )?;
                staged_addons.push(st);
                all_prov.extend(prov);
            }
        }

        // ---------------------------------------------------------------------
        // 11. ForeverSuite_Media_Assets (LoD Binary Media Pack: Dungeon Maps, Arrows, Heatmaps, Sounds, Fonts)
        // ---------------------------------------------------------------------
        {
            let addon_name = "ForeverSuite_Media_Assets";
            let target_dir = v2_root.join(addon_name);
            let pid = std::process::id();
            let stage_dir = v2_root.join(format!(".{addon_name}.stage.{pid}"));
            let prev_dir = v2_root.join(format!(".{addon_name}.prev.{pid}"));
            if stage_dir.exists() {
                fs::remove_dir_all(&stage_dir)?;
            }
            fs::create_dir_all(&stage_dir)?;

            let mut copied_count = 0usize;
            let mut sound_files: Vec<String> = Vec::new();
            let mut font_files: Vec<String> = Vec::new();
            let mut map_files: Vec<String> = Vec::new();
            let mut arrow_files: Vec<String> = Vec::new();
            let prefix = "GodJohnsonGoldBorder/Media/";

            for i in 0..archive.len() {
                let mut entry = archive.by_index(i)?;
                if entry.is_dir() {
                    continue;
                }
                let name = entry.name().to_string();
                let Some(rel) = name.strip_prefix(prefix) else {
                    continue;
                };
                if rel.contains("..") || rel.starts_with('/') {
                    continue;
                }
                let low = rel.to_lowercase();
                let keep = if rel.starts_with("Maps/") && (low.ends_with(".tga") || low.ends_with(".blp")) {
                    map_files.push(rel.to_string());
                    true
                } else if rel.starts_with("Dungeon4130/") && (low.ends_with(".tga") || low.ends_with(".blp")) {
                    map_files.push(rel.to_string());
                    true
                } else if rel.starts_with("Arrows/") && low.ends_with(".tga") {
                    arrow_files.push(rel.to_string());
                    true
                } else if (rel.starts_with("GatherHeat4110/") || rel.starts_with("PetHeat4115/")) && low.ends_with(".tga") {
                    true
                } else if rel.starts_with("Fonts/") && (low.ends_with(".ttf") || low.ends_with(".otf")) {
                    font_files.push(rel.to_string());
                    true
                } else if rel.starts_with("Notifications/") && (low.ends_with(".ogg") || low.ends_with(".wav") || low.ends_with(".mp3")) {
                    // Keep 4 volume steps (_25/_50/_75/_100) + non-suffixed clips for crisp volume control without CVar writes
                    let stem = low.rsplit('/').next().unwrap_or("");
                    let keep_snd = stem.ends_with("_25.ogg")
                        || stem.ends_with("_50.ogg")
                        || stem.ends_with("_75.ogg")
                        || stem.ends_with("_100.ogg")
                        || !stem.contains('_')
                        || stem.ends_with(".wav")
                        || stem.ends_with(".mp3");
                    if keep_snd {
                        sound_files.push(rel.to_string());
                    }
                    keep_snd
                } else {
                    false
                };
                if !keep {
                    continue;
                }
                if entry.size() > MAX_ZIP_ENTRY_BYTES {
                    continue;
                }
                let dst = stage_dir.join(rel);
                if let Some(parent) = dst.parent() {
                    fs::create_dir_all(parent)?;
                }
                let mut buf = Vec::with_capacity(entry.size() as usize);
                entry.read_to_end(&mut buf)?;
                fs::write(&dst, &buf)?;
                copied_count += 1;
            }

            let extracted_count = copied_count;
            if extracted_count > 0 {
                // Preserve bespoke local UI/ and Icons/ art kits across media regeneration
                let mut preserved_ui_tgas = 0usize;
                let mut preserved_icon_tgas = 0usize;
                for sub in ["UI", "Icons"] {
                    let src_sub = target_dir.join(sub);
                    if src_sub.is_dir() {
                        let dst_sub = stage_dir.join(sub);
                        fs::create_dir_all(&dst_sub)?;
                        for entry in fs::read_dir(&src_sub)? {
                            let entry = entry?;
                            let p = entry.path();
                            if p.is_file() && !p.is_symlink() {
                                if let Some(fname) = p.file_name() {
                                    fs::copy(&p, dst_sub.join(fname))?;
                                    if p.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("tga")).unwrap_or(false) {
                                        if sub == "UI" {
                                            preserved_ui_tgas += 1;
                                        } else {
                                            preserved_icon_tgas += 1;
                                        }
                                        copied_count += 1;
                                    }
                                }
                            }
                        }
                    }
                }
                sound_files.sort();
                font_files.sort();
                map_files.sort();
                arrow_files.sort();
                let manifest_lua = format!(
                    "-- Auto-generated ForeverSuite Media Assets Manifest\n\
_G.ForeverSuiteMediaAssets = {{\n\
    root = \"Interface\\\\AddOns\\\\ForeverSuite_Media_Assets\\\\\",\n\
    counts = {{ total = {}, maps = {}, arrows = {}, sounds = {}, fonts = {}, ui = {}, icons = {} }},\n\
}}\n",
                    copied_count,
                    map_files.len(),
                    arrow_files.len(),
                    sound_files.len(),
                    font_files.len(),
                    preserved_ui_tgas,
                    preserved_icon_tgas
                );
                full_moon::parse(&manifest_lua)
                    .map_err(|e| anyhow::anyhow!("Invalid AssetsManifest.lua: {e:?}"))?;
                fs::write(stage_dir.join("AssetsManifest.lua"), manifest_lua.as_bytes())?;
                let toc = "## Interface: 16001, 120105\n\
## Title: |cffd4af37Forever|rSuite · Media Assets (LoD)\n\
## Notes: ForeverSuite LoadOnDemand 던전 내부 지도·화살표·히트맵·알림음·한글 폰트 통합 미디어 팩\n\
## Author: Youngseo Cho\n\
## Version: 4.0.0\n\
## LoadOnDemand: 1\n\
## Dependencies: ForeverSuite\n\n\
AssetsManifest.lua\n";
                fs::write(stage_dir.join(format!("{addon_name}.toc")), toc.as_bytes())?;
                staged_addons.push(StagedAddon {
                    stage_dir,
                    target_dir,
                    prev_dir,
                });
                all_prov.push(GjPackProvenance {
                    addon_name: addon_name.to_string(),
                    pack_id: "media_assets".into(),
                    title: "던전 내부 지도·화살표·히트맵·알림음·한글 폰트 통합 미디어".into(),
                    source_files: vec!["Media/Maps".into(), "Media/Dungeon4130".into(), "Media/Arrows".into(), "Media/Notifications".into(), "Media/Fonts".into()],
                    input_count: copied_count,
                    output_count: copied_count,
                    skipped_count: 0,
                    shards: 1,
                    output_sha256: sha256_bytes(manifest_lua.as_bytes()),
                });
            } else {
                let _ = fs::remove_dir_all(&stage_dir);
            }
        }

        Ok(())
    })();

    if let Err(err) = stage_res {
        for s in &staged_addons {
            let _ = fs::remove_dir_all(&s.stage_dir);
        }
        return Err(err);
    }

    let data_dir = v2_root.join("ForeverSuite_Data");
    fs::create_dir_all(&data_dir)?;
    let manifest = GjBuildManifest {
        generator: format!("fsx {}", env!("CARGO_PKG_VERSION")),
        source_zip: zip_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Legacy_addons_backup.zip")
            .to_string(),
        source_zip_sha256: zip_sha,
        packs: all_prov,
    };
    let manifest_json = serde_json::to_string_pretty(&manifest)? + "\n";

    commit_staged_addons(staged_addons)?;

    let manifest_path = data_dir.join("gj_lod_manifest.json");
    let manifest_tmp = data_dir.join(format!(".gj_lod_manifest.{}.tmp", std::process::id()));
    fs::write(&manifest_tmp, manifest_json.as_bytes())?;
    fs::rename(&manifest_tmp, &manifest_path)?;

    let total_entries: usize = manifest.packs.iter().map(|p| p.output_count).sum();
    let total_shards: usize = manifest.packs.iter().map(|p| p.shards).sum();
    println!(
        "[OK] fsx data compile-gj: generated {} LoD addon packs ({} sub-packs, {} total entries across {} shards)",
        {
            let mut uniq = std::collections::BTreeSet::new();
            for p in &manifest.packs {
                uniq.insert(p.addon_name.as_str());
            }
            uniq.len()
        },
        manifest.packs.len(),
        total_entries,
        total_shards
    );
    for p in &manifest.packs {
        println!(
            "  - {:<28} {:<16} in={:<5} out={:<5} skip={:<4} shards={}",
            p.addon_name, p.pack_id, p.input_count, p.output_count, p.skipped_count, p.shards
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use tempfile::tempdir;
    use zip::write::SimpleFileOptions;
    use zip::ZipWriter;

    #[test]
    fn rejects_wrong_zip_and_binary_lua_bytecode_fail_closed() -> Result<()> {
        let dir = tempdir()?;
        let bad_zip = dir.path().join("wrong.zip");
        {
            let f = File::create(&bad_zip)?;
            let mut zw = ZipWriter::new(f);
            zw.start_file("Account/ForeverSuite.lua", SimpleFileOptions::default())?;
            zw.write_all(b"ForeverSuiteDB = {}\n")?;
            zw.finish()?;
        }
        let out_root = dir.path().join("v2");
        fs::create_dir_all(&out_root)?;
        assert!(compile_gj_lod_packs(&bad_zip, &out_root).is_err());
        assert!(!out_root.join("ForeverSuite_Data_Dungeon").exists());

        let bin_zip = dir.path().join("bytecode.zip");
        {
            let f = File::create(&bin_zip)?;
            let mut zw = ZipWriter::new(f);
            zw.start_file("GodJohnsonGoldBorder/DungeonData.lua", SimpleFileOptions::default())?;
            zw.write_all(b"\x1bLuaQ\x00\x01")?;
            zw.finish()?;
        }
        assert!(compile_gj_lod_packs(&bin_zip, &out_root).is_err());
        Ok(())
    }
}
