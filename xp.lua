--[[ PartyQuest -- quest XP

     The 1.12 client has no API for a quest's XP reward, so the base values
     come from questxp_data.lua ([questId] = { questLevel, full XP }).
     The XP is scaled by the character's level the way the server does it:
     full XP up to 5 levels above the quest level, then 80/60/40/20 %, and
     10 % from 10 levels above. At level 60 quests give money instead of XP.

     Shown in three places:
       * quest log: behind the quest title in the detail view
       * quest window at the NPC (accept / progress / turn in): behind the title
       * PartyQuest panel: per member, at that member's level
]]--

local PQ = PartyQuest
local DB = PartyQuest_QuestXPData or {}

local MAX_LEVEL = 60

--------------------------------------------------------------------------
-- Calculation
--------------------------------------------------------------------------

-- Rounding as the client/server applies it after the level scaling.
local function RoundXP(xp)
  if xp <= 100 then
    return 5 * floor((xp + 2) / 5)
  elseif xp <= 500 then
    return 10 * floor((xp + 5) / 10)
  elseif xp <= 1000 then
    return 25 * floor((xp + 12) / 25)
  end
  return 50 * floor((xp + 25) / 50)
end

local function Rate()
  local r = PQ.db and tonumber(PQ.db.xprate)
  if not r or r <= 0 then r = 1 end
  return r
end

-- XP for one quest id at the given character level.
-- Returns xp, estimated (true for OctoWoW quests estimated from money),
-- or nil if the quest is unknown.
function PQ.QuestXP(qid, charLevel)
  local d = qid and DB[qid]
  if not d then return nil end
  local qlevel, base, est = d[1], d[2], (d[3] == 1)
  charLevel = tonumber(charLevel) or 1
  if charLevel >= MAX_LEVEL then return 0, est end
  local m = 2 * (qlevel - charLevel) + 20
  if m < 1 then m = 1 elseif m > 10 then m = 10 end
  return floor(RoundXP(base * m / 10) * Rate()), est
end

--------------------------------------------------------------------------
-- Finding the quest id
--------------------------------------------------------------------------

-- title -> { id, id, ... } from pfQuest's localized quest names
local titleIndex = nil
local function BuildTitleIndex()
  titleIndex = {}
  if not pfDB or not pfDB["quests"] or type(pfDB["quests"]["loc"]) ~= "table" then return end
  for id, loc in pairs(pfDB["quests"]["loc"]) do
    if type(loc) == "table" and loc.T and DB[id] then
      if not titleIndex[loc.T] then titleIndex[loc.T] = {} end
      table.insert(titleIndex[loc.T], id)
    end
  end
end

-- true if mask has the single bit set; unknown (not a single bit) counts as yes
local function HasBit(mask, bit)
  if not bit or bit <= 0 then return true end
  local b = 1
  while b < bit do b = b * 2 end
  if b ~= bit then return true end  -- pfQuest fallback mask, not one race
  return mod(floor(mask / bit), 2) == 1
end

-- Can the player take this quest at all? (race/class bits from pfQuest)
local function FitsPlayer(id)
  if not pfDB or not pfDB["quests"] or not pfDB["quests"]["data"] then return true end
  local data = pfDB["quests"]["data"][id]
  if not data or not pfDatabase then return true end
  if data.race and pfDatabase.GetBitByRace then
    local _, race = UnitRace("player")
    if not HasBit(data.race, pfDatabase:GetBitByRace(race)) then return nil end
  end
  if data.class and pfDatabase.GetBitByClass then
    local _, class = UnitClass("player")
    if not HasBit(data.class, pfDatabase:GetBitByClass(class)) then return nil end
  end
  return true
end

-- All quest ids that could be meant by key / title / level.
local function Candidates(key, title, level)
  if key then
    local _, _, id = strfind(key, "^q(%d+)$")
    id = tonumber(id)
    if id and DB[id] then return { id } end
  end
  if not title then return {} end
  if not titleIndex then BuildTitleIndex() end
  local ids = titleIndex[title]
  if not ids then return {} end

  local out = {}
  level = tonumber(level)
  for i = 1, table.getn(ids) do
    local id = ids[i]
    if (not level or level <= 0 or DB[id][1] == level) and FitsPlayer(id) then
      table.insert(out, id)
    end
  end
  -- filters too strict (e.g. level shown differently): fall back to all
  if table.getn(out) == 0 then
    for i = 1, table.getn(ids) do table.insert(out, ids[i]) end
  end
  return out
end

-- Text like "1050 XP", "800-850 XP", "~900 XP" (estimate) or nil when unknown.
function PQ.QuestXPText(key, title, level, charLevel)
  local ids = Candidates(key, title, level)
  local lo, hi, approx
  for i = 1, table.getn(ids) do
    local xp, est = PQ.QuestXP(ids[i], charLevel)
    if est then approx = "~" end
    if xp then
      if not lo or xp < lo then lo = xp end
      if not hi or xp > hi then hi = xp end
    end
  end
  if not lo then return nil end
  if hi == 0 then return "no XP" end
  approx = approx or ""
  if lo == hi then return approx .. lo .. " XP" end
  return approx .. lo .. "-" .. hi .. " XP"
end

--------------------------------------------------------------------------
-- Display behind quest titles
--------------------------------------------------------------------------

-- Appends the XP to a title font string. Blizzard rewrites these strings
-- whenever it updates the frame, so the driver below checks a few times a
-- second and appends again when the text was reset.
local function Decorate(fs, getSuffix)
  if not fs or not fs:IsVisible() then return end
  local text = fs:GetText()
  if not text or text == "" or text == fs.pqText then return end
  local xp = getSuffix()
  if not xp then
    fs.pqText = text
    return
  end
  local new = text .. "  " .. PQ.C.gold .. "(" .. xp .. ")" .. PQ.C.off
  fs:SetText(new)
  fs.pqText = new
end

local function QuestLogSuffix()
  local sel = GetQuestLogSelection and GetQuestLogSelection()
  if not sel or sel <= 0 then return nil end
  local title, level, _, header = GetQuestLogTitle(sel)
  if not title or header then return nil end
  return PQ.QuestXPText(PQ.QuestKey(sel, title), title, level, UnitLevel("player"))
end

local function QuestFrameSuffix()
  local title = GetTitleText and GetTitleText()
  if not title or title == "" then return nil end
  -- the NPC window gives no quest level, so the title has to do
  return PQ.QuestXPText(nil, title, nil, UnitLevel("player"))
end

local driver = CreateFrame("Frame", "PartyQuestXPDriver", UIParent)
driver.next = 0
driver:SetScript("OnUpdate", function()
  if not PQ.db or PQ.db.xp ~= "1" then return end
  if GetTime() < driver.next then return end
  driver.next = GetTime() + 0.2

  if QuestLogFrame and QuestLogFrame:IsVisible() then
    Decorate(QuestLogQuestTitle, QuestLogSuffix)
  end
  if QuestFrame and QuestFrame:IsVisible() then
    Decorate(QuestTitleText, QuestFrameSuffix)          -- accept
    Decorate(QuestProgressTitleText, QuestFrameSuffix)  -- items needed
    Decorate(QuestRewardTitleText, QuestFrameSuffix)    -- turn in
  end
end)
