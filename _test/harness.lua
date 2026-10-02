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
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("  |chat| " .. m) end }
SlashCmdList = {}
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }

-- Group: me + Thrall
function GetNumRaidMembers() return 0 end
function GetNumPartyMembers() return 1 end
function UnitName(u) if u == "player" then return "Henry" elseif u == "party1" then return "Thrall" end end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitIsUnit(a, b) return a == b end

-- Quest log: 3 quests, one of them with a lot of objectives
local LOG = {
  { title = "Mountain Pass", level = 12, complete = false, obj = {
      { "Kobold Miner slain: 3/8", false },
      { "Kobold Overseer slain: 0/2", false },
  } },
  { title = "The Lost Map", level = 15, complete = true, obj = {
      { "Map of the Lost", true },
  } },
  { title = "A Gathering Errand With A Very Long Title For The Length Test", level = 30, complete = false, obj = {
      { "Exceptionally long objective number one: 10/20", false },
      { "Exceptionally long objective number two: 5/20", false },
      { "Exceptionally long objective number three: 0/20", false },
      { "Exceptionally long objective number four: 1/20", false },
      { "Exceptionally long objective number five: 2/20", false },
  } },
}

function GetNumQuestLogEntries() return table.getn(LOG), table.getn(LOG) end
function GetQuestLogTitle(i)
  local q = LOG[i]
  if not q then return nil end
  return q.title, q.level, nil, false, false, q.complete
end
function GetNumQuestLeaderBoards(i) return LOG[i] and table.getn(LOG[i].obj) or 0 end
function GetQuestLogLeaderBoard(o, i)
  local q = LOG[i]
  if not q or not q.obj[o] then return nil end
  return q.obj[o][1], "monster", q.obj[o][2]
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

print("== send full sync ==")
PQ.Broadcast(true)

-- drain the send queue
local sender = frames["PartyQuestSender"]
for i = 1, 200 do
  now = now + 1
  sender.scripts.OnUpdate()
end

local maxlen = 0
for i, m in ipairs(SENT) do
  local total = string.len(m.prefix) + 1 + string.len(m.msg)
  if total > maxlen then maxlen = total end
  print(string.format("  [%2d] %3d B  %s", i, total, (string.gsub(m.msg, "\t", " | "))))
end
print("  messages: " .. table.getn(SENT) .. ", longest: " .. maxlen .. " B (limit 255)")
assert(maxlen < 250, "message too long!")

print("== simulate receiving (as Thrall) ==")
for _, m in ipairs(SENT) do
  PQ.OnAddonMessage(m.prefix, m.msg, "PARTY", "Thrall")
end

local member = PQ.party["Thrall"]
assert(member, "no member created")
local n = 0
for key, q in pairs(member.quests) do
  n = n + 1
  local cur, req, pct = PQ.QuestProgress(q)
  print(string.format("  %-8s %-45s lvl %2d  %s", key, q.title, q.level,
    q.complete == 1 and "COMPLETE" or (cur .. "/" .. req .. "  " .. math.floor(pct) .. "%")))
  for i = 1, q.objCount do
    local o = q.obj[i]
    print(string.format("        - %-24s %s/%s%s", o.label, o.cur, o.req, o.done == 1 and " (ok)" or ""))
  end
end
assert(n == 3, "expected 3 quests, got " .. n)

print("== title fallback (receiver without pfQuest ids) ==")
local q = PQ.FindQuest(member, "q99999", "Mountain Pass")
assert(q and q.title == "Mountain Pass", "title fallback broken")
print("  ok: quest found by title")

print("== delta: one objective changes ==")
SENT = {}
LOG[1].obj[1][1] = "Kobold Miner slain: 7/8"
PQ.Broadcast(nil)
for i = 1, 50 do now = now + 1; sender.scripts.OnUpdate() end
print("  delta messages: " .. table.getn(SENT) .. " (expected 1)")
assert(table.getn(SENT) == 1, "delta sends too much")

print("== quest turned in ==")
SENT = {}
table.remove(LOG, 2)
PQ.Broadcast(nil)
for i = 1, 50 do now = now + 1; sender.scripts.OnUpdate() end
local hasDelete = false
for _, m in ipairs(SENT) do
  if string.sub(m.msg, 1, 2) == "D\t" then hasDelete = true end
end
print("  messages: " .. table.getn(SENT) .. ", delete command: " .. tostring(hasDelete))
assert(hasDelete, "no D command sent")

print("\nAll tests passed.")
