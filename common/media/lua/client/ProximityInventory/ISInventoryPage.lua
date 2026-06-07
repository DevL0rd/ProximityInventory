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

-- Sticky selection, handled generically: every way a container becomes selected routes
-- through selectContainer() -- clicking a tab in the UI (onBackpackClick), clicking a
-- container in the WORLD (ISInventoryTransferAction -> selectButtonForContainer), the
-- scroll wheel, and keyboard prev/next. Hooking here (instead of onBackpackMouseDown,
-- which only fires for UI tab clicks) means selecting a real container ALWAYS releases
-- the proxInv tab, no matter how the selection was made.
local old_ISInventoryPage_selectContainer = ISInventoryPage.selectContainer
function ISInventoryPage:selectContainer(button)
  if button and button.inventory then
    local playerNum = self.player or 0
    ProximityInventory.stickSelected[playerNum] =
      (button.inventory:getType() == "proxInv") or nil
  end

  return old_ISInventoryPage_selectContainer(self, button)
end

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
