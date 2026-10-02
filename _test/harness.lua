-- Test harness: stubs the 1.12 API and runs a sync roundtrip.
-- Does NOT run in-game; it only verifies the protocol before installing.

local frames = {}
local now = 100

function GetTime() return now end
UIParent = {}

local frameMT = {}
frameMT.__index = {
  SetScript = function(self, k, f) self.scripts[k] = f end,
  GetScript = function(self, k) return self.scripts[k] end,
  RegisterEvent = function() end,
  UnregisterEvent = function() end,
  SetWidth = function() end, SetHeight = function() end,
  GetWidth = function() return 200 end, GetHeight = function() return 20 end,
  SetPoint = function() end, ClearAllPoints = function() end,
  SetAllPoints = function() end, SetFrameStrata = function() end,
  Show = function(self) self.shown = true end,
  Hide = function(self) self.shown = false end,
  IsShown = function(self) return self.shown end,
  SetBackdrop = function() end,
  CreateFontString = function() return setmetatable({ scripts = {} }, frameMT) end,
  CreateTexture = function() return setmetatable({ scripts = {} }, frameMT) end,
  SetText = function() end, SetJustifyH = function() end, SetFont = function() end,
  SetTextColor = function() end, GetStringWidth = function() return 50 end,
  SetID = function() end, GetID = function() return 1 end,
}

function CreateFrame(kind, name, parent)
  local f = setmetatable({ scripts = {}, name = name, shown = false }, frameMT)
  if name then frames[name] = f end
  return f
end

strfind, strsub, strlen, strbyte, strlower = string.find, string.sub, string.len, string.byte, string.lower
gsub, format = string.gsub, string.format
mod = math.fmod
table.getn = table.getn or function(t) return #t end
UNKNOWNOBJECT = "Unknown"
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("  |chat| " .. m) end }
SlashCmdList = {}
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }

-- Group: me + Thrall
function GetNumRaidMembers() return 0 end
function GetNumPartyMembers() return 1 end
function GetRaidRosterInfo() return nil end
function UnitName(u) if u == "player" then return "Henry" elseif u == "party1" then return "Thrall" end end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitIsUnit(a, b) return a == b end

-- Quest log with zone headers. Quests under a collapsed header are hidden
-- from GetQuestLogTitle, exactly like the 1.12 client does it.
local LOG = {
  { header = "Elwynn Forest", collapsed = false },
  { title = "Mountain Pass", level = 12, obj = {
      { "Kobold Miner slain: 3/8", false },
      { "Kobold Overseer slain: 0/2", false },
  } },
  { title = "The Lost Map", level = 15, complete = 1, obj = {
      { "Map of the Lost", true },
  } },
  { title = "Escort the Merchant", level = 14, complete = -1, obj = {
      { "Escort the merchant", false },
  } },
  { header = "Westfall", collapsed = false },
  { title = "A Gathering Errand With A Very Long Title For The Length Test", level = 30, obj = {
      { "Exceptionally long objective number one: 10/20", false },
      { "Exceptionally long objective number two: 5/20", false },
      { "Exceptionally long objective number three: 0/20", false },
      { "Exceptionally long objective number four: 1/20", false },
      { "Exceptionally long objective number five: 2/20", false },
  } },
  { title = "The Defias Brotherhood", level = 18, obj = {
      { "Defias Pillager slain: 1/10", false },
  } },
}

local function Visible()
  local out, total, hide = {}, 0, false
  for _, e in ipairs(LOG) do
    if e.header then
      hide = e.collapsed
      table.insert(out, e)
    else
      total = total + 1
      if not hide then table.insert(out, e) end
    end
  end
  return out, total
end

function GetNumQuestLogEntries()
  local v, total = Visible()
  return table.getn(v), total
end
function GetQuestLogTitle(i)
  local e = Visible()[i]
  if not e then return nil end
  if e.header then return e.header, nil, nil, 1, e.collapsed and 1 or nil, nil end
  return e.title, e.level, nil, nil, nil, e.complete
end
function GetNumQuestLeaderBoards(i)
  local e = Visible()[i]
  return e and e.obj and table.getn(e.obj) or 0
end
function GetQuestLogLeaderBoard(o, i)
  local e = Visible()[i]
  if not e or not e.obj or not e.obj[o] then return nil end
  return e.obj[o][1], "monster", e.obj[o][2]
end

local function FindLog(title)
  for i, e in ipairs(LOG) do if e.title == title then return i, e end end
end

-- capture everything that gets sent
SENT = {}
function SendAddonMessage(prefix, msg, chan)
  table.insert(SENT, { prefix = prefix, msg = msg, chan = chan })
end

dofile("core.lua")
dofile("scan.lua")
dofile("comm.lua")

local PQ = PartyQuest
PQ.db = {}
for k, v in pairs(PQ.defaults) do PQ.db[k] = v end
PQ.UpdateRoster()

local sender = frames["PartyQuestSender"]
local function Drain()
  for i = 1, 300 do
    now = now + 1
    sender.scripts.OnUpdate()
  end
end
local function Deliver(list)
  for _, m in ipairs(list) do PQ.OnAddonMessage(m.prefix, m.msg, "PARTY", "Thrall") end
end
local function Has(prefix)
  for _, m in ipairs(SENT) do
    if string.sub(m.msg, 1, string.len(prefix)) == prefix then return true end
  end
end

print("== send full sync ==")
PQ.Broadcast(true)
Drain()

local maxlen = 0
for i, m in ipairs(SENT) do
  local total = string.len(m.prefix) + 1 + string.len(m.msg)
  if total > maxlen then maxlen = total end
  print(string.format("  [%2d] %3d B  %s", i, total, (string.gsub(m.msg, "\t", " | "))))
end
print("  messages: " .. table.getn(SENT) .. ", longest: " .. maxlen .. " B (limit 255)")
assert(maxlen < 250, "message too long!")
assert(Has("L\t5\t1\t"), "full sync must end with the key list")

print("== simulate receiving (as Thrall) ==")
-- a ghost quest Thrall's copy still has from earlier: the key list must remove it
local member = PQ.GetMember("Thrall")
member.version = "x"
member.quests["q1"] = { title = "Ghost", level = 1, complete = 0, obj = {}, objCount = 0 }
PQ.IndexTitle(member, member.quests["q1"])
Deliver(SENT)

local n = 0
for key, q in pairs(member.quests) do
  n = n + 1
  local cur, req, pct = PQ.QuestProgress(q)
  print(string.format("  %-10s %-45s lvl %2d  %s", key, q.title, q.level,
    q.complete == 1 and "COMPLETE" or q.complete == -1 and "FAILED"
    or (cur .. "/" .. req .. "  " .. math.floor(pct) .. "%")))
end
assert(n == 5, "expected 5 quests, got " .. n)
assert(not member.quests["q1"], "ghost quest not pruned by key list")
assert(not member.byTitle["Ghost"], "ghost title not unindexed")

print("== failed quest stays failed ==")
local failed = PQ.FindQuest(member, nil, "Escort the Merchant")
assert(failed and failed.complete == -1, "failed quest not transmitted as -1")

print("== state hash matches after full sync ==")
assert(PQ.StateHash(member.quests) == PQ.StateHash(PQ.mine), "hash mismatch after full sync")

print("== title fallback, incl. long titles ==")
local q = PQ.FindQuest(member, "q99999", "Mountain Pass")
assert(q and q.title == "Mountain Pass", "title fallback broken")
q = PQ.FindQuest(member, "q99999", "A Gathering Errand With A Very Long Title For The Length Test")
assert(q, "long title not found (normalisation)")

print("== delta: one objective changes ==")
SENT = {}
local _, mp = FindLog("Mountain Pass")
mp.obj[1][1] = "Kobold Miner slain: 7/8"
PQ.Broadcast(nil)
Drain()
print("  delta messages: " .. table.getn(SENT) .. " (expected 1)")
assert(table.getn(SENT) == 1, "delta sends too much")
Deliver(SENT)

print("== collapsed header: hidden quests are kept ==")
SENT = {}
LOG[5].collapsed = true            -- collapse Westfall
PQ.Broadcast(nil)
Drain()
assert(not Has("D\t"), "hidden quests reported as gone")

print("== collapsed header: turn-in in an open zone is still reported ==")
SENT = {}
local i = FindLog("The Lost Map")
table.remove(LOG, i)
PQ.Broadcast(nil)
Drain()
assert(Has("D\t"), "no D command although Elwynn is expanded")
Deliver(SENT)
assert(not PQ.FindQuest(member, nil, "The Lost Map"), "receiver kept the turned-in quest")

print("== hello: hash match -> no request; mismatch -> targeted request ==")
SENT = {}
PQ.SendHello()
Drain()
local hello
for _, m in ipairs(SENT) do if string.sub(m.msg, 1, 2) == "H\t" then hello = m end end
assert(hello, "no hello sent")
SENT = {}
Deliver({ hello })
Drain()
assert(not Has("R"), "requested although the hash matched")
member.quests["q2"] = { title = "Stale", level = 1, complete = 0, obj = {}, objCount = 0 }
member.requested = nil
SENT = {}
Deliver({ hello })
Drain()
assert(Has("R\tThrall"), "no targeted request on hash mismatch")

print("== v1.0 hello is understood ==")
PQ.OnAddonMessage("PQT", "H\t1.1.0.0", "PARTY", "Thrall")
assert(member.version == "1.0.0" and member.proto == 1, "legacy hello parsed wrong: " .. tostring(member.version))

print("\nAll tests passed.")
