local ProximityInventory = require("ProximityInventory/ProximityInventory")

local old_ISInventoryPage_onBackpackRightMouseDown = ISInventoryPage.onBackpackRightMouseDown
function ISInventoryPage:onBackpackRightMouseDown(x, y)
  local container = self.inventory

  if container and container:getType() == "proxInv" then
    local page = self.parent and self.parent.parent
    local playerNum = (page and page.player) or 0

    local context = ISContextMenu.get(playerNum, getMouseX(), getMouseY())
    if not context then return end

    local highlightIcon   = getTexture("media/textures/Item_LightBulb.png")

    local isHighlight = ProximityInventory.isHighlightEnableOption:getValue()
    local highlightText = isHighlight
      and getText("IGUI_ProxInv_Context_HighlightOn")
      or  getText("IGUI_ProxInv_Context_HighlightOff")
    local optHighlight = context:addOption(highlightText, nil, function()
      ProximityInventory.isHighlightEnableOption:setValue(not ProximityInventory.isHighlightEnableOption:getValue())
      PZAPI.ModOptions:save()
      ISInventoryPage.dirtyUI()
    end)
    optHighlight.iconTexture = isHighlight and highlightIcon or nil

    return
  end

  return old_ISInventoryPage_onBackpackRightMouseDown(self, x, y)
end

-- Sticky selection: selecting any real container through selectContainer() -- a UI tab click
-- (onBackpackClick), a world-container click, the scroll wheel, keyboard prev/next -- releases the
-- proxInv tab; selecting the proxInv tab locks it.
--
-- EXCEPTION: while you take items from the proxInv tab, ISInventoryTransferAction keeps re-selecting
-- the item's source container (its update()/perform() call selectButtonForContainer). That's not the
-- player choosing a tab. We flag the loot page only for the duration of those transfer methods and
-- skip the release while flagged -- genuine selections aren't inside a transfer, so they're untouched.
local old_ISInventoryPage_selectContainer = ISInventoryPage.selectContainer
function ISInventoryPage:selectContainer(button)
  if button and button.inventory and not self._proxInvProgrammatic then
    local playerNum = self.player or 0
    ProximityInventory.stickSelected[playerNum] =
      (button.inventory:getType() == "proxInv") or nil
  end

  return old_ISInventoryPage_selectContainer(self, button)
end

local function proxInvRunGuarded(action, orig)
  local loot = getPlayerLoot and action.character and getPlayerLoot(action.character:getPlayerNum())
  if loot then loot._proxInvProgrammatic = true end
  local ok, err = pcall(orig, action)
  if loot then loot._proxInvProgrammatic = false end
  if not ok then error(err, 0) end
end

local old_ISInventoryTransferAction_update = ISInventoryTransferAction.update
function ISInventoryTransferAction:update() proxInvRunGuarded(self, old_ISInventoryTransferAction_update) end

local old_ISInventoryTransferAction_perform = ISInventoryTransferAction.perform
function ISInventoryTransferAction:perform() proxInvRunGuarded(self, old_ISInventoryTransferAction_perform) end

local old_ISInventoryPage_update = ISInventoryPage.update
function ISInventoryPage:update()
  old_ISInventoryPage_update(self)

  if not ProximityInventory.isEnabled:getValue() or self.onCharacter then return end

  -- I know I kept some good separation between the mod code and the game code, 
  -- but just injecting the table is is SOO much simpler, so I'll just inject it here
  self.coloredProxInventories = self.coloredProxInventories or {}

  for i=#self.coloredProxInventories, 1, -1 do
    local parent = self.coloredProxInventories[i]:getParent()
    if parent then
      parent:setHighlighted(self.player, false)
      parent:setOutlineHighlight(self.player, false);
      parent:setOutlineHlAttached(self.player, false);
    end
    self.coloredProxInventories[i]=nil
  end

  if not ProximityInventory.isHighlightEnableOption:getValue() or self.isCollapsed or self.inventory:getType() ~= "proxInv" then return end

  for i=1, #self.backpacks do
    local container = self.backpacks[i].inventory
    local parent = container:getParent()
    if parent and (instanceof(parent, "IsoObject") or instanceof(parent, "IsoDeadBody")) then
      parent:setHighlighted(self.player, true, false)
      parent:setHighlightColor(self.player, getCore():getObjectHighlitedColor())
      self.coloredProxInventories[#self.coloredProxInventories+1] = container
    end
  end
end

-- ── BaseInv: remember where items came from, send them home on drag-back ─────────────
-- Shared between Proximity Inventory and Safehouse Inventory (same modData key + helpers). Defined
-- once; whichever mod loads first sets it up, the other reuses it.
BaseInv = BaseInv or {}
if not BaseInv._init then
    BaseInv._init = true

    function BaseInv.findOriginContainer(origin)
        if not (origin and origin.x) then return nil end
        local cell = getCell()
        local sq = cell and cell:getGridSquare(origin.x, origin.y, origin.z)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local c = o and o:getContainer()
            if c and (not origin.type or c:getType() == origin.type) then return c end
        end
        return nil
    end

    function BaseInv.returnDropped(page, fallbackFn)
        local playerObj = getSpecificPlayer(page.player)
        pcall(function()
            if not playerObj or not ISMouseDrag.dragging then return end
            local dragging = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
            if not dragging then return end
            local groups, order = {}, {}
            for _, item in ipairs(dragging) do
                local md = item.getModData and item:getModData()
                local target = BaseInv.findOriginContainer(md and md.BaseInv_origin) or (fallbackFn and fallbackFn(playerObj, page))
                if target and target:getParent() then
                    if not groups[target] then groups[target] = {}; order[#order + 1] = target end
                    table.insert(groups[target], item)
                end
            end
            for _, target in ipairs(order) do
                if luautils.walkAdjObject(playerObj, target:getParent(), true, true) then
                    for _, item in ipairs(groups[target]) do
                        ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, item, item:getContainer(), target, nil))
                    end
                end
            end
        end)
        if ISMouseDrag.draggingFocus then
            ISMouseDrag.draggingFocus:onMouseUp(0, 0)
            ISMouseDrag.draggingFocus = nil
        end
        ISMouseDrag.dragging = nil
        pcall(function() page.inventoryPane.selected = {} end)
        return true
    end

    if not BaseInv._stampPatched and ISInventoryTransferAction then
        BaseInv._stampPatched = true
        local _origTAPerform = ISInventoryTransferAction.perform
        function ISInventoryTransferAction:perform()
            pcall(function()
                local it = self.item
                local cont = it and it:getContainer()
                if it and cont and self.character and self.destContainer
                    and self.destContainer:getOutermostContainer() == self.character:getInventory() then
                    local obj = cont:getParent()
                    local sq = obj and obj.getSquare and obj:getSquare()
                    if sq then
                        it:getModData().BaseInv_origin = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), type = cont:getType() }
                    end
                end
            end)
            return _origTAPerform(self)
        end
    end
end

-- Drop onto the Proximity Inventory tab -> send items home (origin crate, else nearest nearby crate).
local function ProxInv_nearest(playerObj, page)
    local best, bestD = nil, math.huge
    for i = 1, #(page.backpacks or {}) do
        local c = page.backpacks[i].inventory
        local t = c and c:getType()
        if c and t ~= "proxInv" and t ~= "floor" and t ~= "safehouseInv" and t ~= "safehouseInvZone" then
            local o = c:getParent()
            local sq = o and o.getSquare and o:getSquare()
            if sq then
                local d = sq:DistToProper(playerObj)
                if d < bestD then bestD = d; best = c end
            end
        end
    end
    return best
end

local old_ISInventoryPage_dropItemsInContainer = ISInventoryPage.dropItemsInContainer
function ISInventoryPage:dropItemsInContainer(button)
    if ProximityInventory.isEnabled:getValue() and ISMouseDrag.dragging and button and button.inventory
        and button.inventory:getType() == "proxInv" then
        return BaseInv.returnDropped(self, ProxInv_nearest)
    end
    return old_ISInventoryPage_dropItemsInContainer(self, button)
end
