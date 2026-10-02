--[[ PartyQuest -- slash commands ]]--

local PQ = PartyQuest

local function Toggle(keyname, label)
  PQ.db[keyname] = (PQ.db[keyname] == "1") and "0" or "1"
  PQ.Print(label .. ": " .. (PQ.db[keyname] == "1" and PQ.C.green .. "on" or PQ.C.red .. "off") .. PQ.C.off)
  PQ.Touch()
end

local function Status()
  PQ.Print("Status:")
  local channel = PQ.InGroup()
  DEFAULT_CHAT_FRAME:AddMessage("  Group: " .. (channel or "none"))
  local n = 0
  for name, unit in pairs(PQ.roster) do
    n = n + 1
    local member = PQ.party[name]
    local info
    if member and member.version then
      info = PQ.C.green .. "v" .. member.version .. PQ.C.off
        .. " (" .. PQ.Count(member.quests) .. " quests)"
    else
      info = PQ.C.grey .. "no PartyQuest" .. PQ.C.off
    end
    DEFAULT_CHAT_FRAME:AddMessage("  " .. PQ.ClassColor(name) .. name .. PQ.C.off .. ": " .. info)
  end
  if n == 0 then DEFAULT_CHAT_FRAME:AddMessage("  (travelling alone)") end
  DEFAULT_CHAT_FRAME:AddMessage("  own quests in sync: " .. PQ.Count(PQ.mine))
end

local function Help()
  PQ.Print("Commands:")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq status    - who is broadcasting, what is queued")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq sync      - request and send a full sync")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq log       - quest log panel on/off")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq rows      - counters in the quest list on/off")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq tracker   - pfQuest tracker lines on/off")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq self      - your own progress in the panel on/off")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq on | off  - sync on/off entirely")
  DEFAULT_CHAT_FRAME:AddMessage("  /pq debug     - debug output on/off")
end

SLASH_PARTYQUEST1 = "/pq"
SLASH_PARTYQUEST2 = "/partyquest"

SlashCmdList["PARTYQUEST"] = function(msg)
  msg = strlower(PQ.Clean(msg or ""))

  if msg == "" or msg == "help" then
    Help()
  elseif msg == "status" then
    Status()
  elseif msg == "sync" then
    if not PQ.InGroup() then
      PQ.Print("You are not in a group.")
    else
      PQ.SendHello()
      PQ.SendRequest()
      PQ.ScheduleFullSync(0.5)
      PQ.Print("Full sync triggered.")
    end
  elseif msg == "log" then
    Toggle("questlog", "Quest log panel")
  elseif msg == "rows" then
    Toggle("rows", "Quest list counters")
  elseif msg == "tracker" then
    Toggle("tracker", "pfQuest tracker lines")
  elseif msg == "self" then
    Toggle("self", "Own progress in panel")
  elseif msg == "debug" then
    Toggle("debug", "Debug")
  elseif msg == "on" then
    PQ.db.enabled = "1"
    PQ.Print("Sync " .. PQ.C.green .. "on" .. PQ.C.off)
    PQ.ScheduleFullSync(1)
  elseif msg == "off" then
    PQ.db.enabled = "0"
    PQ.Print("Sync " .. PQ.C.red .. "off" .. PQ.C.off)
  else
    Help()
  end
end
