--[[ PartyQuest -- scan
     Reads your own quest log and turns it into a compact snapshot.
]]--

local PQ = PartyQuest

--------------------------------------------------------------------------
-- Quest key
--------------------------------------------------------------------------
-- Prefers the numeric quest id from the pfQuest database because that is
-- identical on every client. Without pfQuest we fall back to a hash of the
-- title; the title is sent along anyway, so the receiver still finds the
-- quest either way (see PQ.FindQuest).
function PQ.QuestKey(qlogid, title)
  if pfDatabase and pfDatabase.GetQuestIDs then
    local ok, ids = pcall(function() return pfDatabase:GetQuestIDs(qlogid) end)
    if ok and type(ids) == "table" and ids[1] and tonumber(ids[1]) then
      return "q" .. tonumber(ids[1])
    end
  end
  return "t" .. PQ.Hash(title or "")
end

--------------------------------------------------------------------------
-- Read a quest's objectives
--------------------------------------------------------------------------
-- GetQuestLogLeaderBoard returns text like "Kobold Miner slain: 3/8".
-- Some servers hand back a fullwidth colon (zhCN) or empty rows -- both
-- are handled here.
local function ReadObjectives(qlogid)
  local out, count = {}, 0
  local num = GetNumQuestLeaderBoards(qlogid) or 0
  for i = 1, num do
    local text, otype, done = GetQuestLogLeaderBoard(i, qlogid)
    if text then
      local normalized = gsub(text, "\239\188\154", ":")
      local _, _, label, cur, req = strfind(normalized, "(.*):%s*(%d+)%s*/%s*(%d+)")
      count = count + 1
      if cur and req then
        out[count] = {
          label = PQ.Clean(label),
          cur   = tonumber(cur) or 0,
          req   = tonumber(req) or 1,
          done  = (done and 1) or 0,
        }
      else
        -- Objective without a counter (e.g. "Speak to X") -> 0/1 or 1/1
        out[count] = {
          label = PQ.Clean(normalized),
          cur   = (done and 1) or 0,
          req   = 1,
          done  = (done and 1) or 0,
        }
      end
    end
  end
  return out, count
end

--------------------------------------------------------------------------
-- State string (basis for change detection)
--------------------------------------------------------------------------
function PQ.StateString(q)
  local parts, n = {}, 0
  n = n + 1; parts[n] = q.complete or 0
  for i = 1, q.objCount do
    local o = q.obj[i]
    n = n + 1; parts[n] = o.cur .. "/" .. o.req .. (o.done == 1 and "d" or "t")
  end
  return table.concat(parts, ",")
end

--------------------------------------------------------------------------
-- Overall progress of a quest, in percent
--------------------------------------------------------------------------
function PQ.QuestProgress(q)
  if not q then return 0, 0, 0 end
  if q.complete == 1 then return 1, 1, 100 end
  local cur, req = 0, 0
  for i = 1, (q.objCount or 0) do
    local o = q.obj[i]
    if o then
      cur = cur + (o.done == 1 and o.req or o.cur)
      req = req + o.req
    end
  end
  if req <= 0 then return 0, 0, 0 end
  return cur, req, cur / req * 100
end

--------------------------------------------------------------------------
-- Build a full quest log snapshot
--------------------------------------------------------------------------
-- Vanilla quirk: quests under a collapsed zone header are not returned by
-- GetQuestLogTitle at all. If we find fewer quests than
-- GetNumQuestLogEntries reports, the scan is incomplete -- in that case we
-- keep the old state instead of wrongly broadcasting "quest turned in".
function PQ.ScanQuestLog()
  local snap = {}
  local _, numQuests = GetNumQuestLogEntries()
  numQuests = numQuests or 0
  local found = 0

  for qlogid = 1, 50 do
    -- 1.12: title, level, questTag, isHeader, isCollapsed, isComplete
    local title, level, tag, header, collapsed, complete = GetQuestLogTitle(qlogid)

    if header then
      -- skip headers
    elseif title then
      local key = PQ.QuestKey(qlogid, title)
      local obj, objCount = ReadObjectives(qlogid)
      local q = {
        title    = title,
        level    = tonumber(level) or 0,
        complete = (complete and 1) or 0,
        obj      = obj,
        objCount = objCount,
        qlogid   = qlogid,
      }
      q.state = PQ.StateString(q)
      snap[key] = q

      found = found + 1
      if numQuests > 0 and found >= numQuests then break end
    end
  end

  local partial = (numQuests > 0 and found < numQuests) and true or nil
  return snap, partial
end

--------------------------------------------------------------------------
-- Update our own state and report what changed
--------------------------------------------------------------------------
-- Returns: changed = { [key] = questdata }, removed = { key, key, ... }
function PQ.DiffOwnQuestlog()
  local snap, partial = PQ.ScanQuestLog()
  local changed, removed, nRemoved = {}, {}, 0

  for key, q in pairs(snap) do
    local old = PQ.mine[key]
    if not old or old.state ~= q.state or old.title ~= q.title then
      changed[key] = q
    end
  end

  if not partial then
    for key in pairs(PQ.mine) do
      if not snap[key] then
        nRemoved = nRemoved + 1
        removed[nRemoved] = key
      end
    end
    PQ.mine = snap
  else
    -- Incomplete scan: only refresh the quests we actually found.
    PQ.Debug("incomplete scan (collapsed header?) -- skipping prune")
    for key, q in pairs(snap) do PQ.mine[key] = q end
  end

  return changed, removed, nRemoved
end
