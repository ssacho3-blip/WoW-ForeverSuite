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

fn exec_zip_lua<R: Read + std::io::Seek>(
    lua: &Lua,
    archive: &mut ZipArchive<R>,
    path: &str,
    required: bool,
    loaded_sources: &mut Vec<String>,
) -> Result<bool> {
    if let Some(src) = read_zip_lua(archive, path)? {
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

            if body.contains("GJCompanion") {
                let _ = fs::remove_dir_all(&stage_dir);
                bail!("Forbidden 'GJCompanion' token leaked into {addon_name}/{file_name}");
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
## Version: 2.2.0\n\
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
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonBlueleaf.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonGnomeregan.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonWetlands.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonDalaran468.lua", false, &mut src)?;
            exec_zip_lua(&lua, &mut archive, "GodJohnsonGoldBorder/DungeonGuideData.lua", false, &mut src)?;
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

            let (d_in, d_skip, d_rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local seen = {}
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
                local function addDungeon(d, fallbackKey)
                    if type(d) ~= "table" or type(d.name) ~= "string" or d.name == "" then skip = skip + 1; return end
                    local key = tostring(d.key or fallbackKey or d.instance or d.name)
                    if seen[key] then return end
                    seen[key] = true
                    local inst = (type(d.instance) == "number") and d.instance or 0
                    local row = {
                        id = key,
                        instance = inst,
                        title = d.name,
                        levels = tostring(d.levels or ""),
                        faction = tostring(d.guideFaction or d.faction or "Both"),
                        isRaid = d.isRaid == true,
                        partySize = type(d.partySize) == "number" and d.partySize or (d.isRaid and 40 or 5),
                        zone = tostring(d.intro or d.region or d.levels or ""),
                        note = tostring(d.route or ""),
                        questCount = type(d.quests) == "table" and #d.quests or 0,
                        bossCount = type(d.bosses) == "table" and #d.bosses or 0,
                        category = "dungeon",
                    }
                    local ed = (inst > 0) and entByInst[inst] or nil
                    if ed and ed.points and ed.points[1] then
                        local pt = ed.points[1]
                        local nx, ny = normCoord(pt.x, pt.y)
                        if type(pt.mapID) == "number" and nx and ny and nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                            row.mapID = pt.mapID; row.x = nx; row.y = ny
                            row.entranceNote = tostring(ed.instructions or pt.description or pt.label or "")
                        end
                    end
                    rows[#rows+1] = row
                end
                for _, d in ipairs(C.Dungeons or {}) do inp = inp + 1; addDungeon(d, nil) end
                for k, d in pairs(C.DungeonInfo or {}) do inp = inp + 1; addDungeon(d, k) end
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
                local ids = {}
                for id in pairs(merged) do ids[#ids+1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    inp = inp + 1
                    local it = merged[id]
                    local name = type(it.name) == "string" and it.name or nil
                    if name and name ~= "" then
                        local src = bossByItem[id]
                        local row = {
                            itemID = id,
                            title = name,
                            altName = type(it.altName) == "string" and it.altName or "",
                            quality = type(it.quality) == "number" and it.quality or 1,
                            itemLevel = type(it.itemLevel) == "number" and it.itemLevel or 0,
                            reqLevel = type(it.requiredLevel) == "number" and it.requiredLevel or 0,
                            slot = type(it.slot) == "string" and it.slot or "",
                            itemType = type(it.type) == "string" and it.type or "",
                            dungeon = src and src.dungeon or "",
                            boss = src and src.boss or "",
                            zone = src and (src.dungeon .. " · " .. src.boss) or ((type(it.slot) == "string" and it.slot ~= "" and it.slot) or (type(it.type) == "string" and it.type or "던전 드랍")),
                        }
                        rows[#rows+1] = row
                    else
                        skip = skip + 1
                    end
                end
                return { input = inp, skipped = skip, rows = rows }
                "#,
            )?;

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Dungeon",
                "Dungeon & Loot DB",
                "ForeverSuite LoadOnDemand 던전·보스·퀘스트·드랍 전체 DB",
                vec![
                    ("dungeons".into(), "던전 가이드 전체".into(), "dungeon".into(), src.clone(), d_in, d_skip, d_rows),
                    ("dungeon_bosses".into(), "던전 보스 및 드랍 매핑".into(), "dungeon".into(), src.clone(), b_in, b_skip, b_rows),
                    ("dungeon_quests".into(), "던전 퀘스트 준비 목록".into(), "dungeon".into(), src.clone(), q_in, q_skip, q_rows),
                    ("dungeon_loot".into(), "던전 드랍 아이템 전체".into(), "dungeon".into(), src, l_in, l_skip, l_rows),
                ],
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

            let (inp, skip, rows) = collect_entries_from_lua(
                &lua,
                r#"
                local C = GJCompanion
                local rows, inp, skip = {}, 0, 0
                local items = (type(C.BiSData) == "table" and type(C.BiSData.items) == "table") and C.BiSData.items or {}
                local recipes = (type(C.AcquisitionFacts408) == "table" and type(C.AcquisitionFacts408.recipes) == "table") and C.AcquisitionFacts408.recipes or {}
                local SLOT_TO_INV = {
                    ["머리"] = 1, ["목"] = 2, ["어깨"] = 3, ["가슴"] = 5, ["허리"] = 6,
                    ["다리"] = 7, ["발"] = 8, ["손목"] = 9, ["손"] = 10, ["손가락"] = 11,
                    ["장신구"] = 13, ["등"] = 15, ["망토"] = 15, ["주장비"] = 16, ["한손"] = 16,
                    ["양손"] = 16, ["보조장비"] = 17, ["방패"] = 17, ["원거리"] = 18, ["마법봉"] = 18,
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
                                    acqParts[#acqParts+1] = "제작(" .. tostring(r.profession) .. " " .. tostring(r.skill or "") .. "): " .. tostring(r.source or "")
                                end
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

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_BiS",
                "BiS Gear DB",
                "ForeverSuite LoadOnDemand BiS 장비·비교·획득처 전체 DB",
                vec![("bis".into(), "BiS 장비 및 획득처 전체".into(), "bis".into(), src, inp, skip, rows)],
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

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Profession",
                "Profession DB",
                "ForeverSuite LoadOnDemand 12대 전문기술(독 제조 포함) 육성 가이드·제조법·교관 전체 DB",
                vec![
                    ("prof_guides".into(), "전문기술 구간별 육성 가이드".into(), "profession".into(), src.clone(), g_in, g_skip, g_rows),
                    ("professions".into(), "전문기술 제조법 전체".into(), "profession".into(), src.clone(), r_in, r_skip, r_rows),
                    ("prof_trainers".into(), "전문기술 교관·대가·낚시/요리 길안내".into(), "profession".into(), src, t_in, t_skip, t_rows),
                ],
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

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Pet",
                "Hunter Pet DB",
                "ForeverSuite LoadOnDemand 사냥꾼 야수 길들이기·다중 서식지·기술 전체 DB",
                vec![("hunter_pets".into(), "사냥꾼 야수 도감 전체".into(), "pet".into(), src, inp, skip, rows)],
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

            let (st, prov) = stage_lod_addon(
                v2_root,
                "ForeverSuite_Data_Atlas",
                "Atlas, Quests & Training DB",
                "ForeverSuite LoadOnDemand 서비스 NPC·교통편·직업 퀘스트·특수 퀘스트·도서관 책·스킬 DB",
                vec![
                    ("atlas_npcs".into(), "서비스 NPC · 직업 상급자 · 교통편 전체".into(), "atlas".into(), src.clone(), n_in, n_skip, n_rows),
                    ("class_quests".into(), "직업 퀘스트 및 단계별 공략서 전체".into(), "quest".into(), src.clone(), q_in, q_skip, q_rows),
                    ("special_guides".into(), "특수 퀘스트 · 포에버 도서관 책 전체".into(), "quest".into(), src.clone(), b_in, b_skip, b_rows),
                    ("training_spells".into(), "직업별 스킬 습득 테이블".into(), "character".into(), src, s_in, s_skip, s_rows),
                ],
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
        "[OK] fsx data compile-gj: generated 7 LoD addon packs ({} sub-packs, {} total entries across {} shards)",
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
