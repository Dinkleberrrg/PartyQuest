--[[ PartyQuest -- integration into the default quest log

     1) Side panel to the right of the quest log: shows, for the currently
        selected quest, every group member's progress objective by objective.
     2) Small counter in the quest list: "(2)" = two party members have the
        same quest in their log.

     Deliberately without XML and without hard dependencies on FrameXML
     internals: if EQL3 / ShaguQuest / DragonflightUI replace the quest log,
     whichever frame exists is used, or the feature quietly skips itself.
]]--

local PQ = PartyQuest

local PANEL_WIDTH = 224
local LINE_HEIGHT = 12
local MAX_LINES   = 34

--------------------------------------------------------------------------
-- Which quest log frame is in play?
--------------------------------------------------------------------------
local function GetQuestLogFrame()
  if EQL3_QuestLogFrame then return EQL3_QuestLogFrame end
  if ShaguQuest_QuestLogFrame then return ShaguQuest_QuestLogFrame end
  return QuestLogFrame
end

local function GetSelection()
  if EQL3_QuestLogFrame and EQL3_GetQuestLogSelection then return EQL3_GetQuestLogSelection() end
  if GetQuestLogSelection then return GetQuestLogSelection() end
  return nil
end

--------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------
local panel = CreateFrame("Frame", "PartyQuestPanel", UIParent)
panel:SetWidth(PANEL_WIDTH)
panel:SetHeight(120)
panel:SetFrameStrata("HIGH")
panel:Hide()

panel:SetBackdrop({
  bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
})

panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
panel.title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -10)
panel.title:SetJustifyH("LEFT")
panel.title:SetText(PQ.C.head .. "Party Progress")

panel.lines = {}
local function GetLine(i)
  if not panel.lines[i] then
    local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -24 - (i - 1) * LINE_HEIGHT)
    fs:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -24 - (i - 1) * LINE_HEIGHT)
    fs:SetJustifyH("LEFT")
    fs:SetHeight(LINE_HEIGHT)
    panel.lines[i] = fs
  end
  return panel.lines[i]
end

--------------------------------------------------------------------------
-- Building the lines for one quest
--------------------------------------------------------------------------

-- Order: yourself (optional) first, then the group alphabetically.
local function SortedMembers()
  local names, n = {}, 0
  for name in pairs(PQ.roster) do
    n = n + 1
    names[n] = name
  end
  table.sort(names, function(a, b) return a < b end)
  return names, n
end

-- Fallback label: if the sender had to drop the label, we use our own from
-- the same objective index.
local function OwnLabel(qlogid, index)
  if not qlogid then return nil end
  local text = GetQuestLogLeaderBoard(index, qlogid)
  if not text then return nil end
  local normalized = gsub(text, "\239\188\154", ":")
  local _, _, label = strfind(normalized, "(.*):%s*%d+%s*/%s*%d+")
  return PQ.Clean(label or normalized)
end

local function AppendQuestLines(out, n, q, qlogid)
  if not q then return n end

  if q.complete == 1 then
    n = n + 1
    out[n] = "    " .. PQ.C.green .. "Ready to turn in" .. PQ.C.off
    return n
  end

  if q.complete == -1 then
    n = n + 1
    out[n] = "    " .. PQ.C.red .. "Failed" .. PQ.C.off
    return n
  end

  if (q.objCount or 0) == 0 then
    n = n + 1
    out[n] = "    " .. PQ.C.grey .. "no objectives" .. PQ.C.off
    return n
  end

  for i = 1, q.objCount do
    local o = q.obj[i]
    if o then
      -- Our own log has the untruncated text -- that one wins. Only when we
      -- do not have the quest ourselves do we fall back to the sender's
      -- label (truncated to 22 bytes).
      local label = OwnLabel(qlogid, i)
      if not label or label == "" then label = o.label end
      if not label or label == "" then label = "Objective " .. i end
      local color = PQ.ProgressColor(o.done == 1 and o.req or o.cur, o.req)
      local value
      if o.req <= 1 then
        value = (o.done == 1) and "done" or "open"
      else
        value = (o.done == 1 and o.req or o.cur) .. "/" .. o.req
      end
      n = n + 1
      out[n] = "    " .. PQ.C.grey .. PQ.Truncate(label, 26) .. PQ.C.off
        .. "  " .. color .. value .. PQ.C.off
    end
  end
  return n
end

-- Builds the complete line list for the currently selected quest.
local function BuildPanelLines(qlogid, title, key)
  local out, n = {}, 0

  -- own state
  if PQ.db.self == "1" then
    local mine = PQ.mine[key]
    if not mine and title then
      for _, q in pairs(PQ.mine) do
        if q.title == title then mine = q break end
      end
    end
    n = n + 1
    out[n] = PQ.ClassColor(UnitName("player")) .. "You" .. PQ.C.off
    n = AppendQuestLines(out, n, mine, qlogid)
  end

  local names, count = SortedMembers()
  if count == 0 then
    n = n + 1
    if PQ.InGroup() == "RAID" and PQ.db.raid == "off" then
      out[n] = PQ.C.grey .. "Raid sync is off (/pq raid)." .. PQ.C.off
    elseif PQ.InGroup() then
      out[n] = PQ.C.grey .. "Nobody else in your group." .. PQ.C.off
    else
      out[n] = PQ.C.grey .. "Not in a group." .. PQ.C.off
    end
    return out, n
  end

  for i = 1, count do
    local name = names[i]
    local member = PQ.party[name]
    n = n + 1
    out[n] = PQ.ClassColor(name) .. name .. PQ.C.off

    if not member or not member.version then
      n = n + 1
      out[n] = "    " .. PQ.C.grey .. "PartyQuest not installed" .. PQ.C.off
    else
      local q = PQ.FindQuest(member, key, title)
      if not q then
        n = n + 1
        out[n] = "    " .. PQ.C.grey .. "does not have this quest" .. PQ.C.off
      else
        n = AppendQuestLines(out, n, q, qlogid)
      end
    end

    if n >= MAX_LINES then break end
  end

  return out, n
end

--------------------------------------------------------------------------
-- Draw the panel
--------------------------------------------------------------------------
function PQ.RefreshPanel()
  local qlf = GetQuestLogFrame()
  if not qlf or not qlf:IsShown() or PQ.db.questlog ~= "1" then
    panel:Hide()
    return
  end

  local sel = GetSelection()
  local title, level, tag, header
  if sel and sel > 0 then
    title, level, tag, header = GetQuestLogTitle(sel)
  end

  if not title or header then
    panel:Hide()
    return
  end

  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", qlf, "TOPRIGHT", -33, -12)

  local key = PQ.QuestKey(sel, title)
  local lines, n = BuildPanelLines(sel, title, key)

  panel.title:SetText(PQ.C.head .. "Party" .. PQ.C.off .. " " .. PQ.C.grey
    .. PQ.Truncate(title, 22) .. PQ.C.off)

  for i = 1, n do
    GetLine(i):SetText(lines[i])
    GetLine(i):Show()
  end
  local total = table.getn(panel.lines)
  for i = n + 1, total do
    panel.lines[i]:Hide()
  end

  panel:SetHeight(30 + n * LINE_HEIGHT + 8)
  panel:Show()
end

--------------------------------------------------------------------------
-- Counter in the quest list
--------------------------------------------------------------------------
-- Shows behind each quest title how many party members also have it.
function PQ.UpdateRows()
  if not PQ.db or PQ.db.rows ~= "1" then return end
  local displayed = QUESTS_DISPLAYED or 6

  for i = 1, displayed do
    local btn = getglobal("QuestLogTitle" .. i)
    if btn then
      if not btn.pqTag then
        btn.pqTag = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.pqTag:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        btn.pqTag:SetJustifyH("RIGHT")
      end
      btn.pqTag:SetText("")

      if btn:IsShown() then
        local qlogid = btn:GetID()
        local title, _, _, header = GetQuestLogTitle(qlogid)
        if title and not header then
          local key = PQ.QuestKey(qlogid, title)
          local shared, done = 0, 0
          for name, member in pairs(PQ.party) do
            if PQ.roster[name] then
              local q = PQ.FindQuest(member, key, title)
              if q then
                shared = shared + 1
                if q.complete == 1 then done = done + 1 end
              end
            end
          end
          if shared > 0 then
            local color = (done == shared) and PQ.C.green or PQ.C.head
            btn.pqTag:SetText(color .. shared .. PQ.C.off)
          end
        end
      end
    end
  end
end

--------------------------------------------------------------------------
-- Driver: polls visibility, selection and data revision
--------------------------------------------------------------------------
local driver = CreateFrame("Frame", "PartyQuestUIDriver", UIParent)
driver.next = 0
driver:SetScript("OnUpdate", function()
  if not PQ.db then return end
  if GetTime() < driver.next then return end
  driver.next = GetTime() + 0.2

  local qlf = GetQuestLogFrame()
  local shown = qlf and qlf:IsShown() and 1 or 0
  local sel = GetSelection() or 0

  if shown ~= driver.shown or sel ~= driver.sel or PQ.dataRev ~= driver.rev then
    driver.shown, driver.sel, driver.rev = shown, sel, PQ.dataRev
    PQ.RefreshPanel()
    if shown == 1 then PQ.UpdateRows() end
  end
end)

--------------------------------------------------------------------------
-- Hook QuestLog_Update so the counters follow when scrolling
--------------------------------------------------------------------------
local hooked = CreateFrame("Frame", "PartyQuestHookInit", UIParent)
hooked:RegisterEvent("PLAYER_ENTERING_WORLD")
hooked:SetScript("OnEvent", function()
  if hooked.done then return end
  hooked.done = true
  if type(QuestLog_Update) == "function" then
    local original = QuestLog_Update
    QuestLog_Update = function()
      original()
      if PQ.db and PQ.db.rows == "1" then PQ.UpdateRows() end
    end
    PQ.Debug("hooked QuestLog_Update")
  end
end)

PQ.panel = panel
