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

    function BaseInv.returnDropped(playerNum, fallbackFn)
        local playerObj = getSpecificPlayer(playerNum)
        pcall(function()
            if not playerObj or not ISMouseDrag.dragging then return end
            local dragging = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
            if not dragging then return end
            local groups, order = {}, {}
            for _, item in ipairs(dragging) do
                local md = item.getModData and item:getModData()
                local target = BaseInv.findOriginContainer(md and md.BaseInv_origin) or (fallbackFn and fallbackFn(playerObj))
                if target and target:getParent() then
                    if not groups[target] then groups[target] = {}; order[#order + 1] = target end
                    table.insert(groups[target], item)
                end
            end
            -- Visit the destination crates as a nearest-neighbour route from where we stand, penalising
            -- other floors so we finish our own floor before trekking up/down the stairs (the walk itself
            -- still pathfinds fine). keepActions=true appends each walk so the legs don't wipe each other.
            local FLOOR_PENALTY = 50
            local curX, curY, curZ = playerObj:getX(), playerObj:getY(), math.floor(playerObj:getZ())
            while #order > 0 do
                local bestIdx, bestD = 1, math.huge
                for idx = 1, #order do
                    local o = order[idx]:getParent()
                    local sq = o and o.getSquare and o:getSquare()
                    local tx, ty, tz = curX, curY, curZ
                    if sq then tx, ty, tz = sq:getX(), sq:getY(), sq:getZ() end
                    local dx, dy = tx - curX, ty - curY
                    local d = math.sqrt(dx * dx + dy * dy) + math.abs(tz - curZ) * FLOOR_PENALTY
                    if d < bestD then bestD = d; bestIdx = idx end
                end
                local target = table.remove(order, bestIdx)
                local o = target:getParent()
                local sq = o and o.getSquare and o:getSquare()
                if luautils.walkAdjObject(playerObj, o, true, true) then
                    for _, item in ipairs(groups[target]) do
                        ISTimedActionQueue.add(ISInventoryTransferAction:new(playerObj, item, item:getContainer(), target, nil))
                    end
                end
                if sq then curX, curY, curZ = sq:getX(), sq:getY(), sq:getZ() end
            end
        end)
        if ISMouseDrag.draggingFocus then
            ISMouseDrag.draggingFocus:onMouseUp(0, 0)
            ISMouseDrag.draggingFocus = nil
        end
        ISMouseDrag.dragging = nil
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

    -- Auto-walk to a far source crate when TAKING items out (covers drag, double-click, multi-select).
    -- A normal transfer only reaches containers within ~2.5 tiles, so taking from a distant crate
    -- silently fails. Here we queue a walk to the crate before the transfer is queued; once the player
    -- is adjacent the crate becomes reachable and the transfer goes through.
    if not BaseInv._takeWalkPatched and ISInventoryTransferAction then
        BaseInv._takeWalkPatched = true
        local _origTANew = ISInventoryTransferAction.new
        function ISInventoryTransferAction.new(class, character, item, srcContainer, destContainer, ...)
            pcall(function()
                if character and item and destContainer and character.getInventory
                    and destContainer:getOutermostContainer() == character:getInventory() then
                    local cont = item.getContainer and item:getContainer()
                    local obj = cont and cont:getParent()
                    local sq = obj and obj.getSquare and obj:getSquare()
                    if sq and sq:DistToProper(character) > 2.0 then
                        luautils.walkAdjObject(character, obj, true, true)
                    end
                end
            end)
            return _origTANew(class, character, item, srcContainer, destContainer, ...)
        end
    end

    -- Reorder a list of items being taken into the player as a floor-aware nearest-neighbour route, so
    -- grabbing several items spread across crates on different floors collects them a floor at a time
    -- instead of bouncing up and down the stairs in weight order. Sorts the list in place; the per-item
    -- walk wrap above then walks to each crate in this order.
    function BaseInv.routeSortItems(playerNum, items)
        local playerObj = getSpecificPlayer(playerNum)
        if not (playerObj and items and #items >= 2) then return end
        local FLOOR_PENALTY = 50
        local pool = {}
        for _, it in ipairs(items) do
            local cont = it.getContainer and it:getContainer()
            local outer = cont and cont:getOutermostContainer()
            local obj = outer and outer:getParent()
            local sq = obj and obj.getSquare and obj:getSquare()
            pool[#pool + 1] = { item = it, sq = sq }
        end
        local curX, curY, curZ = playerObj:getX(), playerObj:getY(), math.floor(playerObj:getZ())
        for w = 1, #items do
            local bestIdx, bestD = 1, math.huge
            for idx = 1, #pool do
                local p = pool[idx]
                local tx, ty, tz = curX, curY, curZ
                if p.sq then tx, ty, tz = p.sq:getX(), p.sq:getY(), p.sq:getZ() end
                local dx, dy = tx - curX, ty - curY
                local d = math.sqrt(dx * dx + dy * dy) + math.abs(tz - curZ) * FLOOR_PENALTY
                if d < bestD then bestD = d; bestIdx = idx end
            end
            local p = table.remove(pool, bestIdx)
            items[w] = p.item
            if p.sq then curX, curY, curZ = p.sq:getX(), p.sq:getY(), p.sq:getZ() end
        end
    end

    -- True only when a take is worth routing: 2+ distinct source squares and at least one off our floor
    -- or out of reach. Plain nearby single-crate takes keep vanilla's weight order untouched.
    function BaseInv.takeNeedsRoute(playerObj, items)
        if not (playerObj and items and #items >= 2) then return false end
        local pz = math.floor(playerObj:getZ())
        local squares, distinct, far = {}, 0, false
        for _, it in ipairs(items) do
            local cont = it.getContainer and it:getContainer()
            local outer = cont and cont:getOutermostContainer()
            local obj = outer and outer:getParent()
            local sq = obj and obj.getSquare and obj:getSquare()
            if sq then
                if not squares[sq] then squares[sq] = true; distinct = distinct + 1 end
                if sq:getZ() ~= pz or sq:DistToProper(playerObj) > 2.5 then far = true end
            end
        end
        return distinct >= 2 and far
    end

    -- Route-sort the shared take path (multi-select drag, loot-all). We pre-sort, then neutralise
    -- vanilla's weight re-sort for just this call so our order survives into the transfer queue.
    if not BaseInv._takeSortPatched and ISInventoryPane then
        BaseInv._takeSortPatched = true
        local _origTransferByWeight = ISInventoryPane.transferItemsByWeight
        function ISInventoryPane:transferItemsByWeight(items, container)
            local routed = false
            pcall(function()
                local playerObj = getSpecificPlayer(self.player)
                if playerObj and container and container.getOutermostContainer
                    and container:getOutermostContainer() == playerObj:getInventory()
                    and BaseInv.takeNeedsRoute(playerObj, items) then
                    BaseInv.routeSortItems(self.player, items)
                    routed = true
                end
            end)
            if routed then
                self.sortItemsByTypeAndWeight = function() end
                local ok, err = pcall(_origTransferByWeight, self, items, container)
                self.sortItemsByTypeAndWeight = nil
                if not ok then error(err, 0) end
                return
            end
            return _origTransferByWeight(self, items, container)
        end

        -- Double-clicking a stacked row grabs every copy in it. Index 1 of a stack is a dummy duplicate
        -- (see getActualItems), so we route-sort the real items 2..N in place and the vanilla loop then
        -- collects them floor-by-floor.
        local _origDblClick = ISInventoryPane.onMouseDoubleClick
        function ISInventoryPane:onMouseDoubleClick(x, y)
            pcall(function()
                local playerObj = getSpecificPlayer(self.player)
                local row = self.items and self.mouseOverOption and self.items[self.mouseOverOption]
                if playerObj and row and not instanceof(row, "InventoryItem") and row.items and #row.items > 2 then
                    local sub = {}
                    for i = 2, #row.items do sub[#sub + 1] = row.items[i] end
                    if BaseInv.takeNeedsRoute(playerObj, sub) then
                        BaseInv.routeSortItems(self.player, sub)
                        for i = 2, #row.items do row.items[i] = sub[i - 1] end
                    end
                end
            end)
            return _origDblClick(self, x, y)
        end
    end

    -- Right-click "Grab All" funnels through onGrabItems, which flattens its input with getActualItems
    -- in input order. Handing it a route-ordered flat list makes it grab a floor at a time too.
    if not BaseInv._grabPatched and ISInventoryPaneContextMenu then
        BaseInv._grabPatched = true
        local _origGrab = ISInventoryPaneContextMenu.onGrabItems
        if _origGrab then
            ISInventoryPaneContextMenu.onGrabItems = function(items, player)
                pcall(function()
                    local playerObj = getSpecificPlayer(player)
                    local flat = ISInventoryPane.getActualItems(items)
                    if playerObj and BaseInv.takeNeedsRoute(playerObj, flat) then
                        BaseInv.routeSortItems(player, flat)
                        items = flat
                    end
                end)
                return _origGrab(items, player)
            end
        end
    end

    -- Drag-validity highlight: our synthetic tabs reject items via isItemAllowed/hasRoomFor, so the
    -- vanilla drag overlay paints the dragged item red even though our drop handler accepts it (it sends
    -- the item home). Each mod registers a predicate for its tab types; while a drag hovers one of them,
    -- clear the per-item "can't drop" flags so the item shows as a valid drop.
    BaseInv.homeTypePredicates = BaseInv.homeTypePredicates or {}
    function BaseInv.isHomeTabType(t)
        if not t then return false end
        for i = 1, #BaseInv.homeTypePredicates do
            if BaseInv.homeTypePredicates[i](t) then return true end
        end
        return false
    end

    if not BaseInv._dragHLPatched and ISInventoryPaneDraggedItems then
        BaseInv._dragHLPatched = true
        local _origDIUpdate = ISInventoryPaneDraggedItems.update
        function ISInventoryPaneDraggedItems:update()
            _origDIUpdate(self)
            pcall(function()
                local c = self.mouseOverContainer
                if c and c.getType and self.itemNotOK and BaseInv.isHomeTabType(c:getType()) then
                    table.wipe(self.itemNotOK)
                end
            end)
        end
    end
end

BaseInv.homeTypePredicates = BaseInv.homeTypePredicates or {}
table.insert(BaseInv.homeTypePredicates, function(t) return t == "proxInv" end)

-- Drop onto the Proximity Inventory tab -> send items home (origin crate, else nearest nearby crate).
local function ProxInv_nearest(playerObj)
    local page = getPlayerLoot and getPlayerLoot(playerObj:getPlayerNum())
    local backpacks = (page and page.backpacks) or {}
    local best, bestD = nil, math.huge
    for i = 1, #backpacks do
        local c = backpacks[i].inventory
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
        return BaseInv.returnDropped(self.player, ProxInv_nearest)
    end
    return old_ISInventoryPage_dropItemsInContainer(self, button)
end

-- Also catch dropping onto the item LIST (the pane), not just the tab icon.
local old_ISInventoryPane_onMouseUp = ISInventoryPane.onMouseUp
function ISInventoryPane:onMouseUp(x, y)
    if ProximityInventory.isEnabled:getValue() and ISMouseDrag.dragging ~= nil and ISMouseDrag.draggingFocus ~= self
        and ISMouseDrag.draggingFocus ~= nil and self.inventory and self.inventory:getType() == "proxInv" then
        BaseInv.returnDropped(self.player, ProxInv_nearest)
        self.selected = {}
        self.draggingMarquis = false
        return true
    end
    return old_ISInventoryPane_onMouseUp(self, x, y)
end
