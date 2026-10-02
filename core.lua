--[[ PartyQuest -- core
     Target client: WoW 1.12 (Octo WoW / Turtle base), Lua 5.0.
     Deliberately NO modern APIs: no C_*, no hooksecurefunc, no #tbl,
     no string.gmatch, no select(), no strsplit().
]]--

PartyQuest = CreateFrame("Frame", "PartyQuestCore", UIParent)
local PQ = PartyQuest

PQ.addonName  = "PartyQuest"
PQ.versionStr = "1.1.0"
PQ.protocol   = 2   -- 1 = v1.0 (H carried "1.<version>"), 2 = H with state hash
PQ.prefix     = "PQT"

-- Default configuration (SavedVariablesPerCharacter)
PQ.defaults = {
  enabled  = "1",   -- sync on/off entirely
  questlog = "1",   -- side panel on the Blizzard quest log
  rows     = "1",   -- counters in the quest log list
  tracker  = "1",   -- lines in the pfQuest tracker
  self     = "1",   -- include your own progress in the panel
  raid     = "group", -- in a raid: "group" = own subgroup only, "all", "off"
  debug    = "0",
}

-- Runtime data
PQ.party   = {}   -- [playername] = { time, version, quests = { [key] = questdata }, byTitle = {} }
PQ.mine    = {}   -- [key] = questdata (own snapshot, basis for delta sync)
PQ.roster  = {}   -- [playername] = unitid ("party1".."party4" / "raidN")
                  -- in a raid only your own subgroup, unless db.raid == "all"
PQ.dataRev = 0    -- bumped on every data change; the UIs poll it

-- Colors
PQ.C = {
  head  = "|cff33ffcc",
  white = "|cffffffff",
  grey  = "|cff888888",
  gold  = "|cffffcc00",
  green = "|cff40dd40",
  red   = "|cffdd4040",
  off   = "|r",
}

--------------------------------------------------------------------------
-- small helpers (Lua 5.0 safe)
--------------------------------------------------------------------------

-- Counts entries of a hash table (table.getn does not work on those).
function PQ.Count(t)
  local n = 0
  if not t then return 0 end
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Splits on a *literal* separator (plain find, no pattern magic).
function PQ.Split(str, sep)
  local out, count, pos = {}, 0, 1
  if not str then return out, 0 end
  while true do
    local s, e = strfind(str, sep, pos, 1)
    if not s then break end
    count = count + 1
    out[count] = strsub(str, pos, s - 1)
    pos = e + 1
  end
  count = count + 1
  out[count] = strsub(str, pos)
  return out, count
end

-- Cuts to at most n bytes without slicing a UTF-8 sequence in half.
function PQ.Truncate(str, n)
  if not str then return "" end
  if strlen(str) <= n then return str end
  local cut = n
  while cut > 0 do
    local b = strbyte(str, cut + 1)
    -- 0x80..0xBF = continuation byte -> step back one more
    if b and b >= 128 and b < 192 then
      cut = cut - 1
    else
      break
    end
  end
  return strsub(str, 1, cut)
end

-- Strips every character the protocol uses as a separator.
-- (see NormTitle below for the title variant)
function PQ.Clean(str)
  if not str then return "" end
  str = gsub(str, "[\t~#|]", " ")
  str = gsub(str, "%s+", " ")
  str = gsub(str, "^%s*(.-)%s*$", "%1")
  return str
end

-- Title as it travels over the wire: cleaned and cut to 48 bytes. Both the
-- sender and every lookup use this form, so long titles or titles with
-- separator characters still match.
function PQ.NormTitle(title)
  return PQ.Truncate(PQ.Clean(title or ""), 48)
end

-- Stable hash over a string (djb2, clamped to 2^24).
-- Same locale => same bytes => same key on every client.
function PQ.Hash(str)
  local h = 5381
  if not str then return 0 end
  local len = strlen(str)
  for i = 1, len do
    h = mod(h * 33 + strbyte(str, i), 16777216)
  end
  return h
end

function PQ.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(PQ.C.head .. "Party" .. PQ.C.white .. "Quest" .. PQ.C.off .. ": " .. (msg or ""))
end

function PQ.Debug(msg)
  if PQ.db and PQ.db.debug == "1" then
    DEFAULT_CHAT_FRAME:AddMessage(PQ.C.grey .. "[PQ] " .. (msg or "") .. PQ.C.off)
  end
end

-- Flags the data as changed; the UIs redraw on the next poll.
function PQ.Touch()
  PQ.dataRev = PQ.dataRev + 1
end

--------------------------------------------------------------------------
-- Group roster
--------------------------------------------------------------------------

function PQ.InGroup()
  if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
  if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
  return nil
end

-- Channel used for syncing, or nil when syncing is off for this group type.
function PQ.SyncChannel()
  local channel = PQ.InGroup()
  if channel == "RAID" and PQ.db and PQ.db.raid == "off" then return nil end
  return channel
end

local function IsKnownName(name)
  return name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown"
end

-- Rebuilds PQ.roster and drops data from members who left.
-- Returns: joined = { name, ... }, nJoined, wasAlone
-- (wasAlone = we had nobody before, i.e. we just joined a group)
function PQ.UpdateRoster()
  local old, wasAlone = {}, true
  for k, v in pairs(PQ.roster) do
    old[k] = v
    wasAlone = false
    PQ.roster[k] = nil
  end

  -- During loading screens names can briefly be unknown. Then we keep the
  -- stored data instead of throwing it away and re-syncing everything.
  local incomplete = nil
  local channel = PQ.SyncChannel()
  if channel == "RAID" then
    local n = GetNumRaidMembers()
    local me = UnitName("player")
    local mygroup = nil
    if PQ.db and PQ.db.raid ~= "all" then
      for i = 1, n do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name == me then mygroup = subgroup break end
      end
    end
    for i = 1, n do
      local unit = "raid" .. i
      local name, _, subgroup = GetRaidRosterInfo(i)
      name = name or UnitName(unit)
      if not IsKnownName(name) then
        incomplete = true
      elseif name ~= me and (not mygroup or subgroup == mygroup) then
        PQ.roster[name] = unit
      end
    end
  elseif channel == "PARTY" then
    local n = GetNumPartyMembers()
    for i = 1, n do
      local unit = "party" .. i
      local name = UnitName(unit)
      if not IsKnownName(name) then
        incomplete = true
      else
        PQ.roster[name] = unit
      end
    end
  end

  -- Drop data from people who are no longer with us
  if not incomplete then
    for name in pairs(PQ.party) do
      if not PQ.roster[name] then PQ.party[name] = nil end
    end
  end

  local joined, nJoined = {}, 0
  for name in pairs(PQ.roster) do
    if not old[name] then
      nJoined = nJoined + 1
      joined[nJoined] = name
    end
  end

  PQ.Touch()
  return joined, nJoined, wasAlone
end

function PQ.ClassColor(name)
  local unit = PQ.roster[name]
  if not unit and name == UnitName("player") then unit = "player" end
  if not unit then return "|cffcccccc" end
  local _, class = UnitClass(unit)
  if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
    local c = RAID_CLASS_COLORS[class]
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
  end
  return "|cffcccccc"
end

-- Traffic-light color for a progress value.
function PQ.ProgressColor(cur, req)
  if not req or req <= 0 then return PQ.C.grey end
  if cur >= req then return PQ.C.green end
  if cur <= 0 then return PQ.C.red end
  local p = cur / req
  local r = 1
  local g = 0.3 + 0.7 * p
  if p > 0.5 then r = 1 - (p - 0.5) * 1.2 end
  return string.format("|cff%02x%02x40", r * 255, g * 255)
end

--------------------------------------------------------------------------
-- Access to a member's data
--------------------------------------------------------------------------

function PQ.GetMember(name)
  if not PQ.party[name] then
    PQ.party[name] = { time = GetTime(), version = nil, proto = nil, quests = {}, byTitle = {} }
  end
  return PQ.party[name]
end

-- Keeps member.byTitle in step with member.quests (keyed by NormTitle).
function PQ.IndexTitle(member, q)
  if q and q.title and q.title ~= "" then
    member.byTitle[PQ.NormTitle(q.title)] = q
  end
end

function PQ.UnindexTitle(member, q)
  if not q or not q.title then return end
  local t = PQ.NormTitle(q.title)
  if member.byTitle[t] == q then member.byTitle[t] = nil end
end

-- Looks up a member's quest: by key (quest id) first, by title second.
-- The title fallback covers the case where one client has pfQuest and the
-- other does not.
function PQ.FindQuest(member, key, title)
  if not member then return nil end
  if key and member.quests[key] then return member.quests[key] end
  if title then
    local q = member.byTitle[PQ.NormTitle(title)]
    if q then return q end
  end
  return nil
end

--------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------

PQ:RegisterEvent("ADDON_LOADED")
PQ:RegisterEvent("PLAYER_ENTERING_WORLD")

PQ:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "PartyQuest" then
    PartyQuest_config = PartyQuest_config or {}
    for k, v in pairs(PQ.defaults) do
      if PartyQuest_config[k] == nil then PartyQuest_config[k] = v end
    end
    PQ.db = PartyQuest_config
    PQ.Debug("config loaded")
  elseif event == "PLAYER_ENTERING_WORLD" then
    PQ.db = PartyQuest_config or PQ.defaults
    -- the roster itself is handled in comm.lua (it needs the join info)
    if not PQ.greeted then
      PQ.greeted = true
      PQ.Print("v" .. PQ.versionStr .. " loaded. Type " .. PQ.C.head .. "/pq" .. PQ.C.off .. " for options.")
    end
  end
end)
