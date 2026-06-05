local ProximityInventory = {}

-- Options
ProximityInventory.options = PZAPI.ModOptions:create("ProximityInventory", "Proximity Inventory")

ProximityInventory.isEnabled = ProximityInventory.options:addTickBox(
  "ProximityInventory_isEnabled",
  getText("UI_optionscreen_binding_ProximityInventory_isEnabled"),
  true
)

ProximityInventory.toggleEnabledOption = ProximityInventory.options:addKeyBind(
  "ProximityInventory_toggleEnabled",
  getText("UI_optionscreen_binding_ProximityInventory_toggleEnabled"),
  Keyboard.KEY_NUMPAD1
)

ProximityInventory.isHighlightEnableOption = ProximityInventory.options:addTickBox(
  "ProximityInventory_isHighlightEnableOption",
  getText("UI_optionscreen_binding_ProximityInventory_isHighlightEnableOption"),
  true
)

-- Consts
ProximityInventory.inventoryIcon = getTexture("media/ui/ProximityInventory.png")

---@type { [number]: ItemContainer? }
ProximityInventory.itemContainer = {}
---@type { [number]: ISButton? } -- Reference of the button in the UI for each player
ProximityInventory.inventoryButtonRef = {}
---@type { [number]: boolean? } -- true while the proxInv tab is the player's current selection
-- Sticky selection: instead of a manual force-select pin, the proxInv tab stays selected across
-- refreshes once you click it, and is released when you click (or scroll to) a real container.
ProximityInventory.stickSelected = {}

---@param container ItemContainer
---@param playerObj IsoPlayer
function ProximityInventory.CanBeAdded(container, playerObj)
  local object = container:getParent()

  if SandboxVars.ProximityInventory.ZombieOnly then
    return container:getType() == "inventoryfemale" or container:getType() == "inventorymale"
  end

  -- Don't allow to see inside containers locked to you, for MP
  if object and instanceof(object, "IsoThumpable") and object:isLockedToCharacter(playerObj) then
    return false
  end

  return true
end

---@param playerNum number
function ProximityInventory.GetItemContainer(playerNum)
  if ProximityInventory.itemContainer[playerNum] then
    return ProximityInventory.itemContainer[playerNum]
  end

  ProximityInventory.itemContainer[playerNum] = ItemContainer.new("proxInv", nil, nil)
  ProximityInventory.itemContainer[playerNum]:setExplored(true)
  ProximityInventory.itemContainer[playerNum]:setOnlyAcceptCategory("none") -- Ensures you can't put stuff in it
  ProximityInventory.itemContainer[playerNum]:setCapacity(0)                -- Makes the UI Render the weight as XXX/0 instead of the default XXX/50

  return ProximityInventory.itemContainer[playerNum]
end

---@param invSelf ISInventoryPage
---@return ISButton
function ProximityInventory.AddProximityInventoryButton(invSelf)
  local itemContainer = ProximityInventory.GetItemContainer(invSelf.player)
  itemContainer:clear() -- We want to reset the proxinv between refreshes

  local title = getText("IGUI_ProxInv_InventoryName")

  if getSpecificPlayer(invSelf.player):getVehicle() then
    title = title .. " - " .. getText("GameSound_Category_Vehicle")
  end

  local proxInvButton = invSelf:addContainerButton(
    itemContainer,
    ProximityInventory.inventoryIcon,
    title
  )

  return proxInvButton
end

---Adds the button at the top of the list of the containers, so that it always appears as first
---@param invSelf ISInventoryPage
-- ─── Patch onMouseWheel for the loot ISInventoryPage instance ────────────────
-- When the proxInv tab is the sticky selection, OnRefreshEnd forces invSelf.inventory to the
-- proxInv container.  The vanilla getCurrentBackpackIndex() looks for self.inventory inside
-- self.backpacks, but proxInv is a synthetic container that is never a real backpack entry, so
-- it always returns -1.  onMouseWheel then sees index -1 and may propagate the event to the
-- camera as zoom.  Fix: resolve the current index from self.selectedButton instead, and consume
-- the event when the mouse is over the icon column.
local function patchMouseWheel(invSelf, playerNum)
  if invSelf._proxInvMouseWheelPatched then return end
  invSelf._proxInvMouseWheelPatched = true

  local _origOnMouseWheel = invSelf.onMouseWheel
  invSelf.onMouseWheel = function(self, del)
    -- Only intercept when the proxInv tab is the sticky selection and this is the loot window
    if not ProximityInventory.isEnabled:getValue()
      or not ProximityInventory.stickSelected[playerNum]
      or self.onCharacter
    then
      return _origOnMouseWheel(self, del)
    end

    -- Gate: only act when the mouse is over the icon column.
    -- CleanUI can place the panel on either side (isPageLeft), vanilla always right.
    local inContainerArea
    if self.isPageLeft then
      if self:isPageLeft() then
        inContainerArea = self:getMouseX() < self.containerButtonPanel.width
      else
        inContainerArea = self:getMouseX() >= (self:getWidth() - self.containerButtonPanel.width)
      end
    else
      -- Vanilla layout: icon column is always the rightmost buttonSize pixels
      inContainerArea = self:getMouseX() >= (self:getWidth() - self.buttonSize)
    end

    if not inContainerArea and not self:isCycleContainerKeyDown() then
      -- Consume the event so it does NOT propagate to the camera as zoom.
      return true
    end

    local currentIndex = -1
    if self.selectedButton then
      for i = 1, #self.backpacks do
        if self.backpacks[i] == self.selectedButton then
          currentIndex = i
          break
        end
      end
    end

    local ms = getTimestampMs()
    self.lastMouseWheelMS = self.lastMouseWheelMS or 0
    local wrap = (self.containerButtonPanel.height > self.containerButtonPanel:getScrollHeight())
              or (ms - self.lastMouseWheelMS > 750)
    self.lastMouseWheelMS = ms

    local unlockedIndex = -1
    if del < 0 then
      unlockedIndex = self:prevUnlockedContainer(currentIndex, wrap)
    else
      unlockedIndex = self:nextUnlockedContainer(currentIndex, wrap)
    end

    if unlockedIndex ~= -1 then
      local targetContainer = self.backpacks[unlockedIndex].inventory
      -- scrolling onto/off the proxInv tab updates the sticky selection
      ProximityInventory.stickSelected[playerNum] =
        (targetContainer == ProximityInventory.itemContainer[playerNum]) or nil
      self:selectContainer(self.backpacks[unlockedIndex])
    end

    return true
  end
end
-- ─────────────────────────────────────────────────────────────────────────────

function ProximityInventory.OnBeginRefresh(invSelf)
  -- Patch onMouseWheel so scroll works correctly when the proxInv tab is sticky.
  patchMouseWheel(invSelf, invSelf.player)

  -- If ZombieOnly is enabled, defer button creation to OnButtonsAdded, where
  -- the backpacks list is already populated and we can check for zombie bodies.
  if SandboxVars.ProximityInventory.ZombieOnly then
    ProximityInventory.inventoryButtonRef[invSelf.player] = nil
    return
  end

  local proxInvButton = ProximityInventory.AddProximityInventoryButton(invSelf)

  -- We will need this ref for after the button are added
  ProximityInventory.inventoryButtonRef[invSelf.player] = proxInvButton
end

---@param invSelf ISInventoryPage
function ProximityInventory.OnButtonsAdded(invSelf)
  local playerNum = invSelf.player --[[@as number]]
  local playerObj = getSpecificPlayer(invSelf.player)

  -- If ZombieOnly is enabled, create the button here only if there is at least
  -- one zombie body nearby — backpacks is fully populated at this point.
  if SandboxVars.ProximityInventory.ZombieOnly then
    local hasZombieBody = false
    for i = 1, #invSelf.backpacks do
      local t = invSelf.backpacks[i].inventory:getType()
      if t == "inventoryfemale" or t == "inventorymale" then
        hasZombieBody = true
        break
      end
    end
    if not hasZombieBody then return end

    local proxInvButton = ProximityInventory.AddProximityInventoryButton(invSelf)
    ProximityInventory.inventoryButtonRef[playerNum] = proxInvButton
  end

  local proximityButtonRef = ProximityInventory.inventoryButtonRef[playerNum]
  if not proximityButtonRef then return end -- something must have gone wrong if this returns here

  -- Add all nearby containers except virtual ones (proxInv itself, CleanUI's local, etc.)
  for i = 1, #invSelf.backpacks do
    local invToAdd = invSelf.backpacks[i].inventory
    local containerType = invToAdd:getType()
    if invToAdd ~= ProximityInventory.itemContainer[playerNum]
      and containerType ~= "proxInv"
      and containerType ~= "local"
      and ProximityInventory.CanBeAdded(invToAdd, playerObj)
    then
      local items = invToAdd:getItems()
      proximityButtonRef.inventory:getItems():addAll(items)
    end
  end
end

-- Keep the proxInv tab selected across refreshes while it is the sticky selection.
function ProximityInventory.OnRefreshEnd(invSelf)
  local playerNum = invSelf.player --[[@as number]]
  if not ProximityInventory.stickSelected[playerNum] then return end

  local proximityButtonRef = ProximityInventory.inventoryButtonRef[playerNum]
  if not proximityButtonRef then
    -- proxInv tab isn't present this refresh (e.g. nothing nearby); release the stick.
    ProximityInventory.stickSelected[playerNum] = nil
    return
  end

  local targetContainer = proximityButtonRef.inventory

  invSelf.inventoryPane.inventory = targetContainer
  invSelf.inventoryPane.lastinventory = targetContainer
  invSelf.inventory = targetContainer

  invSelf.title = nil
  for _, containerButton in ipairs(invSelf.backpacks) do
    if containerButton.inventory == targetContainer then
      invSelf.selectedButton = containerButton
      containerButton:setBackgroundRGBA(0.7, 0.7, 0.7, 1.0)
      invSelf.title = containerButton.name
    else
      containerButton:setBackgroundRGBA(0.0, 0.0, 0.0, 0.0)
    end
  end

  if invSelf.inventoryPane then
    invSelf.inventoryPane:refreshContainer()
  end
end

function ProximityInventory.OnToggle()
  ProximityInventory.isEnabled:setValue(not ProximityInventory.isEnabled:getValue())
  PZAPI.ModOptions:save()

  ISInventoryPage.dirtyUI() -- Let's force a reset of the UI
end

Events.OnKeyPressed.Add(function(key)
  if not getPlayer() then return end
  if key == ProximityInventory.toggleEnabledOption:getValue() then
    return ProximityInventory.OnToggle()
  end
end);


Events.OnRefreshInventoryWindowContainers.Add(function(invSelf, state)
  if not ProximityInventory.isEnabled:getValue() or invSelf.onCharacter then
    -- Ignore character containers, as usual, but I Wonder if instead it would be nice to have
    -- I did just enable proxinv for vehicles, so I'll need to wait for feedback
    return
  end

  if state == "begin" then
    return ProximityInventory.OnBeginRefresh(invSelf)
  end

  if state == "buttonsAdded" then
    return ProximityInventory.OnButtonsAdded(invSelf)
  end

  if state == "end" then
    return ProximityInventory.OnRefreshEnd(invSelf)
  end
end)

return ProximityInventory
