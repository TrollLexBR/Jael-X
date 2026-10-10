--[[
	FISCH JAEL X AUTO — physical-input fishing automation with Jael UI
	Place: Fisch

	KEYS
	  F1           -> toggle all automation
	  F3           -> dump fishing GUI objects
	  F4           -> STOP EVERYTHING and unload
	  Insert -> show/hide the Jael windows
	  Console: shared.FISCH_JAELX.stop()

	Port of RbxCli/Games/Fisch/fisch-auto.lua. Runtime: Jael X Lua 5.4.
	Reads replicated PlayerGui and sends Windows input. No remotes or game writes.
	Requires Mouse & keyboard enabled, Roblox foreground, and a readable exact-build
	GUI profile. Reel can use scale-only UDim2 positions when absolute geometry
	is unavailable; this compares ratios on the same track without screen clicks.
]]

--=========================== SINGLETON ==========================--
if shared.FISCH_JAELX and shared.FISCH_JAELX.stop then
	pcall(shared.FISCH_JAELX.stop)
	task.wait(0.15)
end

local APP = {
	alive = true,
	generation = 0,
	windows = {},
	connections = {},
}
local Library, masterToggle
local heldKeys = {}
shared.FISCH_JAELX = APP

local function running()
	return APP.alive and shared.FISCH_JAELX == APP
end

--=========================== SERVICES ==========================--
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local WS = game:GetService("Workspace")
local LP = Players and Players.LocalPlayer

local TAG = "[FISCH-JAELX]"
local LEFT_BUTTON = Enum.KeyCode.LeftButton
local HOTBAR_KEYS = {
	49, 50, 51, 52, 53, 54, 55, 56, 57, 48,
}
local KEY_RETURN = 13
local KEY_SPACE = 32

--=========================== SETTINGS ==========================--
local state = {
	enabled = false,
	autoCast = true,
	autoEquip = true,
	autoShake = true,
	autoReel = true,
	reelPreset = "Prediction",
	intentionalLoss = false,
	lossEveryMin = 50,
	lossEveryMax = 1000,
	antiAfk = true,
	jumpCatchesMin = 5,
	jumpCatchesMax = 10,
	jumpTrigger = "Either",
	jumpShakesMin = 50,
	jumpShakesMax = 100,
	jumpRodSlot = 0,
	jumpUnequipDelayMs = 250,
	jumpSpaceHoldMs = 80,
	jumpLandingDelayMs = 600,
	jumpEquipDelayMs = 250,

	castHoldMinMs = 750,
	castHoldMaxMs = 950,
	castRetryMs = 6000,
	castPollMs = 20,
	shakeDelayMinMs = 50,
	shakeDelayMaxMs = 90,
	equipRetryMs = 350,
	equipKeyHoldMs = 50,
	equipSettleMs = 100,
	enterKeyHoldMs = 30,

	workerDelayMs = 20,
	checkDelayMs = 10,
	idleDelayMs = 100,
	guiRefreshMs = 2000,
	reelLookupMs = 75,
	reelStaleMs = 1250,
	reelCloseCooldownMs = 1000,
	preReelTimeoutMs = 35000,
	sessionTimeoutMs = 60000,

}

local stats = {
	casts = 0, shakes = 0, reelChanges = 0, reelSamples = 0, reelMisses = 0,
	phaseChanges = 0,
	geometryMissing = 0,
}
local status = "Idle"
local phase = "Check"
local mouseHeld = false
local inputBusy = false
local lastCastAt = -math.huge
local nextShakeAt = 0
local nextEquipAt = 0
local nextHotbarSlot = 1
local recognizedRodName = nil
local equipAttempt = nil
local equippedRodSlot = nil
local trackedCharacter = nil
local characterReady = false
local nextCharacterCheckAt = 0
local fishingSessionActive = false
local fishingSessionStartedAt = 0
local reelWasSeen = false
local nextReelLookupAt = 0
local reelGuiObject = nil
local reelFishObject = nil
local reelPlayerBarObject = nil
local lastReelMotionAt = 0
local lastReelFishX = nil
local lastReelPlayerX = nil
local lastReelDetectedAt = nil
local reelEnding = false
local reelQuietSince = nil
local reelProgressPercent = nil
local reelDetectionStatus = "Not sampled"
local previousReelAt = 0
local lastReelDirection = nil
local smoothFishX = nil
local smoothBarX = nil
local reelFishVelocity = 0
local reelBarVelocity = 0
local reelSampleObject = nil
local reelTrackObject = nil
local reelTrackRect = nil
local lastReelSwitchAt = 0
local lossCycle = {object = nil, remaining = nil, active = false, hold = nil, attempts = 0}
local jumpCycle = {
	counter = nil, lastTotal = nil, catches = 0, target = nil, pending = false,
	nextPollAt = 0, nextLookupAt = 0, nextAttemptAt = 0, keyHeld = false,
	castBlockedUntil = 0,
	generation = 0, jumps = 0, shakes = 0, shakeTarget = nil, stage = nil,
	deadline = 0, rodName = nil, rodSlot = nil, status = "Waiting for activity",
}
local guiCache = {objects = {}, buttons = {}, roots = {}, dirty = true, refreshedAt = -math.huge}
local GUI_KEYWORDS = {
	"fish", "reel", "shake", "safezone", "spear", "stab", "harpoon",
	"pull", "playerbar", "player bar", "controlbar", "control bar",
}

local function now()
	return os.clock()
end

local function randomDelayMs(minimum, maximum)
	local low = math.max(0, math.floor(tonumber(minimum) or 0))
	local high = math.max(0, math.floor(tonumber(maximum) or low))
	return math.random(math.min(low, high), math.max(low, high))
end

local function log(message)
	print(TAG .. " " .. tostring(message))
end

local function setPhase(value)
	if phase == value then return end
	phase = value
	stats.phaseChanges = stats.phaseChanges + 1
	log("Phase: " .. value)
end

local function read(object, property)
	if not object then return nil end
	local ok, value = pcall(function()
		if property == "Text" then
			local hasContent, content = pcall(function() return object.ContentText end)
			if hasContent and type(content) == "string" and content ~= "" then return content end
		end
		return object[property]
	end)
	-- Preserve false: hidden GUI objects are different from unavailable properties.
	if ok then return value end
	return nil
end

local function call(object, method, ...)
	if not object then return nil end
	local args = {...}
	local ok, value = pcall(function()
		return object[method](object, table.unpack(args))
	end)
	if ok then return value end
	return nil
end

local function lower(value)
	return string.lower(tostring(value or ""))
end

local function includesAny(text, words)
	for _, word in ipairs(words) do
		if string.find(text, word, 1, true) then return true end
	end
	return false
end

local function getPlayerGui()
	if not LP and Players then LP = Players.LocalPlayer end
	return LP and call(LP, "FindFirstChildOfClass", "PlayerGui") or nil
end

local function descendants(root)
	local result = call(root, "GetDescendants")
	return type(result) == "table" and result or {}
end

local function isClass(object, className)
	return call(object, "IsA", className) == true
end

local function isGuiButton(object)
	return isClass(object, "GuiButton") or isClass(object, "TextButton") or isClass(object, "ImageButton")
end

local function objectIdentity(object)
	local name = tostring(read(object, "Name") or "")
	local text = tostring(read(object, "Text") or "")
	local fullName = tostring(call(object, "GetFullName") or name)
	return lower(name .. " " .. text .. " " .. fullName)
end

local function cheapIdentity(object, name)
	local text = tostring(read(object, "Text") or "")
	return lower(tostring(name or read(object, "Name") or "") .. " " .. text)
end

local function guiRect(object)
	if not object then return nil end
	local position = read(object, "AbsolutePosition")
	local size = read(object, "AbsoluteSize")
	if not position or not size then stats.geometryMissing = stats.geometryMissing + 1;return nil end
	local x, y = tonumber(position.X), tonumber(position.Y)
	local width, height = tonumber(size.X), tonumber(size.Y)
	if not x or not y or not width or not height or width < 2 or height < 2 then return nil end
	return {x = x, y = y, width = width, height = height, cx = x + width / 2, cy = y + height / 2}
end

local function hierarchyVisible(object)
	local current = object
	for _ = 1, 18 do
		if not current then break end
		if read(current, "Visible") == false or read(current, "Enabled") == false then return false end
		current = read(current, "Parent")
	end
	return true
end
local function visible(object)
	return hierarchyVisible(object) and guiRect(object) ~= nil
end

local function relevantGuiRoot(root)
	local name = lower(read(root, "Name"))
	return includesAny(name, GUI_KEYWORDS)
end

--=========================== INPUT ==========================--
local function inputFocused()
	if Library and (Library:IsInteracting() or Library:IsMouseOverUI()) then APP.inputReason = "Menu interaction";return false end
	if type(input.get_status) == "function" then
		local ok, info = pcall(input.get_status)
		if ok and info.enabled == false then APP.inputReason = "Enable Mouse & keyboard in Jael X";return false end
	end
	local ok, focused = pcall(input.is_window_focused)
	APP.inputReason = ok and focused == true and "Ready" or "Waiting for Roblox focus"
	return ok and focused == true
end

local function releaseMouse()
	if mouseHeld then
		local okUp, upError = pcall(input.mouse_up, LEFT_BUTTON)
		if not okUp then warn(TAG .. " mouse_up failed: " .. tostring(upError)) end
		if okUp then mouseHeld = false;return true end
		return false
	end
	return true
end
local function releaseHeldKeys()
	for key in pairs(heldKeys) do
		local ok = pcall(input.key_up, key)
		if ok then heldKeys[key] = nil end
	end
end

local function holdMouse()
	if not inputFocused() then return false end
	if mouseHeld then
		if type(input.is_mouse_down) ~= "function" then return true end
		local ok, held = pcall(input.is_mouse_down, LEFT_BUTTON)
		if not ok or held then return true end
		mouseHeld = false
	end
	local okDown, downError = pcall(input.mouse_down, LEFT_BUTTON)
	if not okDown then
		warn(TAG .. " mouse_down failed: " .. tostring(downError))
		status = "Reel mouse_down failed"
		return false
	end
	mouseHeld = true
	return true
end

local function tapKey(keyCode, holdMs)
	if not inputFocused() then return false end
	local generation = APP.generation
	local duration = math.max(0, tonumber(holdMs) or 0) / 1000
	-- Jael X exposes explicit keyboard transitions. Using both transitions makes
	-- the configured hold time real and avoids relying on an unrelated global.
	local okDown, downError = pcall(input.key_down, keyCode)
	if not okDown then
		warn(TAG .. " key_down failed: " .. tostring(downError))
		return false
	end
	heldKeys[keyCode] = true
	if duration > 0 then task.wait(duration) end
	local okUp, upError = pcall(input.key_up, keyCode)
	if okUp then heldKeys[keyCode] = nil end
	if not okUp then warn(TAG .. " key_up failed: " .. tostring(upError)) end
	return okUp and running() and state.enabled and APP.generation == generation
end

function APP.keyPress(code)
	local numericCode = tonumber(code)
	if not numericCode then return false, "key code must be a number" end
	local ok, message = pcall(input.key_click, numericCode)
	if not ok then warn(TAG .. " keyboard input failed: " .. tostring(message)) end
	return ok, message
end

--=========================== ANTI-AFK JUMP ==========================--
local function releaseJumpKey()
	if not jumpCycle.keyHeld then return true end
	local ok, result = pcall(input.key_up, KEY_SPACE)
	local name = read(result, "Name")
	if not ok or result == false or name == "Failed" or name == "OutOfFocus" then
		jumpCycle.status = "Space release failed; retrying"
		return false
	end
	jumpCycle.keyHeld = false
	-- Preserve the landing pause even if Anti-AFK is disabled during the jump.
	jumpCycle.castBlockedUntil = now() + state.jumpLandingDelayMs / 1000
	return true
end

local function resetJumpSchedule()
	jumpCycle.generation = jumpCycle.generation + 1
	releaseJumpKey()
	jumpCycle.lastTotal = nil
	jumpCycle.target = math.max(1, randomDelayMs(state.jumpCatchesMin, state.jumpCatchesMax))
	jumpCycle.shakeTarget = math.max(1, randomDelayMs(state.jumpShakesMin, state.jumpShakesMax))
	jumpCycle.shakes, jumpCycle.stage = 0, nil
	jumpCycle.rodName, jumpCycle.rodSlot = nil, nil
	jumpCycle.catches, jumpCycle.pending = 0, false
	jumpCycle.nextPollAt, jumpCycle.nextAttemptAt = 0, 0
	jumpCycle.status = state.antiAfk and "Waiting for shakes / catches" or "OFF"
end

local function readCatchTotal()
	if jumpCycle.counter and read(jumpCycle.counter, "Parent") ~= nil then
		local value = tonumber(read(jumpCycle.counter, "Value"))
		if value and value >= 0 and value < math.huge then return math.floor(value) end
	end
	jumpCycle.counter = nil
	if now() < jumpCycle.nextLookupAt then return nil end
	jumpCycle.nextLookupAt = now() + 2
	-- legacyLocalPlayerData.fetch().Stats.tracker_fishcaught is replicated here.
	-- Read the Value only; no require, remotes, or writes to the game's data.
	local name = LP and read(LP, "Name")
	local root = call(WS, "FindFirstChild", "PlayerStats")
	local playerData = name and call(root, "FindFirstChild", name)
	local container = call(playerData, "FindFirstChild", "T")
	local profile = name and call(container, "FindFirstChild", name)
	local folder = call(profile, "FindFirstChild", "Stats")
	jumpCycle.counter = call(folder, "FindFirstChild", "tracker_fishcaught")
	local value = tonumber(read(jumpCycle.counter, "Value"))
	if value and value >= 0 and value < math.huge then return math.floor(value) end
	return nil
end

local function jumpThresholdReached()
	if state.jumpTrigger ~= "Catches" and jumpCycle.shakes >= (jumpCycle.shakeTarget or math.huge) then return true end
	if state.jumpTrigger ~= "Shakes" and jumpCycle.catches >= (jumpCycle.target or math.huge) then return true end
	return false
end

local function pollJumpCatches()
	if not state.antiAfk or jumpCycle.stage or now() < jumpCycle.nextPollAt then return end
	jumpCycle.nextPollAt = now() + 0.25
	local total = readCatchTotal()
	if total ~= nil then
		if jumpCycle.lastTotal ~= nil then
			if total < jumpCycle.lastTotal then jumpCycle.catches = 0
			else jumpCycle.catches = jumpCycle.catches + total - jumpCycle.lastTotal end
		end
		jumpCycle.lastTotal = total
	end
	if jumpThresholdReached() then jumpCycle.pending = true end
	jumpCycle.status = jumpCycle.pending and "Jump queued after this fishing cycle"
		or string.format("Shakes %d / %s | Catches %d / %s%s", jumpCycle.shakes,
			tostring(jumpCycle.shakeTarget), jumpCycle.catches, tostring(jumpCycle.target),
			total == nil and " (catch counter unavailable)" or "")
end

local function runAntiAfkJump(tool)
	if not running() or not state.enabled or not state.antiAfk or not inputFocused() then return false end
	local character = LP and read(LP, "Character")
	local heldTool = call(character, "FindFirstChildOfClass", "Tool")
	local stage = jumpCycle.stage
	if not stage then
		if not jumpCycle.pending or inputBusy or mouseHeld or fishingSessionActive or reelEnding
			or phase ~= "Check" or now() < jumpCycle.nextAttemptAt then return false end
		if lastReelDetectedAt and now() - lastReelDetectedAt < 0.3 then return false end
		if tool and call(tool, "FindFirstChild", "bobber") then return false end
		if not tool then return false end
		local okKey, spaceDown = pcall(input.is_key_down, KEY_SPACE)
		if okKey and spaceDown then return false end
		jumpCycle.rodName = read(tool, "Name")
		local configuredSlot = math.floor(state.jumpRodSlot)
		jumpCycle.rodSlot = configuredSlot > 0 and math.clamp(configuredSlot, 1, 10) or equippedRodSlot or 1
		-- Hotbar keys toggle equip without dropping or modifying the game-owned rod.
		if not tapKey(HOTBAR_KEYS[jumpCycle.rodSlot], state.equipKeyHoldMs) then return true end
		jumpCycle.stage = "Stored"
		jumpCycle.deadline = now() + state.jumpUnequipDelayMs / 1000
	elseif now() < jumpCycle.deadline then
		status = "Anti-AFK: " .. stage
		return true
	elseif stage == "Stored" then
		if heldTool and read(heldTool, "Name") == jumpCycle.rodName then
			jumpCycle.stage = nil
			jumpCycle.nextAttemptAt = now() + 1
			jumpCycle.status = "Rod still equipped; check Rod hotbar slot"
			status = jumpCycle.status
			return true
		end
		local ok, result = pcall(input.key_down, KEY_SPACE)
		if not ok or result == false then jumpCycle.status = "Space input failed; retrying";return true end
		jumpCycle.keyHeld = true
		jumpCycle.stage = "Jump"
		jumpCycle.deadline = now() + state.jumpSpaceHoldMs / 1000
	elseif stage == "Jump" then
		if not releaseJumpKey() then return true end
		jumpCycle.jumps = jumpCycle.jumps + 1
		jumpCycle.stage = "Landing"
		jumpCycle.deadline = now() + state.jumpLandingDelayMs / 1000
	elseif stage == "Landing" then
		if not tapKey(HOTBAR_KEYS[jumpCycle.rodSlot], state.equipKeyHoldMs) then return true end
		jumpCycle.stage = "Equip"
		jumpCycle.deadline = now() + state.jumpEquipDelayMs / 1000
	elseif stage == "Equip" then
		if not heldTool or read(heldTool, "Name") ~= jumpCycle.rodName then
			jumpCycle.stage = "Landing"
			jumpCycle.deadline = now() + state.equipRetryMs / 1000
			jumpCycle.status = "Waiting for rod equip; check Rod hotbar slot"
			return true
		end
		equippedRodSlot = jumpCycle.rodSlot
		resetJumpSchedule()
		jumpCycle.castBlockedUntil = now()
		status = "Anti-AFK: rod equipped; fishing resumed"
		return true
	end
	status = "Anti-AFK: " .. tostring(jumpCycle.stage)
	jumpCycle.status = status
	return true
end

--=========================== GUI DISCOVERY ==========================--
local function refreshGuiCache(force)
	local refreshSeconds = math.max(500, state.guiRefreshMs) / 1000
	if not force and not guiCache.dirty and now() - guiCache.refreshedAt < refreshSeconds then return guiCache end
	local root = getPlayerGui()
	local objects = {}
	local buttons = {}
	local roots = {}
	-- PlayerGui is extremely large in Fisch. Only fishing ScreenGuis are allowed to
	-- cross the Jael X bridge; a full GetDescendants scan can stall or crash the host.
	for _, child in ipairs(root and call(root, "GetChildren") or {}) do
		if relevantGuiRoot(child) then roots[#roots + 1] = child end
	end
	for _, guiRoot in ipairs(roots) do
		local candidates = {guiRoot}
		for _, object in ipairs(descendants(guiRoot)) do candidates[#candidates + 1] = object end
		for _, object in ipairs(candidates) do
			local name = tostring(read(object, "Name") or "")
			local className = tostring(read(object, "ClassName") or "")
			local identity = cheapIdentity(object, name)
			if includesAny(identity, GUI_KEYWORDS) then objects[#objects + 1] = object end
			if (className == "TextButton" or className == "ImageButton" or className == "GuiButton")
				and visible(object) then
				local rect = guiRect(object)
				if rect then
					buttons[#buttons + 1] = {object = object, rect = rect, identity = objectIdentity(object)}
				end
			end
		end
	end
	guiCache.objects = objects
	guiCache.buttons = buttons
	guiCache.roots = roots
	guiCache.dirty = false
	guiCache.refreshedAt = now()
	return guiCache
end

local function findShakeButton(buttons)
	local best, bestArea = nil, 0
	for _, item in ipairs(buttons) do
		if hierarchyVisible(item.object) and includesAny(item.identity, {"shakeui", "safezone", "shake"}) then
			local area = item.rect.width * item.rect.height
			if area > bestArea then best, bestArea = item, area end
		end
	end
	return best
end

local function findActiveShakeButton(buttons)
	local playerGui = getPlayerGui()
	local shakeGui = playerGui and call(playerGui, "FindFirstChild", "shakeui") or nil
	if shakeGui and read(shakeGui, "Enabled") ~= false then
		local safezone = call(shakeGui, "FindFirstChild", "safezone")
		local button = safezone and call(safezone, "FindFirstChild", "button") or nil
		-- The current controller creates an ImageButton named "default".
		if not button and safezone then
			for _, candidate in ipairs(descendants(safezone)) do
				if isGuiButton(candidate) and hierarchyVisible(candidate) then button = candidate;break end
			end
		end
		local rect = button and guiRect(button) or nil
		-- Keyboard shake needs the active UI, not a native geometry profile.
		if button and hierarchyVisible(button) then
			return {object = button, rect = rect, identity = "shakeui safezone button"}
		end
	end
	return findShakeButton(buttons)
end

local function colorIsPurple(color)
	if not color then return false end
	local r, g, b = tonumber(color.R), tonumber(color.G), tonumber(color.B)
	return r and g and b and b > 0.45 and r > 0.25 and b > g * 1.35 and r > g * 1.2 or false
end

local function objectHasPurple(object)
	if colorIsPurple(read(object, "TextColor3")) or colorIsPurple(read(object, "BackgroundColor3"))
		or colorIsPurple(read(object, "ImageColor3")) then return true end
	for _, child in ipairs(descendants(object)) do
		if colorIsPurple(read(child, "TextColor3")) or colorIsPurple(read(child, "BackgroundColor3"))
			or colorIsPurple(read(child, "ImageColor3")) then return true end
	end
	return false
end

local function findNamedObject(objects, names, excluded)
	for _, object in ipairs(objects) do
		local identity = cheapIdentity(object)
		if includesAny(identity, names) and not (excluded and includesAny(identity, excluded)) and visible(object) then
			local rect = guiRect(object)
			if rect then return {object = object, rect = rect, identity = identity} end
		end
	end
	return nil
end

local function reelRects(fishObject, playerObject)
	local fishRect, playerRect = guiRect(fishObject), guiRect(playerObject)
	if fishRect and playerRect then return fishRect, playerRect end
	local track = read(fishObject, "Parent")
	if not track or track ~= read(playerObject, "Parent") then return nil, nil end
	local function relativeRect(object)
		local positionX = read(read(object, "Position"), "X")
		local sizeX = read(read(object, "Size"), "X")
		local scale, width = tonumber(read(positionX, "Scale")), tonumber(read(sizeX, "Scale"))
		local offset, sizeOffset = tonumber(read(positionX, "Offset")), tonumber(read(sizeX, "Offset"))
		local anchor = tonumber(read(read(object, "AnchorPoint"), "X"))
		-- Fisch uses pure X scale for both bars. Their shared parent makes aspect
		-- constraints, viewport and inset cancel out. Unknown pixel offsets fail soft.
		if not scale or not width or not anchor or offset ~= 0 or sizeOffset ~= 0 or width <= 0 then return nil end
		local w = width * 1000
		local x = scale * 1000 - anchor * w
		return {x = x, y = 0, width = w, height = 10, cx = x + w / 2, cy = 5, normalized = true}
	end
	return relativeRect(fishObject), relativeRect(playerObject)
end

local function findReelBars()
	-- Once discovered, retain the two instances and sample their live geometry on
	-- every worker tick. Returning nil between discovery polls would release M1.
	if reelGuiObject and reelFishObject and reelPlayerBarObject
		and read(reelGuiObject, "Parent") ~= nil
		and read(reelGuiObject, "Enabled") ~= false then
		local fishRect, playerRect = reelRects(reelFishObject, reelPlayerBarObject)
		local saneSize = fishRect and playerRect and playerRect.width > 2
		if saneSize and hierarchyVisible(reelFishObject) and hierarchyVisible(reelPlayerBarObject) then
			local fish = {object = reelFishObject, rect = fishRect, identity = "reel fish"}
			local playerBar = {object = reelPlayerBarObject, rect = playerRect, identity = "reel playerbar"}
			local moved = not lastReelFishX or math.abs(fishRect.cx - lastReelFishX) > 0.15
				or not lastReelPlayerX or math.abs(playerRect.cx - lastReelPlayerX) > 0.15
			if moved then lastReelMotionAt = now() end
			lastReelFishX, lastReelPlayerX = fishRect.cx, playerRect.cx
			if not reelWasSeen then log("Reel bars detected; mouse balance enabled.") end
			reelWasSeen = true
			reelDetectionStatus = fishRect.normalized and "Live bars / relative scale" or "Cached live bars"
			return fish, playerBar
		end
		reelGuiObject, reelFishObject, reelPlayerBarObject = nil, nil, nil
	end
	if now() < nextReelLookupAt then
		reelDetectionStatus = "Waiting for discovery poll"
		return nil, nil
	end
	nextReelLookupAt = now() + state.reelLookupMs / 1000
	local playerGui = getPlayerGui()
	local reelRoot = playerGui and call(playerGui, "FindFirstChild", "reel") or nil
	local bar = reelRoot and call(reelRoot, "FindFirstChild", "bar") or nil
	local directFish = bar and call(bar, "FindFirstChild", "fish") or nil
	local directPlayerBar = bar and call(bar, "FindFirstChild", "playerbar") or nil
	local directFishRect, directPlayerRect = reelRects(directFish, directPlayerBar)
	if reelRoot and read(reelRoot, "Enabled") ~= false and directFish and directPlayerBar
		and read(directFish, "Visible") ~= false and read(directPlayerBar, "Visible") ~= false
		and (not directPlayerRect or not directFishRect) then
		APP.geometryBlocked = true
	end
	-- Jael X does not expose ScreenGui.Enabled. Unknown must be accepted in both
	-- discovery and cached reads; child visibility and live geometry gate activity.
	if reelRoot and read(reelRoot, "Enabled") ~= false and directFish and directPlayerBar
		and directFishRect and directPlayerRect and directPlayerRect.width > 2
		and hierarchyVisible(directFish) and hierarchyVisible(directPlayerBar) then
		reelGuiObject, reelFishObject, reelPlayerBarObject = reelRoot, directFish, directPlayerBar
		return findReelBars()
	end
	local cache = refreshGuiCache(false)
	-- The replicated reel template is reel.bar.fish + reel.bar.playerbar. Prefer
	-- those exact names so the controller performs only a handful of bridge reads.
	local exactReelRoot, exactFish, exactPlayerBar = nil, nil, nil
	for _, guiRoot in ipairs(cache.roots) do
		if lower(read(guiRoot, "Name")) == "reel" and read(guiRoot, "Enabled") ~= false then
			exactReelRoot = guiRoot
			for _, object in ipairs(cache.objects) do
				local name = lower(read(object, "Name"))
				if name == "fish" then exactFish = object elseif name == "playerbar" then exactPlayerBar = object end
			end
			break
		end
	end
	local objects = cache.objects
	local fish = findNamedObject(objects,
		{"reel_fish", "fishbar", "fish cursor", "fishicon", "fishmarker", "fish marker"},
		{"progress", "shake", "harpoon", "spear"})
	local playerBar = findNamedObject(objects,
		{"reel_playerbar", "playerbar", "player bar", "controlbar", "control bar"})
	if exactFish and exactPlayerBar and read(exactReelRoot, "Parent") ~= nil
		and hierarchyVisible(exactFish) and hierarchyVisible(exactPlayerBar) then
		local fishRect, playerRect = reelRects(exactFish, exactPlayerBar)
		if fishRect and playerRect then
			reelGuiObject, reelFishObject, reelPlayerBarObject = exactReelRoot, exactFish, exactPlayerBar
			fish = {object = exactFish, rect = fishRect, identity = "reel fish"}
			playerBar = {object = exactPlayerBar, rect = playerRect, identity = "reel playerbar"}
		end
	end
	if fish and playerBar then
		local moved = not lastReelFishX or math.abs(fish.rect.cx - lastReelFishX) > 0.15
			or not lastReelPlayerX or math.abs(playerBar.rect.cx - lastReelPlayerX) > 0.15
		if moved then lastReelMotionAt = now() end
		lastReelFishX, lastReelPlayerX = fish.rect.cx, playerBar.rect.cx
		if now() - lastReelMotionAt <= state.reelStaleMs / 1000 then
			if not reelWasSeen then log("Reel bars detected; mouse balance enabled.") end
			reelWasSeen = true
			reelDetectionStatus = "Discovered live bars"
			return fish, playerBar
		end
	end
	reelDetectionStatus = "No visible reel bars"
	return nil, nil
end

--=========================== AUTOMATION ==========================--
local function isFishingRod(tool)
	if not tool or not isClass(tool, "Tool") then return false end
	-- Rods such as Requiem have no "rod" in their name. Check their actual
	-- client/cast components before using the name as a compatibility fallback.
	if call(tool, "FindFirstChild", "rod/client") then return true end
	local events = call(tool, "FindFirstChild", "events")
	if events and (call(events, "FindFirstChild", "castAsync") or call(events, "FindFirstChild", "cast")) then return true end
	local name = lower(read(tool, "Name"))
	return name == recognizedRodName or string.find(name, "rod", 1, true) ~= nil
end



local function equippedTool()
	local character = LP and read(LP, "Character") or nil
	for _, child in ipairs(character and call(character, "GetChildren") or {}) do
		if isFishingRod(child) then return child end
	end
	-- RodBodyModel can persist while stowed. Its component uses IsVisible to
	-- decide whether the rod is in hand; existence alone is not an equip signal.
	local rodVisual = character and call(character, "FindFirstChild", "RodBodyModel") or nil
	if rodVisual and call(rodVisual, "GetAttribute", "IsVisible") == true then
		local backpack = LP and call(LP, "FindFirstChildOfClass", "Backpack") or nil
		local candidate
		for _, child in ipairs(backpack and call(backpack, "GetChildren") or {}) do
			if isFishingRod(child) then
				if lower(read(child, "Name")) == recognizedRodName then return child end
				candidate = candidate or child
			end
		end
		return candidate
	end
	return nil
end

local function hasBobber(tool)
	-- The game's rod/client uses Tool:FindFirstChild("bobber"). Character.Bodybobber
	-- is only the equipped visual and must not suppress casting.
	return tool and call(tool, "FindFirstChild", "bobber") ~= nil or false
end

local function runAutoEquip()
	local tool = equippedTool()
	if tool then
		if equipAttempt then
			equippedRodSlot = equipAttempt.slot
			recognizedRodName = lower(read(tool, "Name"))
			equipAttempt = nil
			status = "Rod confirmed in hand: " .. tostring(read(tool, "Name"))
			log(status)
		end
		return false
	end
	-- A lost/unequipped rod invalidates the old cast, even if the old session
	-- timeout has not expired. Never promote an arbitrary hotbar Tool to a rod.
	fishingSessionActive, reelWasSeen = false, false
	lastCastAt = -math.huge
	if not state.autoEquip then status = "Waiting for rod; Auto Equip Rod is OFF"; return true end
	if inputBusy then return true end
	if equipAttempt then
		if now() < equipAttempt.deadline then
			status = "Confirming rod in slot " .. equipAttempt.slot
			return true
		end
		nextHotbarSlot = equipAttempt.slot % #HOTBAR_KEYS + 1
		equipAttempt = nil
		nextEquipAt = now() + state.equipRetryMs / 1000
	end
	if now() < nextEquipAt then status = "Searching hotbar for a fishing rod"; return true end
	local slot = nextHotbarSlot
	if not tapKey(HOTBAR_KEYS[slot], state.equipKeyHoldMs) then
		nextEquipAt = now() + state.equipRetryMs / 1000
		status = inputFocused() and "Hotbar input failed" or "Waiting for Roblox focus"
		return true
	end
	if not running() or not state.enabled then return true end
	-- Wait across worker ticks so a delayed equip is not toggled back off.
	equipAttempt = {slot = slot, deadline = now() + math.max(450, state.equipSettleMs) / 1000}
	status = "Confirming rod in slot " .. slot
	return true
end

local function runShake(buttons, detected)
	if not state.autoShake or now() < nextShakeAt then return false end
	local item = detected or findActiveShakeButton(buttons)
	if not item then return false end
	local sent = tapKey(KEY_RETURN, state.enterKeyHoldMs)
	if sent then
		local delayMs = randomDelayMs(state.shakeDelayMinMs, state.shakeDelayMaxMs)
		-- Schedule once after the key is released; polling must not reroll the wait.
		nextShakeAt = now() + delayMs / 1000
		stats.lastShakeDelayMs = delayMs
		stats.shakes = stats.shakes + 1
		if state.antiAfk then
			jumpCycle.shakes = jumpCycle.shakes + 1
			if jumpThresholdReached() then jumpCycle.pending = true end
		end
		status = "Shake: Enter"
	end
	return true
end

local function resetReelController()
	previousReelAt = 0
	lastReelDirection = nil
	smoothFishX, smoothBarX = nil, nil
	reelFishVelocity, reelBarVelocity = 0, 0
	reelSampleObject, reelTrackObject, reelTrackRect = nil, nil, nil
	lastReelSwitchAt = 0
end

-- Exemplo2 reads reel.bar.progress.bar.Size.X.Scale. Absolute widths cover
-- bridges that expose geometry but not UDim2; zero-width progress is valid.
local function readReelProgress(playerBar)
	local track = playerBar and read(playerBar.object, "Parent")
	local progress = call(track, "FindFirstChild", "progress")
	local fill = call(progress, "FindFirstChild", "bar")
	local size = read(fill, "Size")
	local x = read(size, "X")
	local scale = tonumber(read(x, "Scale"))
	local offset = tonumber(read(x, "Offset"))
	if not scale or (offset and offset ~= 0) then
		local fillSize, parentSize = read(fill, "AbsoluteSize"), read(progress, "AbsoluteSize")
		local width, parentWidth = tonumber(read(fillSize, "X")), tonumber(read(parentSize, "X"))
		scale = width and parentWidth and parentWidth > 0 and width / parentWidth or nil
	end
	if not scale or scale ~= scale or scale < 0 or scale > 1.5 then return nil end
	return math.clamp(scale * 100, 0, 100)
end

local function updateReelEnding(fish, playerBar)
	local currentAt = now()
	local barsPresent = fish ~= nil and playerBar ~= nil
	if barsPresent then reelProgressPercent = readReelProgress(playerBar) end
	-- Wait for a full bar, not an estimate of time remaining: progress can fall.
	-- Latch completion before another M1 transition can become a new cast.
	if not reelEnding then
		local completed = barsPresent and reelProgressPercent and reelProgressPercent >= 100
		local closed = not barsPresent and reelWasSeen and lastReelDetectedAt
			and currentAt - lastReelDetectedAt >= 0.15
		if not completed and not closed then return false end
		reelEnding = true
		reelQuietSince = nil
		resetReelController()
	end
	releaseMouse()
	setPhase("Finishing")
	status = "Waiting for reel to close"
	-- A lingering completed GUI must never re-enter runReel, even if its fill
	-- resets during the catch animation. Require continuous absence afterwards.
	if barsPresent then
		reelQuietSince = nil
		return true
	end
	reelQuietSince = reelQuietSince or currentAt
	if currentAt - reelQuietSince < state.reelCloseCooldownMs / 1000 then
		status = "Waiting after reel closed"
		return true
	end
	reelEnding, reelQuietSince, reelProgressPercent = false, nil, nil
	fishingSessionActive, reelWasSeen = false, false
	reelGuiObject, reelFishObject, reelPlayerBarObject = nil, nil, nil
	lastReelFishX, lastReelPlayerX, lastReelDetectedAt = nil, nil, nil
	lastReelMotionAt, nextReelLookupAt = 0, 0
	lossCycle.object, lossCycle.active, lossCycle.hold = nil, false, nil
	guiCache.dirty = true
	status = "Fishing cycle completed"
	return true
end

local function checkCharacterState()
	if now() < nextCharacterCheckAt then return characterReady end
	nextCharacterCheckAt = now() + 0.2
	if not LP and Players then LP = Players.LocalPlayer end
	local character = LP and read(LP, "Character") or nil
	local humanoid = character and call(character, "FindFirstChildOfClass", "Humanoid")
	local health = tonumber(read(humanoid, "Health"))
	local ready = character ~= nil and read(character, "Parent") ~= nil and health ~= nil and health > 0
	if character ~= trackedCharacter or (characterReady and not ready) then
		releaseMouse()
		releaseJumpKey()
		resetJumpSchedule()
		inputBusy = false
		resetReelController()
		fishingSessionActive, reelWasSeen = false, false
		reelEnding, reelQuietSince, reelProgressPercent = false, nil, nil
		fishingSessionStartedAt, nextShakeAt = 0, 0
		lastCastAt = -math.huge
		reelGuiObject, reelFishObject, reelPlayerBarObject = nil, nil, nil
		lastReelFishX, lastReelPlayerX, lastReelDetectedAt = nil, nil, nil
		lastReelMotionAt, nextReelLookupAt = 0, 0
		equipAttempt, recognizedRodName = nil, nil
		nextHotbarSlot, nextEquipAt = equippedRodSlot or 1, 0
		lossCycle.object, lossCycle.active, lossCycle.hold = nil, false, nil
		guiCache.objects, guiCache.buttons, guiCache.roots = {}, {}, {}
		guiCache.dirty = true
		trackedCharacter = character
		setPhase("Check")
	end
	characterReady = ready
	if not ready then status = "Waiting for character to spawn" end
	return ready
end

--=========================== INTENTIONAL LOSSES ==========================--
local function resetLossSchedule()
	if lossCycle.active then resetReelController() end
	lossCycle.remaining = nil
	lossCycle.active = false
	lossCycle.hold = nil
end

local function updateLossCycle(playerBar)
	if not state.intentionalLoss then resetLossSchedule() end
	if lossCycle.object == playerBar.object then return end
	-- Keep this identity separate from velocity resets: focus changes and bridge
	-- stalls do not start another fish. Count minigames, not unverified catches.
	lossCycle.object = playerBar.object
	lossCycle.active, lossCycle.hold = false, nil
	if not state.intentionalLoss then return end
	if lossCycle.remaining == nil then
		lossCycle.remaining = randomDelayMs(state.lossEveryMin, state.lossEveryMax)
	end
	if lossCycle.remaining <= 0 then
		lossCycle.active = true
		lossCycle.attempts = lossCycle.attempts + 1
		lossCycle.remaining = nil
	else
		lossCycle.remaining = lossCycle.remaining - 1
	end
end

local function runIntentionalLoss(fish, playerBar, currentAt)
	if not lossCycle.active then return false end
	local track = reelTrackRect
	local midpoint = track and track.x + track.width / 2 or playerBar.rect.cx
	local margin = track and track.width * 0.08 or playerBar.rect.width * 0.1
	-- Aim for the end farthest from the fish. Hysteresis prevents switching on
	-- every center crossing; all movement still uses ordinary mouse transitions.
	if lossCycle.hold == nil then lossCycle.hold = fish.rect.cx < midpoint end
	if fish.rect.cx < midpoint - margin then
		lossCycle.hold = true
	elseif fish.rect.cx > midpoint + margin then
		lossCycle.hold = false
	end
	if currentAt - lastReelSwitchAt >= 0.04 then
		local wasHeld = mouseHeld
		if lossCycle.hold then holdMouse() else releaseMouse() end
		if wasHeld ~= mouseHeld then
			lastReelSwitchAt = currentAt
			stats.reelChanges = stats.reelChanges + 1
		end
	end
	lastReelDirection = mouseHeld and "RIGHT" or "LEFT"
	previousReelAt = currentAt
	status = "Reel: intentional loss - moving away from fish"
	return true
end

local function runReel(fish, playerBar)
	if not state.autoReel or not fish or not playerBar then
		if reelSampleObject then releaseMouse(); resetReelController() end
		return false
	end
	if inputBusy then return false end
	if not inputFocused() then releaseMouse();resetReelController();status = APP.inputReason;return false end
	updateLossCycle(playerBar)
	local currentAt = now()
	local elapsed = currentAt - previousReelAt
	-- A new GUI or a stalled bridge must not become a fictitious velocity spike.
	if reelSampleObject ~= playerBar.object or elapsed > 0.25 then
		resetReelController()
		reelSampleObject = playerBar.object
		reelTrackObject = read(playerBar.object, "Parent")
	end
	elapsed = previousReelAt > 0 and math.max(0.001, elapsed) or 0.02
	local playerWidth = math.max(1, playerBar.rect.width)
	if fish.rect.normalized then
		reelTrackRect = {x = 0, width = 1000}
	else
		reelTrackRect = guiRect(reelTrackObject) or reelTrackRect
	end
	if runIntentionalLoss(fish, playerBar, currentAt) then return true end
	local rawFishX, rawBarX = fish.rect.cx, playerBar.rect.cx
	if not smoothFishX then smoothFishX, smoothBarX = rawFishX, rawBarX end
	local previousFishX, previousBarX = smoothFishX, smoothBarX
	smoothFishX, smoothBarX = rawFishX, rawBarX
	local measuredFishVelocity = (smoothFishX - previousFishX) / elapsed
	local measuredBarVelocity = (smoothBarX - previousBarX) / elapsed
	-- Time-based filtering keeps the same response at different polling rates.
	-- Drop the old fish direction promptly when it reverses.
	local fishAlpha = 1 - math.exp(-elapsed / 0.035)
	local barAlpha = 1 - math.exp(-elapsed / 0.025)
	if measuredFishVelocity * reelFishVelocity < 0 then fishAlpha = math.max(0.8, fishAlpha) end
	reelFishVelocity = reelFishVelocity + (measuredFishVelocity - reelFishVelocity) * fishAlpha
	reelBarVelocity = reelBarVelocity + (measuredBarVelocity - reelBarVelocity) * barAlpha

	-- RodMovement:Tick smooths velocity with SmoothDamp (base smooth time 0.85s).
	-- InputBegan/InputEnded reset its acceleration in legacy mode. Per-tick PWM
	-- therefore does NOT produce an average force: keep a direction until the
	-- predicted tracking error crosses the opposite threshold.
	local targetX = rawFishX
	local targetVelocity = reelFishVelocity
	if state.reelPreset == "Prediction" then
		targetX = targetX + math.clamp(targetVelocity * 0.035, -playerWidth * 0.08, playerWidth * 0.08)
	end
	if reelTrackRect and reelTrackRect.width >= playerWidth then
		local left = reelTrackRect.x + playerWidth / 2
		local right = reelTrackRect.x + reelTrackRect.width - playerWidth / 2
		-- The bar center cannot reach a fish at the very end of the track.
		targetX = math.clamp(targetX, left, right)
		if (targetX <= left and targetVelocity < 0) or (targetX >= right and targetVelocity > 0) then
			targetVelocity = 0
		end
	end
	local positionError = targetX - rawBarX
	local brakeTime = 0.42 + math.min(elapsed, 0.06)
	local control = positionError + (targetVelocity - reelBarVelocity) * brakeTime
	local tolerance = math.max(0.75, playerWidth * 0.015)
	local desiredHold = mouseHeld
	if control > tolerance then
		desiredHold = true
	elseif control < -tolerance then
		desiredHold = false
	end
	-- Let a transition reach the game before considering another one.
	if currentAt - lastReelSwitchAt < 0.04 then desiredHold = mouseHeld end

	local wasHeld = mouseHeld
	local applied = desiredHold and holdMouse() or (not desiredHold and releaseMouse())
	if not applied then
		status = "Reel input failed; retrying"
		return false
	end
	if wasHeld ~= mouseHeld then
		stats.reelChanges = stats.reelChanges + 1
		lastReelSwitchAt = currentAt
	end
	lastReelDirection = mouseHeld and "RIGHT" or "LEFT"
	previousReelAt = currentAt
	status = string.format("Reel %s | %s | center error %.1f %s | speed %.1f",
		state.reelPreset, lastReelDirection, rawFishX - rawBarX, fish.rect.normalized and "units" or "px", reelBarVelocity)
	return true
end

local function runCast()
	if not state.autoCast or inputBusy or mouseHeld or fishingSessionActive or reelEnding or reelWasSeen then return false end
	if now() < jumpCycle.castBlockedUntil then
		status = "Anti-AFK: waiting after jump"
		return true
	end
	local tool = equippedTool()
	if not isFishingRod(tool) or hasBobber(tool) or now() - lastCastAt < state.castRetryMs / 1000 then return false end
	if not inputFocused() then status = "Waiting for Roblox focus"; return true end
	local castCharacter = LP and read(LP, "Character")
	local castGeneration = APP.generation
	lastCastAt = now()
	inputBusy = true
	local okDown, downError = pcall(input.mouse_down, LEFT_BUTTON)
	if not okDown then
		inputBusy = false
		status = "Cast mouse_down failed"
		warn(TAG .. " " .. status .. ": " .. tostring(downError))
		return true
	end
	mouseHeld = true
	local holdMs = randomDelayMs(state.castHoldMinMs, state.castHoldMaxMs)
	stats.lastCastHoldMs = holdMs
	status = "Holding cast: " .. holdMs .. " ms"
	log(status)
	local deadline = now() + holdMs / 1000
	while running() and state.enabled and inputFocused()
		and APP.generation == castGeneration
		and read(LP, "Character") == castCharacter and now() < deadline do
		task.wait(math.min(state.castPollMs / 1000, math.max(0, deadline - now())))
	end
	local released = releaseMouse()
	inputBusy = false
	if APP.generation ~= castGeneration then return false end
	if not released then status = "Cast mouse_up failed; retrying";return false end
	if not running() or not state.enabled or not inputFocused()
		or read(LP, "Character") ~= castCharacter or not equippedTool() then
		fishingSessionActive = false
		status = "Cast interrupted; checking rod again"
		return true
	end
	stats.casts = stats.casts + 1
	fishingSessionActive = true
	fishingSessionStartedAt = now()
	status = "Cast released"
	return true
end

local function dumpFishingGui()
	local lines = {}
	local cache = refreshGuiCache(true)
	for _, object in ipairs(cache.objects) do
		local identity = objectIdentity(object)
		local rect = guiRect(object)
		if rect and visible(object) and includesAny(identity,
			{"fish", "reel", "shake", "spear", "stab", "harpoon", "pull", "safezone", "playerbar", "controlbar"}) then
			lines[#lines + 1] = string.format("%s | %s | %.0f,%.0f %.0fx%.0f",
				tostring(read(object, "ClassName") or "Unknown"), identity,
				rect.x, rect.y, rect.width, rect.height)
		end
	end
	log("GUI DUMP BEGIN")
	for _, line in ipairs(lines) do log(line) end
	log("GUI DUMP END: " .. #lines .. " candidate(s)")
	status = "GUI dump printed"
	return lines
end

function APP.setEnabled(value)
	APP.generation = APP.generation + 1
	releaseMouse();releaseHeldKeys()
	inputBusy = false
	resetReelController()
	fishingSessionActive, reelWasSeen = false, false
	reelEnding, reelQuietSince, reelProgressPercent = false, nil, nil
	fishingSessionStartedAt, nextShakeAt, nextReelLookupAt = 0, 0, 0
	lastCastAt = -math.huge
	reelGuiObject, reelFishObject, reelPlayerBarObject = nil, nil, nil
	lastReelFishX, lastReelPlayerX, lastReelDetectedAt = nil, nil, nil
	lastReelMotionAt = 0
	APP.geometryBlocked = false
	guiCache.dirty = true
	guiCache.refreshedAt = -math.huge
	equipAttempt = nil
	lossCycle.object, lossCycle.active, lossCycle.hold = nil, false, nil
	resetJumpSchedule()
	state.enabled = value == true
	if masterToggle then masterToggle:SetValue(state.enabled, true) end
	if state.enabled then
		-- A stationary cursor over the open menu previously blocked every input.
		if Library then Library:SetVisible(false) end
		nextHotbarSlot, nextEquipAt = equippedRodSlot or 1, 0
		equipAttempt = nil
		nextCharacterCheckAt = 0
		setPhase("Check")
	end
	setPhase("Check")
	status = state.enabled and "Automation enabled" or "Automation disabled"
	log(status)
end

APP.getState = function() return state end
APP.getStats = function() return stats end
APP.getStatus = function() return status end
APP.getPhase = function() return phase end
APP.getDiagnostics = function()
	return {
		alive = running(), enabled = state.enabled, autoReel = state.autoReel,
		phase = phase, status = status, focused = inputFocused(), inputReason = APP.inputReason, mouseHeld = mouseHeld,
		detection = reelDetectionStatus, reelSamples = stats.reelSamples,
		reelMisses = stats.reelMisses, phaseChanges = stats.phaseChanges,
		lastReelAgeMs = lastReelDetectedAt and math.floor((now() - lastReelDetectedAt) * 1000) or -1,
		reelEnding = reelEnding, reelProgressPercent = reelProgressPercent,
		intentionalLoss = lossCycle.active, normalReelsRemaining = lossCycle.remaining,
		intentionalLossAttempts = lossCycle.attempts,
		antiAfk = state.antiAfk, jumpStatus = jumpCycle.status, jumps = jumpCycle.jumps,
		jumpStage = jumpCycle.stage, shakesSinceJump = jumpCycle.shakes, shakeTarget = jumpCycle.shakeTarget,
		jumpPending = jumpCycle.pending, catchesSinceJump = jumpCycle.catches, jumpTarget = jumpCycle.target,
		characterReady = characterReady, rodEquipped = equippedTool() ~= nil,
		geometryMissing = stats.geometryMissing,
		equipSlot = equipAttempt and equipAttempt.slot or equippedRodSlot,
	}
end
APP.dumpGui = dumpFishingGui

--=========================== JOX LIBRARY UI ==========================--
local LIBRARY_URL = "https://raw.githubusercontent.com/TrollLexBR/Jael-X/main/JoX-Library.lua"
local okLibrary, resultLibrary = pcall(function()
	local source = game:HttpGet(LIBRARY_URL)
	local fn, err = loadstring(source, "@JoXLibrary")
	assert(fn, err)
	local result = fn()
	assert(type(result) == "table" and result.NewWindow, "Invalid JoX Library")
	return result
end)
if okLibrary then Library = resultLibrary end
local okUI, uiError = pcall(function()
	if not Library then error(resultLibrary) end
	local win = Library:NewWindow({title = "Fisch / JoX", subtitle = "JAEL X / PHYSICAL INPUT AUTOMATION", configId = "FischJaelX", width = 920, height = 650})
	APP.window = win
	local fishing = win:NewTab("Fishing", "Automation and live status")
	local core = fishing:NewSection("Automation", "left")
	local function toggle(section, text, key, changed)
		return section:AddToggle({text = text, flag = "fisch/" .. key, default = state[key], callback = function(value)
			state[key] = value
			if changed then changed(value) end
		end})
	end
	local function slider(section, text, key, min, max)
		return section:AddSlider({text = text, flag = "fisch/" .. key, min = min, max = max, step = 1, default = state[key], callback = function(value) state[key] = value end})
	end
	masterToggle = core:AddToggle({text = "Master switch (F1)", flag = "fisch/enabled", default = false, callback = APP.setEnabled})
	toggle(core, "Auto cast", "autoCast")
	toggle(core, "Auto equip rod", "autoEquip")
	toggle(core, "Auto shake", "autoShake")
	toggle(core, "Auto reel", "autoReel", function()releaseMouse();resetReelController()end)
	core:AddDropdown({text = "Reel controller", flag = "fisch/reelPreset", options = {"Prediction", "Normal"}, default = state.reelPreset,
		callback = function(v)state.reelPreset = v;resetReelController()end})
	core:AddLabel({text = "Shake input: Enter only"})
	local live = fishing:NewSection("Live status", "right")
	live:AddLabel({get = function()return (state.enabled and "ON" or "OFF") .. " / " .. phase end})
	live:AddLabel({get = function()return status end})
	live:AddLabel({get = function()return string.format("Casts: %d / Shakes: %d", stats.casts, stats.shakes) end})
	live:AddLabel({get = function()return string.format("Reel samples: %d / Misses: %d", stats.reelSamples, stats.reelMisses) end})
	live:AddLabel({get = function()return "Detection: " .. reelDetectionStatus end})
	live:AddProgress({text = "Reel progress", get = function()return (reelProgressPercent or 0) / 100 end})
	live:AddButton({text = "Dump fishing GUI (F3)", callback = dumpFishingGui})
	live:AddButton({text = "Stop and unload (F4)", callback = function()if APP.stop then APP.stop()end end})
	live:AddParagraph({text = "Equip a fishing rod and stand by water. Enable Mouse & keyboard in Jael X. Automation pauses while you interact with this menu or leave Roblox focus."})
	local timing = win:NewTab("Timing", "Delays in milliseconds")
	local cast = timing:NewSection("Cast and equip", "left")
	for _, item in ipairs({{"Cast hold minimum", "castHoldMinMs", 100,2500},{"Cast hold maximum","castHoldMaxMs",100,2500},
		{"Cast retry","castRetryMs",1000,15000},{"Equip retry","equipRetryMs",100,2000},
		{"Equip key hold","equipKeyHoldMs",10,300},{"Equip settle","equipSettleMs",100,2000}}) do slider(cast,table.unpack(item)) end
	local shake = timing:NewSection("Shake and polling", "right")
	for _, item in ipairs({{"Shake delay minimum","shakeDelayMinMs",10,1000},{"Shake delay maximum","shakeDelayMaxMs",10,1000},
		{"Enter hold","enterKeyHoldMs",10,200},{"Worker delay","workerDelayMs",10,100},
		{"GUI refresh","guiRefreshMs",500,5000},{"Reel discovery","reelLookupMs",20,500}}) do slider(shake,table.unpack(item)) end
	local extra = win:NewTab("Extras", "AFK and intentional losses")
	local afk = extra:NewSection("Anti-AFK jump", "left")
	toggle(afk,"Enable anti-AFK jump","antiAfk",resetJumpSchedule)
	afk:AddDropdown({text = "Jump trigger", flag = "fisch/jumpTrigger", options = {"Either", "Shakes", "Catches"}, default = state.jumpTrigger,
		callback = function(value)state.jumpTrigger = value;resetJumpSchedule()end})
	slider(afk,"Shakes before jump minimum","jumpShakesMin",1,500)
	slider(afk,"Shakes before jump maximum","jumpShakesMax",1,500)
	slider(afk,"Rod slot (0 = auto)","jumpRodSlot",0,10)
	afk:AddParagraph({text = "Auto uses the slot confirmed by Auto Equip, falling back to slot 1. Set your rod slot manually if needed. Either queues a jump when either activity threshold is reached; jumping waits until fishing is idle."})
	slider(afk,"Delay after storing rod (ms)","jumpUnequipDelayMs",50,3000)
	slider(afk,"Space hold (ms)","jumpSpaceHoldMs",20,300)
	slider(afk,"Delay after jump (ms)","jumpLandingDelayMs",50,5000)
	slider(afk,"Delay after equip (ms)","jumpEquipDelayMs",50,3000)
	slider(afk,"Catches before jump minimum","jumpCatchesMin",1,100)
	slider(afk,"Catches before jump maximum","jumpCatchesMax",1,100)
	afk:AddLabel({get = function()return jumpCycle.status end})
	local loss = extra:NewSection("Intentional losses", "right")
	toggle(loss,"Lose occasional fish","intentionalLoss",function()resetLossSchedule();resetReelController()end)
	slider(loss,"Normal reels minimum","lossEveryMin",1,1000)
	slider(loss,"Normal reels maximum","lossEveryMax",1,1000)
	loss:AddLabel({get = function()return lossCycle.active and "Losing this fish" or "Reels until loss: " .. tostring(lossCycle.remaining or "Not drawn")end})
	local diagnosis = win:NewTab("Diagnostics", "GUI and input compatibility")
	local geo = diagnosis:NewSection("Input state", "left")
	geo:AddLabel({get = function()return APP.inputReason or "Not sampled"end})
	geo:AddParagraph({text = "Shake detects the live button by class and taps Enter only. Reel holds/releases M1 using absolute coordinates or shared-parent UDim2 scale. Starting hides the menu; F1 pause resets the session."})
	local debug = diagnosis:NewSection("Runtime checks", "right")
	debug:AddLabel({get = function()return inputFocused() and "Input ready" or "Input paused / disabled / unfocused" end})
	debug:AddLabel({get = function()return jumpCycle.status end})
	debug:AddLabel({get = function()return "Unreadable GUI samples: " .. stats.geometryMissing end})
	debug:AddButton({text = "Refresh GUI cache", callback = function()guiCache.dirty = true;nextReelLookupAt = 0 end})
	debug:AddButton({text = "Print diagnostics", callback = function()log(HttpService:JSONEncode(APP.getDiagnostics()))end})
	fishing:Select()
	Library:Notify("Fisch / Jael X", "Ready. F1 starts; F4 unloads. Insert toggles the menu.", 5)
end)
if not okUI then
	if Library then pcall(function()Library:Unload()end);Library = nil end
	warn(TAG .. " UI unavailable: " .. tostring(uiError))
	warn(TAG .. " Use F1/F3/F4 and shared.FISCH_JAELX.")
end
--=========================== LOOPS ==========================--
local hotkeyConnection = UIS.InputBegan:Connect(function(inputObject)
	local key = inputObject.KeyCode
	if key == Enum.KeyCode.F1 then
		APP.setEnabled(not state.enabled)
	elseif key == Enum.KeyCode.F3 then
		task.spawn(dumpFishingGui)
	elseif key == Enum.KeyCode.F4 then
		if APP.stop then task.defer(APP.stop) end
	end
end)
APP.connections[#APP.connections + 1] = hotkeyConnection

task.spawn(function()
	while running() do
		if jumpCycle.keyHeld and (not state.enabled or jumpCycle.stage ~= "Jump") then pcall(releaseJumpKey) end
		if not state.enabled then releaseMouse();releaseHeldKeys() end
		if state.enabled then
			local ok, message = pcall(function()
				if jumpCycle.keyHeld and jumpCycle.stage ~= "Jump" and not releaseJumpKey() then return end
				if not checkCharacterState() then return end
				pollJumpCatches()
				if not inputFocused() then
					releaseMouse()
					releaseJumpKey()
					resetReelController()
					status = APP.inputReason or "Input paused"
					return
				end
				-- Complete the idle jump sequence before auto-equip can toggle the rod back on.
				if jumpCycle.stage and runAntiAfkJump(nil) then return end
				local sessionAgeMs = (now() - fishingSessionStartedAt) * 1000
				if fishingSessionActive and ((not reelWasSeen and sessionAgeMs > state.preReelTimeoutMs)
					or sessionAgeMs > state.sessionTimeoutMs) then
					fishingSessionActive = false
					status = "Fishing session timed out"
				end
				local fish, playerBar = findReelBars()
				if APP.geometryBlocked then
					APP.geometryBlocked = false
					releaseMouse();resetReelController()
					status = "GUI geometry unavailable; check Jael X profile"
					return
				end
				if updateReelEnding(fish, playerBar) then return end
				if fish and playerBar then
					lastReelDetectedAt = now()
					stats.reelSamples = stats.reelSamples + 1
					setPhase("Minigame")
					runReel(fish, playerBar)
					return
				end
				if reelSampleObject then
					stats.reelMisses = stats.reelMisses + 1
					-- Retry brief bridge gaps without dropping M1 or resetting velocity.
					-- Never steer using the previous frame's fish position.
					nextReelLookupAt = math.min(nextReelLookupAt, now() + 0.02)
					if lastReelDetectedAt and now() - lastReelDetectedAt < 0.15 then
						status = "Reel: waiting for a fresh GUI sample"
						return
					end
				end
				if reelSampleObject then releaseMouse(); resetReelController() end
				if lossCycle.object and lastReelDetectedAt and now() - lastReelDetectedAt >= 0.15 then
					lossCycle.object, lossCycle.active, lossCycle.hold = nil, false, nil
				end
				if runAutoEquip() then setPhase("Check"); return end
				local cache = refreshGuiCache(false)
				local shakeButton = findActiveShakeButton(cache.buttons)
				if shakeButton then
					setPhase("Shake")
					releaseMouse()
					runShake(cache.buttons, shakeButton)
					return
				end
				setPhase("Check")
				local tool = equippedTool()
				if runAntiAfkJump(tool) then return end
				local castReady = state.autoCast and not inputBusy and not mouseHeld
					and isFishingRod(tool) and not hasBobber(tool)
					and not fishingSessionActive
					and now() - lastCastAt >= state.castRetryMs / 1000
				if castReady then
					setPhase("Cast")
					runCast()
				else
					if hasBobber(tool) or fishingSessionActive then
						status = "Check: waiting for bite"
					elseif isFishingRod(tool) then
						status = "Check: cast cooldown"
					else
						status = "Check: waiting for rod"
					end
				end
			end)
			if not ok then
				status = "Automation worker failed"
				warn(TAG .. " " .. tostring(message))
				releaseMouse()
				releaseJumpKey()
				resetReelController()
				inputBusy = false
			end
		end
		local delayMs = state.enabled and math.max(10, state.workerDelayMs) or math.max(50, state.idleDelayMs)
		if state.enabled and phase == "Check" then delayMs = state.checkDelayMs end
		-- Scanner settings must not turn an active reel into one correction/second.
		if state.enabled and reelSampleObject then delayMs = math.min(delayMs, 20) end
		task.wait(delayMs / 1000)
	end
end)

--=========================== CLEANUP ==========================--
function APP.stop()
	if not APP.alive then return end
	APP.alive = false
	state.enabled = false
	releaseMouse()
	resetJumpSchedule()
	for _, connection in ipairs(APP.connections) do pcall(function() connection:Disconnect() end) end
	for key in pairs(heldKeys) do pcall(input.key_up, key) end
	if Library then pcall(function()Library:Unload()end);Library = nil end
	for index = #APP.windows, 1, -1 do pcall(function() APP.windows[index]:Remove() end) end
	APP.connections, APP.windows = {}, {}
	if shared.FISCH_JAELX == APP then shared.FISCH_JAELX = nil end
	log("unloaded.")
end

log("loaded. Keyboard backend: input.key_down/input.key_up")
log("F1 toggles automation, Insert toggles UI, and F4 unloads.")
while running() do task.wait(0.25) end
