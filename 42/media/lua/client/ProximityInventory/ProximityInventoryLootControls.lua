local ProximityInventory = require("ProximityInventory/ProximityInventory")

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

-- Recoge todos los ítems de los contenedores cercanos al inventario del jugador
local function proxInvGrabAll(invSelf)
  local playerNum = invSelf.player
  local playerObj = getSpecificPlayer(playerNum)
  if not playerObj then return end
  local playerInv = playerObj:getInventory()

  for i = 1, #invSelf.backpacks do
    local srcContainer = invSelf.backpacks[i].inventory
    if srcContainer:getType() ~= "proxInv" and ProximityInventory.CanBeAdded(srcContainer, playerObj) then
      if luautils.walkToContainer(srcContainer, playerNum) then
        local items = {}
        local it = srcContainer:getItems()
        for j = 0, it:size() - 1 do
          local item = it:get(j)
          if not item:isUnwanted(playerObj) then
            table.insert(items, item)
          end
        end
        invSelf.inventoryPane:transferItemsByWeight(items, playerInv)
      end
    end
  end
  invSelf.inventoryPane.selected = {}
  getPlayerLoot(playerNum).inventoryPane.selected = {}
  getPlayerInventory(playerNum).inventoryPane.selected = {}
end

-- Transfiere ítems del mismo tipo que los que ya tiene el jugador en su inventario
local function proxInvTakeSameType(invSelf)
  if isGamePaused() then return end
  local playerNum = invSelf.player
  local playerObj = getSpecificPlayer(playerNum)
  if not playerObj then return end
  local playerInv = playerObj:getInventory()

  -- Construye tabla de tipos presentes en el inventario del jugador
  local playerTypes = {}
  local playerItems = playerInv:getItems()
  for i = 0, playerItems:size() - 1 do
    playerTypes[playerItems:get(i):getFullType()] = true
  end

  -- Recoge ítems coincidentes de los contenedores cercanos
  local itemsToTransfer = {}
  for i = 1, #invSelf.backpacks do
    local srcContainer = invSelf.backpacks[i].inventory
    if srcContainer:getType() ~= "proxInv" and ProximityInventory.CanBeAdded(srcContainer, playerObj) then
      local it = srcContainer:getItems()
      for j = 0, it:size() - 1 do
        local item = it:get(j)
        if playerTypes[item:getFullType()] and not item:isFavorite() and not item:isUnwanted(playerObj) then
          table.insert(itemsToTransfer, item)
        end
      end
    end
  end

  if #itemsToTransfer > 0 then
    invSelf.inventoryPane:transferItemsByWeight(itemsToTransfer, playerInv)
  end
  invSelf.inventoryPane.selected = {}
  getPlayerLoot(playerNum).inventoryPane.selected = {}
  getPlayerInventory(playerNum).inventoryPane.selected = {}
end

-- Mueve todos los ítems de los contenedores cercanos al suelo
local function proxInvMoveToFloor(invSelf)
  if isGamePaused() then return end
  local playerNum = invSelf.player
  local floorContainer = ISInventoryPage.GetFloorContainer(playerNum)

  local items = {}
  for i = 1, #invSelf.backpacks do
    local srcContainer = invSelf.backpacks[i].inventory
    if srcContainer:getType() ~= "proxInv" then
      local it = srcContainer:getItems()
      for j = 0, it:size() - 1 do
        table.insert(items, it:get(j))
      end
    end
  end

  ISInventoryPaneContextMenu.onMoveItemsTo(items, floorContainer, playerNum)

  invSelf.inventoryPane.selected = {}
  getPlayerLoot(playerNum).inventoryPane.selected = {}
  getPlayerInventory(playerNum).inventoryPane.selected = {}
end

-- Hookea arrange() para agregar los botones cuando el contenedor activo es proxInv
local old_arrange = ISLootWindowContainerControls.arrange
function ISLootWindowContainerControls:arrange()
  old_arrange(self)

  local container = self.lootWindow and self.lootWindow.inventoryPane and self.lootWindow.inventoryPane.inventory
  if not container or container:getType() ~= "proxInv" then return end

  local invSelf = self.lootWindow
  local hasNearbyContainers = false
  for i = 1, #invSelf.backpacks do
    local t = invSelf.backpacks[i].inventory:getType()
    if t ~= "proxInv" and t ~= "floor" then
      hasNearbyContainers = true
      break
    end
  end
  if not hasNearbyContainers then return end

  local buttonH = 2 + FONT_HGT_SMALL + 2
  local y = 1
  local x = 1
  for _, ctrl in ipairs(self.controls) do
    if ctrl:getRight() + 10 > x then x = ctrl:getRight() + 10 end
  end

  if not self.proxGrabAllBtn then
    local btn = ISButton:new(x, y, 80, buttonH, getText("IGUI_invpage_Loot_all"), self, function() proxInvGrabAll(invSelf) end)
    btn:initialise()
    btn.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    btn:setWidthToTitle()
    self.proxGrabAllBtn = btn
  end
  self.proxGrabAllBtn:setX(x)
  self.proxGrabAllBtn:setY(y)
  self.proxGrabAllBtn:setVisible(true)
  self:addChild(self.proxGrabAllBtn)
  table.insert(self.controls, self.proxGrabAllBtn)
  x = self.proxGrabAllBtn:getRight() + 10

  if not self.proxTakeSameTypeBtn then
    local icon = getTexture("media/ui/inventoryPanes/TakeSameTypeOneContainer.png")
    local hgt = FONT_HGT_SMALL
    local wid = (icon:getWidth() / icon:getHeight()) * hgt
    local btn = ISButton:new(x, y, wid + 2 * 2, hgt + 2 * 2, "", self, function() proxInvTakeSameType(invSelf) end)
    btn:initialise()
    btn.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    btn:setImage(icon)
    btn:forceImageSize(wid, hgt)
    btn:setTooltip(getText("IGUI_invpage_Loot_TakeSameType_tt"))
    self.proxTakeSameTypeBtn = btn
  end
  self.proxTakeSameTypeBtn:setX(x)
  self.proxTakeSameTypeBtn:setY(y)
  self.proxTakeSameTypeBtn:setVisible(true)
  self:addChild(self.proxTakeSameTypeBtn)
  table.insert(self.controls, self.proxTakeSameTypeBtn)
  x = self.proxTakeSameTypeBtn:getRight() + 10

  local moveToFloorText = getTextOrNull("ContextMenu_MoveToFloor") or "Move To Floor"
  if not self.proxMoveToFloorBtn then
    local btn = ISButton:new(x, y, 110, buttonH, moveToFloorText, self, function() proxInvMoveToFloor(invSelf) end)
    btn:initialise()
    btn.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    btn:setWidthToTitle()
    self.proxMoveToFloorBtn = btn
  end
  self.proxMoveToFloorBtn:setX(x)
  self.proxMoveToFloorBtn:setY(y)
  self.proxMoveToFloorBtn:setVisible(true)
  self:addChild(self.proxMoveToFloorBtn)
  table.insert(self.controls, self.proxMoveToFloorBtn)

  self:setHeight(math.max(self:getHeight(), y + buttonH + 1))
  self:setVisible(true)
end
