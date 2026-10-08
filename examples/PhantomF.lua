--[[
	PF_ASSIST — JoX aim and ESP hub for Phantom Forces.
	Place: Phantom Forces (292439477). Runtime: Jael X, Lua 5.4.

	KEYS
	  Hold RMB -> aim at the closest enemy head inside the FOV
	  F2       -> toggle aim
	  F3       -> toggle chams
	  F4       -> stop and unload
	  RightCtrl -> show/hide the JoX menu
	  Handle: shared.PF_ASSIST (getgenv is unavailable in this VM).

	Measured: Player.Character and Player.Team are nil. Character models live
	under workspace.Players in randomized team folders. A BillboardGui marks
	the head; its TextLabel.TextColor3 is red (255,10,20) for enemies and cyan
	for allies. Never assume folder order or randomized object names.
	The six direct body parts report Size=0.001; drawing uses R6-sized volumes.
	These external volumes approximate R6 bodies. Map-only raycast checks are
	approximate OBB visibility; unreadable/incomplete map scans block aim.
	Camera.CFrame is read-only here: aim uses bounded relative mouse movement.
	Requires Jael X 1.31.5 Entity List and raycast APIs. Menu starts closed.
	Status reports distance/FOV/input blockers; RightCtrl opens settings.
	Name ESP reads ContentText: confirmed readable on Jael X 1.30 while Text
	fails with "Unsupported string layout" for these PlayerTag labels.
	Health follows visible PlayerTag.Health.Percent; hidden templates are not HP.
	Unknown health is omitted; no hidden template is presented as real HP.
	ESP uses one Entity List and one fresh native pose batch per render frame.
	Skeleton links measured head/torso/limb centers, not hidden engine joints.
]]

--=========================== LIFECYCLE ==========================--
local ENV = shared
if ENV.PF_ASSIST and ENV.PF_ASSIST.stop then
	pcall(ENV.PF_ASSIST.stop)
	task.wait(0.15)
end
local APP = { alive = true, stats = {}, connections = {}, visuals = {} }
ENV.PF_ASSIST = APP
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("RunService")
local CFG = {
	esp = true, skeleton = false,
	chamsStyle = "Silhouette", chamsOutline = true,
	chamsOutlineColor = Color3.new(1, 1, 1), chamsOutlineOpacity = 1, chamsThickness = 1.5,
	boxOpacity = 1, boxThickness = 1.5, boxBorder = true, boxBorderColor = Color3.new(0, 0, 0),
	boxBorderOpacity = 1, boxBorderThickness = 1, boxFilled = false,
	boxFillColor = Color3.new(0, 0, 0), boxFillOpacity = .15,
	boxCornerLength = .25, boxDashLength = 8, boxGapLength = 5,
	skeletonOpacity = 1, skeletonThickness = 1.5, skeletonBorder = true,
	skeletonBorderColor = Color3.new(0, 0, 0), skeletonBorderOpacity = .8, skeletonBorderThickness = 1,
	tracerOpacity = 1, tracerThickness = 1, tracerTarget = "Center", tracerBorder = false,
	tracerBorderColor = Color3.new(0, 0, 0), tracerBorderOpacity = 1, tracerBorderThickness = 1,
	nameOpacity = 1, nameFont = "Segoe UI", nameOffset = 3,
	healthColor = Color3.fromRGB(80, 235, 135), healthOpacity = 1,
	healthBackgroundColor = Color3.fromRGB(20, 20, 20), healthBackgroundOpacity = .7,
	healthThickness = 3, healthOffset = 4, healthSide = "Left",

	aim = true, chams = true, nametags = true, teamCheck = true, showFov = true,
	wallCheck = true, visibilityColors = true, lightweight = true,
	visibleColor = Color3.fromRGB(80, 235, 135),
	blockedColor = Color3.fromRGB(255, 70, 90),
	unknownColor = Color3.fromRGB(150, 150, 160),
	nameSize = 12, nameDistance = false, nameOutline = true,
	targetMode = "Closest to crosshair", targetPart = "Head", aimKey = "MB2", sticky = false,
	box2d = true, boxStyle = "Corners", tracers = false, tracerOrigin = "Bottom",
	healthBars = true, healthText = false, showAllies = false, visualRange = 2000,
	crosshair = false, targetLine = false, showStatus = true, thickness = 1,
	filledChams = true, rosterRate = 0.4,
	fovColor = Color3.fromRGB(160, 110, 255),
	fov = 160, smoothing = 6, maxDistance = 2000, opacity = 0.18,
	enemyColor = Color3.fromRGB(255, 70, 90),
	targetColor = Color3.fromRGB(255, 200, 65),
	allyColor = Color3.fromRGB(30, 230, 200),
}
for _, kind in ipairs({"chams", "box", "skeleton", "tracer", "name"}) do
	CFG[kind .. "UseEntityColor"] = true
	CFG[kind .. "Color"] = Color3.new(1, 1, 1)
end
local ranges = {
	smoothing={0,100}, fov={40,400}, maxDistance={10,10000}, visualRange={10,10000},
	opacity={0,1}, nameSize={6,64}, thickness={.1,8}, rosterRate={.2,2},
	chamsOutlineOpacity={0,1}, chamsThickness={.1,8}, boxOpacity={0,1}, boxThickness={.1,8},
	boxBorderOpacity={0,1}, boxBorderThickness={.1,8}, boxFillOpacity={0,1},
	boxCornerLength={.05,.5}, boxDashLength={1,40}, boxGapLength={1,40},
	skeletonOpacity={0,1}, skeletonThickness={.1,8}, skeletonBorderOpacity={0,1}, skeletonBorderThickness={.1,8},
	tracerOpacity={0,1}, tracerThickness={.1,8}, tracerBorderOpacity={0,1}, tracerBorderThickness={.1,8},
	nameOpacity={0,1}, nameOffset={0,30}, healthOpacity={0,1}, healthBackgroundOpacity={0,1},
	healthThickness={.1,12}, healthOffset={0,30},
}
local choices = {
	chamsStyle={"Silhouette","Wireframe","Volumes"}, boxStyle={"Corners","Full box","Dashed","3D"},
	tracerOrigin={"Top","Center","Bottom","Mouse"}, tracerTarget={"Top","Center","Bottom"},
	healthSide={"Left","Right","Bottom"}, nameFont={"Segoe UI","Arial","Consolas","Tahoma"},
	targetMode={"Closest to crosshair","Closest to player","Lowest health"}, targetPart={"Head","Torso"},
}
local function normalizeSetting(key, value)
	if type(CFG[key]) == "boolean" then assert(type(value)=="boolean", "Expected boolean");return value end
	if ranges[key] then
		assert(type(value)=="number" and value==value and math.abs(value)<math.huge, "Expected finite number")
		return math.clamp(value, ranges[key][1], ranges[key][2])
	end
	if choices[key] then
		for _, item in ipairs(choices[key]) do if value==item then return value end end
		error("Unknown option: " .. tostring(value))
	end
	if key=="aimKey" then
		assert(type(value)=="string" and (value=="None" or value:match("^MB[123]$") or Enum.KeyCode[value]), "Invalid key")
		return value
	end
	if typeof(CFG[key])=="Color3" then
		if typeof(value)=="Color3" then return value end
		assert(type(value)=="table" and #value==3, "Expected RGB color")
		for _, n in ipairs(value) do assert(type(n)=="number" and n==n and math.abs(n)<math.huge, "Invalid color") end
		return Color3.fromRGB(math.clamp(value[1],0,255),math.clamp(value[2],0,255),math.clamp(value[3],0,255))
	end
	error("Unknown setting: " .. tostring(key))
end
APP.config = CFG
APP.styleRevision = 1
local roster, ring, status = {}, nil, nil
local UI = { objects = {}, open = false, tab = "Aim", scroll = 0, x = 30, y = 65 }
APP.menuOpen = false
local HTTP = game:GetService("HttpService")
local configFile = "pf_jox_config.json"
local function saveConfig()
	pcall(function()
		local values = {}
		for k, v in pairs(CFG) do
			if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then values[k] = v
			elseif typeof(v)=="Color3" then values[k]={v.R*255,v.G*255,v.B*255} end
		end
		fs.write_async(configFile, HTTP:JSONEncode(values))
	end)
end
pcall(function()
	local ok,raw=pcall(function()return buffer.tostring(fs.read_async(configFile))end)
	if not ok then raw=buffer.tostring(fs.read_async("pf_assist_config.json")) end
	local values=HTTP:JSONDecode(raw)
	values.smoothing=values.smoothing or values.smooth
	-- Old per-script rate/body-bound options are intentionally retired. Keep existing visual flags.
	for _, kind in ipairs({"chams", "box", "skeleton", "tracer"}) do
		local key=kind .. "Thickness"
		if values[key]==nil and values.thickness~=nil then values[key]=values.thickness end
	end
	for key, value in pairs(values) do
		if CFG[key]~=nil then local valid, normalized=pcall(normalizeSetting,key,value);if valid then CFG[key]=normalized end end
	end
end)

local lastError = 0
local function running() return APP.alive and ENV.PF_ASSIST == APP end
local function read(o, k)
	if not o then return nil end
	local ok, value = pcall(function() return o[k] end)
	if ok then return value end
	return nil
end
local function children(o)
	local ok, result = pcall(function() return o:GetChildren() end)
	return ok and result or {}
end
local frameSerial=0
local shown=setmetatable({},{__mode="k"})
local function show(d)
	local previous=shown[d]
	shown[d]=frameSerial
	if not previous then d.Visible=true end
end
local function hide(d)
	if shown[d] then d.Visible=false;shown[d]=nil end
end
local function finishDrawings()
	for d,stamp in pairs(shown)do if stamp~=frameSerial then hide(d)end end
end
local function removeVisual(v)
	if v.entry then v.entry:Remove() end
end
function APP.stop()
	if not APP.alive then return end
	APP.alive = false
	for _, c in ipairs(APP.connections) do pcall(function() c:Disconnect() end) end
	for _, v in pairs(APP.visuals) do removeVisual(v) end
	APP.visuals = {}
	if APP.entityList then APP.entityList:Destroy() end
	if ring then pcall(function() ring:Remove() end) end
	if status then pcall(function() status:Remove() end) end
	saveConfig()
	for _, d in ipairs(UI.objects) do pcall(function() hide(d);d:Remove() end) end
	if APP.Library then pcall(function() APP.Library:Unload() end) end
	if ENV.PF_ASSIST == APP then ENV.PF_ASSIST = nil end
	print("[PF_ASSIST] unloaded.")
end
local function hideAll()
	for _, v in pairs(APP.visuals) do v.draw=false;v.entity.poses={};v.entity.poseNames={} end
end
local function report(err)
	APP.stats.lastError = tostring(err)
	if os.clock() - lastError > 5 then
		lastError = os.clock()
		warn("[PF_ASSIST] " .. tostring(err))
	end
end

--=========================== GAME ADAPTER ==========================--
local function readPlayerName(label)
	-- ContentText is the rendered plain text; Text uses a different native layout.
	for _, property in ipairs({ "ContentText", "Text" }) do
		local value = read(label, property)
		if type(value) == "string" then
			value = value:gsub("<.->", ""):match("^%s*(.-)%s*$")
			if value ~= "" and #value <= 64 and not value:find("[%c]") then return value end
		end
	end
	return nil
end
local function refreshHealth(e)
	-- The tag may arrive after the body or replace its frames during a respawn.
	e.healthFrame, e.healthBar = nil, nil
	local ok, container, fill = pcall(function()
		local frame = e.label:FindFirstChild("Health")
		return frame, frame and frame:FindFirstChild("Percent")
	end)
	if ok then e.healthFrame, e.healthBar = container, fill end
end
local function resolve(model)
	local e = { model = model, parts = {} }
	for _, part in ipairs(children(model)) do
		if part:IsA("BasePart") then
			e.parts[#e.parts + 1] = part
			for _, child in ipairs(children(part)) do
				if child:IsA("SpotLight") then e.torso = part end
				if child:IsA("BillboardGui") then
					e.head = part
					for _, label in ipairs(children(child)) do
						if label:IsA("TextLabel") then
							e.label = label
							e.name = readPlayerName(label)
							refreshHealth(e)
						end
					end
				end
			end
		end
	end
	if e.head and e.label and #e.parts >= 5 and #e.parts <= 8 then
		e.sizes={}
		for _,part in ipairs(e.parts)do
			local size=read(part,"Size")
			if not size or size.X<.05 or size.Y<.05 then size=part==e.head and Vector3.new(1.1,1.1,1.1)or part==e.torso and Vector3.new(2,2,1)or Vector3.new(.85,1.8,.85)end
			e.sizes[part]=size
		end
		return e
	end
end
local characterFolder
local function locateCharacters()
	if characterFolder and read(characterFolder,"Parent") then return characterFolder end
	local named=workspace:FindFirstChild("Players")
	if named then characterFolder=named;return named end
	-- Folder/model structure survives name obfuscation. Validate a player-tag body.
	for _,folder in ipairs(children(workspace))do
		if folder:IsA("Folder") then
			for _,team in ipairs(children(folder))do
				if team:IsA("Folder") then
					for _,model in ipairs(children(team))do
						if model:IsA("Model") then local ok,entity=pcall(resolve,model);if ok and entity then characterFolder=folder;return folder end end
					end
				end
			end
		end
	end
end
local attachEntity
local function refreshRoster()
	local folder = locateCharacters()
	local nextRoster, seen = {}, {}
	for _, team in ipairs(children(folder)) do
		for _, model in ipairs(children(team)) do
			if model:IsA("Model") then
				local key = model
				local old = APP.visuals[key]
				local ok, e = pcall(function()
					return old and read(old.entity.label,"Parent") and old.entity or resolve(model)
				end)
				if ok and e then
					e.key = key
					e.name = readPlayerName(e.label) or e.name
					refreshHealth(e)
					if attachEntity then attachEntity(e) end
					seen[key] = true
					nextRoster[#nextRoster + 1] = e
				end
			end
		end
	end
	for key, v in pairs(APP.visuals) do
		if not seen[key] then removeVisual(v); APP.visuals[key] = nil end
	end
	roster = nextRoster
end
local function classify(e)
	local c = read(e.label, "TextColor3")
	if not c then return nil end
	if math.abs(c.R * 255 - 255) <= 8 and math.abs(c.G * 255 - 10) <= 12
		and math.abs(c.B * 255 - 20) <= 12 then return true end
	-- Recognize the measured cyan and green squad labels; unknown colors are skipped.
	if c.G > 0.7 and c.R < 0.35 then return false end
	return nil
end
local function alive(e, hp)
	if not read(e.model, "Parent") then return false end
	return hp == nil or hp > 0
end
local function health(e)
	-- A hidden enemy tag can keep the template's full width. It is not verified HP.
	if not e.healthFrame or read(e.healthFrame,"Visible") == false then return nil end
	local size = read(e.healthBar,"Size")
	if not size or not size.X then return nil end
	local scale, offset = size.X.Scale, size.X.Offset or 0
	if type(scale)~="number" or scale~=scale or type(offset)~="number" then return nil end
	if offset~=0 then
		local parentSize=read(e.healthFrame,"AbsoluteSize")
		if not parentSize or parentSize.X<=0 then return nil end
		scale=scale+offset/parentSize.X
	end
	if scale<0 or scale>1 then return nil end
	return scale
end
local function metadata(e,now)
	if not e.teamAt or now-e.teamAt>=.25 then e.enemy=classify(e);e.teamAt=now end
	if not e.healthAt or now-e.healthAt>=.12 then
		e.hp=health(e);e.parent=read(e.model,"Parent");e.healthAt=now
	end
	return e.enemy,e.hp,e.parent~=nil
end
local function activation()
	local key = CFG.aimKey
	if key == "MB1" then return input.is_mouse_down(Enum.KeyCode.LeftButton)
	elseif key == "MB2" then return input.is_mouse_down(Enum.KeyCode.RightButton)
	elseif key == "MB3" then return input.is_mouse_down(Enum.KeyCode.MiddleButton)
	elseif key ~= "None" and Enum.KeyCode[key] then return UIS:IsKeyDown(Enum.KeyCode[key]) end
	return false
end
--=========================== MAP VISIBILITY ==========================--
local rayCache={root=nil,params=nil,thin={},ready=false,certified=false}
local spatialCache={root=nil,building=false,ready=false,failed=0,cells={},large={},parts=0}
local visibilityEntries,visibilityRequests={},{}
local buildSpatialCache
local function prepareRayCache(root,force)
	if rayCache.root==root and rayCache.ready and not force then return end
	visibilityEntries={};spatialCache={root=root,building=false,ready=false,failed=0,cells={},large={},parts=0}
	local params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude
	local excluded,thin={},{}
	local top=root:GetChildren()
	if #top>2048 then
		params.FilterDescendantsInstances={}
		rayCache={root=root,params=params,thin={},ready=true,certified=false}
		buildSpatialCache(root,top,true);return
	end
	local ok,nodes=pcall(function()return root:GetDescendants()end)
	if not ok then
		params.FilterDescendantsInstances={}
		rayCache={root=root,params=params,thin={},ready=true,certified=false}
		buildSpatialCache(root,top,true);return
	end
	-- Large snapshots go directly to the grid instead of paying for a doomed
	-- capped native scan and then reading every part a second time.
	if #nodes>8192 then
		params.FilterDescendantsInstances={}
		rayCache={root=root,params=params,thin={},ready=true,certified=false}
		buildSpatialCache(root,nodes,false);return
	end
	for index,part in ipairs(nodes)do
		if index%64==0 then collectgarbage("step",128);task.wait(.001);if not running()then error("Stopped")end end
		if part:IsA("BasePart")then
			local size,cf=read(part,"Size"),read(part,"CFrame")
			if size and cf and size.X>0 and size.Y>0 and size.Z>0
				and (size.X<.01 or size.Y<.01 or size.Z<.01)then
				excluded[#excluded+1]=part;thin[#thin+1]=part
			end
		end
	end
	-- Native filters allow 128 instances. Never silently omit excess colliders.
	assert(#excluded<=128,"Too many thin map colliders")
	params.FilterDescendantsInstances=excluded
	rayCache={root=root,params=params,thin=thin,ready=true,certified=false}
	visibilityEntries={}
	spatialCache={root=root,building=false,ready=false,failed=0,cells={},large={},parts=0}
	if force then raycast.refresh(root,params)end
end
local function thinIntersection(part,origin,destination)
	local cf,size=read(part,"CFrame"),read(part,"Size")
	if not cf or not size then return nil end
	local o=cf:PointToObjectSpace(origin);local d=cf:VectorToObjectSpace(destination-origin)
	local lo,hi=0,1
	for _,axis in ipairs({"X","Y","Z"})do
		local half=size[axis]/2;local a,b=o[axis],d[axis]
		if half<=0 then return nil end
		if math.abs(b)<1e-9 then if math.abs(a)>half then return false end
		else
			local first,last=(-half-a)/b,(half-a)/b
			if first>last then first,last=last,first end
			lo,hi=math.max(lo,first),math.min(hi,last)
			if lo>hi then return false end
		end
	end
	return lo<1 and hi>0
end
-- Native scenes cap part count. Larger maps use an immutable spatial snapshot,
-- built cooperatively, then segment traversal touches only intersected grid cells.
local CELL=64
local function cellKey(x,y,z)return x..":"..y..":"..z end
buildSpatialCache=function(root,nodes,recursive)
	if spatialCache.building then return end
	local cache={root=root,building=true,ready=false,failed=0,cells={},large={},parts=0}
	spatialCache=cache
	task.spawn(function()
		local ok,err=pcall(function()
			local queue=nodes or root:GetChildren();local tail=#queue;nodes=nil
			local index=0
			while index<tail do
				index=index+1;local part=queue[index];queue[index]=nil
				if not running()or spatialCache~=cache then return end
				if index%32==0 then
					collectgarbage("step",256)
					task.wait(.002)
				end
				if part:IsA("BasePart")then
					local size,cf=read(part,"Size"),read(part,"CFrame")
					if not size or not cf or size.X<=0 or size.Y<=0 or size.Z<=0 then cache.failed=cache.failed+1
					else
						-- Store only numbers, not proxy CFrames and their vector tables.
						local box={cf:GetComponents()};box[13],box[14],box[15]=size.X/2,size.Y/2,size.Z/2
						local hx,hy,hz=box[13],box[14],box[15]
						local ex=math.abs(box[4])*hx+math.abs(box[5])*hy+math.abs(box[6])*hz
						local ey=math.abs(box[7])*hx+math.abs(box[8])*hy+math.abs(box[9])*hz
						local ez=math.abs(box[10])*hx+math.abs(box[11])*hy+math.abs(box[12])*hz
						local ax,bx=math.floor((box[1]-ex)/CELL),math.floor((box[1]+ex)/CELL)
						local ay,by=math.floor((box[2]-ey)/CELL),math.floor((box[2]+ey)/CELL)
						local az,bz=math.floor((box[3]-ez)/CELL),math.floor((box[3]+ez)/CELL)
						if (bx-ax+1)*(by-ay+1)*(bz-az+1)>128 then cache.large[#cache.large+1]=box
						else for x=ax,bx do for y=ay,by do for z=az,bz do
							local key=cellKey(x,y,z);local cell=cache.cells[key]or {};cache.cells[key]=cell;cell[#cell+1]=box
						end end end end
						cache.parts=cache.parts+1
					end
				end
				if recursive~=false then
					for _,child in ipairs(part:GetChildren())do tail=tail+1;queue[tail]=child end
				end
			end
			if spatialCache==cache and running()then cache.ready=cache.failed==0;cache.finished=os.clock()end
		end)
		cache.building=false
		if not ok then cache.error=tostring(err);report(err)end
	end)
end
local function numericBoxIntersection(box,origin,direction)
	local x,y,z=origin.X-box[1],origin.Y-box[2],origin.Z-box[3]
	local lo,hi=0,1
	for axis=1,3 do
		local a=x*box[3+axis]+y*box[6+axis]+z*box[9+axis]
		local d=direction.X*box[3+axis]+direction.Y*box[6+axis]+direction.Z*box[9+axis]
		local half=box[12+axis]
		if math.abs(d)<1e-9 then if math.abs(a)>half then return false end
		else local first,last=(-half-a)/d,(half-a)/d
			if first>last then first,last=last,first end
			lo,hi=math.max(lo,first),math.min(hi,last);if lo>hi then return false end
		end
	end
	return lo<1 and hi>0
end
local function spatialVisibility(origin,destination)
	local cache=spatialCache
	APP.stats.spatialParts=cache.parts;APP.stats.spatialReady=cache.ready
	if not cache.ready then
		APP.stats.raycastState=cache.error or string.format("Spatial cache: %d parts / %d unreadable",cache.parts,cache.failed)
		return nil
	end
	local direction=destination-origin;local tested={}
	local function blocked(box)
		if tested[box]then return false end;tested[box]=true
		return numericBoxIntersection(box,origin,direction)
	end
	for _,box in ipairs(cache.large)do if blocked(box)then return false end end
	local axes={"X","Y","Z"};local cell,step,nextAt,increment={},{},{},{}
	for i,axis in ipairs(axes)do
		local a,d=origin[axis],direction[axis];cell[i]=math.floor(a/CELL)
		step[i]=d>0 and 1 or d<0 and -1 or 0
		if d==0 then nextAt[i],increment[i]=math.huge,math.huge
		else nextAt[i]=((cell[i]+(d>0 and 1 or 0))*CELL-a)/d;increment[i]=CELL/math.abs(d)end
	end
	for iteration=1,4096 do
		for _,box in ipairs(cache.cells[cellKey(cell[1],cell[2],cell[3])]or {})do if blocked(box)then return false end end
		local nextStep=math.min(nextAt[1],nextAt[2],nextAt[3]);if nextStep>1 then
			APP.stats.raycastState="Spatial map ready: "..cache.parts.." parts";return true
		end
		for i=1,3 do if nextAt[i]<=nextStep+1e-10 then cell[i]=cell[i]+step[i];nextAt[i]=nextAt[i]+increment[i]end end
	end
	APP.stats.raycastState="Spatial ray traversal limit";return nil
end
local function pointVisibility(origin, destination)
	if not raycast or type(raycast.cast)~="function" then
		APP.stats.raycastState="Raycast API unavailable"
		return nil
	end
	local root=workspace:FindFirstChild("Map")
	root=root and (root:FindFirstChild("MapParts")or root)
	if not root or not read(root,"Parent") then
		APP.stats.raycastState="Waiting for Workspace.Map"
		return nil
	end
	-- Never force refresh per target: the native scanner must finish its batch.
	-- A map-only root excludes player bounds and viewmodels from wall checks.
	local prepared,err=pcall(prepareRayCache,root,false)
	if not prepared then APP.stats.raycastState="Map cache error: "..tostring(err);return nil end
	if spatialCache.building or spatialCache.ready or spatialCache.error or spatialCache.failed>0 then
		local started=os.clock();local clear=spatialVisibility(origin,destination)
		APP.stats.rayCalls=(APP.stats.rayCalls or 0)+1;APP.stats.rayMs=(os.clock()-started)*1000
		return clear
	end
	local direction=destination-origin
	local started=os.clock()
	local ok,hit,scan=pcall(raycast.cast,root,origin,direction,rayCache.params)
	APP.stats.rayCalls=(APP.stats.rayCalls or 0)+1
	APP.stats.rayMs=(os.clock()-started)*1000
	local clear=ok and (hit==nil or hit.Distance>=direction.Magnitude-.02)
	APP.stats.rayScan=scan;APP.stats.thinColliders=#rayCache.thin
	if not ok then APP.stats.raycastState="Raycast error";return nil end
	if type(scan)=="table"and scan.Truncated==true then buildSpatialCache(root);return nil end
	if type(scan)~="table" or scan.Truncated==true or (tonumber(scan.Skipped)or 0)>0 then
		rayCache.certified=false
		APP.stats.raycastState=scan and scan.Truncated and "Map scan truncated" or "Map scan incomplete / skipped geometry"
		return nil
	end
	if scan.Complete==true then rayCache.certified=true end
	-- During native rebuild, cast still intersects the previous finished boxes.
	-- Accept only a previously certified snapshot, bounded in age; query endpoints
	-- remain current. Initial/errored/truncated scenes never count as clear.
	local snapshotReady=scan.Complete==true or (rayCache.certified and (scan.Parts or 0)>0
		and type(scan.AgeMs)=="number" and scan.AgeMs<=5000)
	if not snapshotReady then APP.stats.raycastState="Building initial map snapshot";return nil end
	APP.stats.raycastState=string.format("%s: %d parts / %d thin colliders",scan.Complete and "Map ready"or "Rebuilding (using certified snapshot)",scan.Parts or 0,#rayCache.thin)
	if clear then
		for _,part in ipairs(rayCache.thin)do
			local success,blocked=pcall(thinIntersection,part,origin,destination)
			if not success or blocked==nil then return nil end
			if blocked then return false end
		end
	end
	return clear
end
local function cachedVisibility(key,origin,destination,now)
	local entry=visibilityEntries[key]
	if not entry or not entry.origin or not entry.point then return nil,nil end
	local color;if now-entry.confirmedAt<=3 then color=entry.clear end
	-- Keep visual feedback separate from aim authorization. A stale green color
	-- cannot authorize aim after the camera or the target has moved.
	local fresh=entry.latestKnown and now-entry.checkedAt<=.2
		and (origin-entry.origin).Magnitude<=2 and (destination-entry.point).Magnitude<=2
	local aimClear=fresh and entry.clear==true
	return color,aimClear
end
local function sampleVisibility(request)
	local clear=pointVisibility(request.origin,request.point)
	local entry=visibilityEntries[request.key]or {confirmedAt=-math.huge}
	entry.checkedAt=os.clock();entry.latestKnown=clear~=nil
	if clear~=nil then entry.clear=clear;entry.confirmedAt=entry.checkedAt
		entry.origin,entry.point=request.origin,request.point end
	visibilityEntries[request.key]=entry
end
-- Advance the fair queue only for requests actually visited. A priority sample
-- must not consume an unseen player's slot (even-sized rosters used to starve).
local function updateVisibilityBatch(requests,priority,cursor,maxCount,budget)
	if #requests==0 then return 0 end
	local started,count,visited=os.clock(),0,0
	local refresh=CFG.lightweight and .08 or .05
	local function due(request,interval)
		local entry=visibilityEntries[request.key]
		return not entry or started-entry.checkedAt>=interval
	end
	local function sample(request)
		local ok,err=pcall(sampleVisibility,request)
		if not ok then report(err)end
		count=count+1
	end
	if priority and due(priority,.04)then sample(priority)end
	while visited<#requests and count<maxCount do
		if count>0 and os.clock()-started>=budget then break end
		cursor=cursor%#requests+1;visited=visited+1
		local request=requests[cursor]
		if (not priority or request.key~=priority.key)and due(request,refresh)then sample(request)end
	end
	APP.stats.rayBatchQueries=count
	APP.stats.rayBatchMs=(os.clock()-started)*1000
	return cursor
end
local function canAimAt(lineOfSight)
	return not CFG.wallCheck or lineOfSight==true
end
local function visibilityColor(state, selected)
	if state.enemy and CFG.visibilityColors then
		if state.lineOfSight==true then return selected and CFG.targetColor or CFG.visibleColor end
		if state.lineOfSight==false then return CFG.blockedColor end
		return CFG.unknownColor
	end
	return selected and CFG.targetColor or state.enemy and CFG.enemyColor or CFG.allyColor
end

local function drawLine(d,a,b,color)
	d.From,d.To = a,b
	if d.Color~=color then d.Color=color end
	if d.Thickness~=CFG.thickness then d.Thickness=CFG.thickness end
	show(d)
end
--=========================== ENTITY LIST ESP ==========================--
local function featureColor(kind, entity)
	local v=entity.Options.Adapter
	return CFG[kind .. "UseEntityColor"] and (v.color or CFG.unknownColor) or CFG[kind .. "Color"]
end
local colorCallbacks={}
for _, kind in ipairs({"chams","box","skeleton","tracer","name"}) do
	colorCallbacks[kind]=function(entity)return featureColor(kind,entity)end
end
local function configureFeatures(v)
	local entry=v.entry
	entry:AddChams({Enabled=CFG.chams,Style=CFG.chamsStyle,Color=colorCallbacks.chams,
		Transparency=CFG.opacity,Filled=CFG.filledChams,Outline=CFG.chamsOutline,
		OutlineColor=CFG.chamsOutlineColor,OutlineTransparency=CFG.chamsOutlineOpacity,Thickness=CFG.chamsThickness})
	entry:AddBox({Enabled=CFG.box2d,Style=CFG.boxStyle=="Corners" and "Corner" or CFG.boxStyle=="Full box" and "Full" or CFG.boxStyle,
		Color=colorCallbacks.box,Transparency=CFG.boxOpacity,Thickness=CFG.boxThickness,
		Border=CFG.boxBorder,BorderColor=CFG.boxBorderColor,BorderTransparency=CFG.boxBorderOpacity,BorderThickness=CFG.boxBorderThickness,
		Filled=CFG.boxFilled,FillColor=CFG.boxFillColor,FillTransparency=CFG.boxFillOpacity,
		CornerLength=CFG.boxCornerLength,DashLength=CFG.boxDashLength,GapLength=CFG.boxGapLength})
	entry:AddSkeleton({Enabled=CFG.skeleton,Color=colorCallbacks.skeleton,Transparency=CFG.skeletonOpacity,
		Thickness=CFG.skeletonThickness,Border=CFG.skeletonBorder,BorderColor=CFG.skeletonBorderColor,
		BorderTransparency=CFG.skeletonBorderOpacity,BorderThickness=CFG.skeletonBorderThickness,Connections=v.entity.links})
	entry:AddTracer({Enabled=CFG.tracers,Origin=CFG.tracerOrigin,Target=CFG.tracerTarget,
		Color=colorCallbacks.tracer,Transparency=CFG.tracerOpacity,Thickness=CFG.tracerThickness,
		Border=CFG.tracerBorder,BorderColor=CFG.tracerBorderColor,BorderTransparency=CFG.tracerBorderOpacity,BorderThickness=CFG.tracerBorderThickness})
	entry:AddNameTag({Enabled=CFG.nametags or CFG.nameDistance,Color=colorCallbacks.name,Transparency=CFG.nameOpacity,
		Size=CFG.nameSize,Font=CFG.nameFont,Outline=CFG.nameOutline,Offset=CFG.nameOffset,ShowDistance=false})
	entry:AddHealthBar({Enabled=CFG.healthBars,Color=CFG.healthColor,Transparency=CFG.healthOpacity,
		BackgroundColor=CFG.healthBackgroundColor,BackgroundTransparency=CFG.healthBackgroundOpacity,
		Thickness=CFG.healthThickness,Offset=CFG.healthOffset,Side=CFG.healthSide,ShowText=CFG.healthText})
	v.styleRevision=APP.styleRevision
end
attachEntity=function(e)
	local v=APP.visuals[e.key]
	if v and v.entity==e then return v end
	if v then removeVisual(v) end
	if not APP.entityList or APP.entityList.Count>=128 then return nil end
	e.poses={};e.poseNames={};e.partNames={};e.links={}
	for i,part in ipairs(e.parts) do
		local name=part==e.head and "Head" or part==e.torso and "Torso" or "Limb"..i
		e.partNames[i]=name
		-- PF names are obfuscated: link actual body centers, without pretending to read Motor6Ds.
		if e.torso and part~=e.torso then e.links[#e.links+1]={"Torso",name} end
	end
	v={entity=e,draw=false}
	local descriptor={Name=e.name or "Player",Parts=function()return v.draw and e.poses or {}end}
	v.descriptor=descriptor
	v.entry=APP.entityList:Add(descriptor,{Adapter=v})
	APP.visuals[e.key]=v
	configureFeatures(v)
	return v
end
local function refreshPoses()
	local requested,owners={},{}
	for _,e in ipairs(roster) do
		e.poses={};e.poseNames={}
		for i,part in ipairs(e.partNames and e.parts or {}) do
			if #requested<4096 then requested[#requested+1]=part;owners[#owners+1]={e,i} end
		end
	end
	if #requested==0 then return end
	local ok,snapshot=pcall(entities.get_parts_snapshot,requested)
	if not ok then report(snapshot);return end
	for i,owner in ipairs(owners) do
		local pose=snapshot.parts[i]
		if pose and typeof(pose.cframe)=="CFrame" then
			local e,index=owner[1],owner[2]
			local part={Name=e.partNames[index],CFrame=pose.cframe,Size=e.sizes[e.parts[index]]}
			e.poses[#e.poses+1]=part;e.poseNames[part.Name]=part
		end
	end
	APP.stats.poseParts=#requested
end
local function renderEntity(state, selected)
	local e=state.e;local v=APP.visuals[e.key]
	if not v then return end
	v.draw=true;v.color=visibilityColor(state,selected)
	if v.styleRevision~=APP.styleRevision then configureFeatures(v) end
	v.descriptor.Name=(CFG.nametags and (e.name or (state.enemy and "Enemy" or "Ally")) or "")
		..(CFG.nameDistance and string.format(" [%d studs]",math.floor(state.distance)) or "")
	v.descriptor.Health=state.hp and state.hp*100 or nil
	v.descriptor.MaxHealth=state.hp and 100 or nil
end
local targetLine=Drawing.new("Line");local cross={Drawing.new("Line"),Drawing.new("Line")}
UI.objects={targetLine,cross[1],cross[2]}
local lastFrame,lastStatus=0,0
local function frame(dt)
	local now=os.clock();frameSerial=frameSerial+1
	dt=math.min(.05,now-lastFrame);lastFrame=now
	-- Each retained primitive is hidden only when it stops being used.
	APP.menuOpen=APP.Library and APP.Library.Visible and APP.window and APP.window.visible or false
	APP.stats.enemies,APP.stats.allies,APP.stats.unknown,APP.stats.target=0,0,0,nil
	APP.stats.healthKnown,APP.stats.healthUnknown=0,0
	APP.stats.visibleEnemies,APP.stats.blockedEnemies,APP.stats.visibilityUnknown=0,0,0
	local camera=workspace.CurrentCamera;local cf=read(camera,"CFrame");local view=Drawing3D.GetViewportSize()
	if not cf or view.X<1 or view.Y<1 then hideAll();hide(targetLine);for _,d in ipairs(cross)do hide(d)end;ring.Visible=false;return end
	local center=Vector2.new(view.X/2,view.Y/2)
	ring.Position,ring.Radius,ring.Color,ring.Visible=center,CFG.fov,CFG.fovColor,CFG.showFov and CFG.aim
	if CFG.crosshair then drawLine(cross[1],center-Vector2.new(5,0),center+Vector2.new(5,0),CFG.fovColor);drawLine(cross[2],center-Vector2.new(0,5),center+Vector2.new(0,5),CFG.fovColor) end
	for _,v in pairs(APP.visuals) do v.draw=false end
	refreshPoses()
	local best,score,states=nil,math.huge,{}
	local requests,aimRequest,aimRequestScore={},nil,math.huge
	local held=activation();if not held then APP.lock=nil end
	for _,e in ipairs(roster) do
		local ok,err=pcall(function()
			local enemy,hp,present=metadata(e,now);if enemy==nil then APP.stats.unknown=APP.stats.unknown+1;return end
			if enemy then APP.stats.enemies=APP.stats.enemies+1 else APP.stats.allies=APP.stats.allies+1 end
			if hp==nil then APP.stats.healthUnknown=APP.stats.healthUnknown+1 else APP.stats.healthKnown=APP.stats.healthKnown+1 end
			if not present or hp~=nil and hp<=0 then return end
			if not enemy and CFG.teamCheck and not CFG.showAllies then return end
			local headPose=e.poseNames.Head;local head=headPose and headPose.CFrame.Position;if not head then return end
			local distance=(head-cf.Position).Magnitude;if distance<4 then return end
			local screen,on=Drawing3D.WorldToViewportPoint(head);if not on or screen.Z<=0 then return end
			local aimPose=e.poseNames[CFG.targetPart];local aimPosition=aimPose and aimPose.CFrame.Position
			if distance>math.max(CFG.visualRange,CFG.maxDistance)then return end
			local lineOfSight,aimClear
			if aimPosition and (CFG.wallCheck or CFG.visibilityColors)and (enemy or not CFG.teamCheck)then
				local request={key=e.key,origin=cf.Position,point=aimPosition}
				requests[#requests+1]=request
				local delta=(Vector2.new(screen.X,screen.Y)-center).Magnitude
				local priority=CFG.targetMode=="Closest to player"and distance or CFG.targetMode=="Lowest health"and hp or delta
				if CFG.targetMode=="Lowest health"and hp==nil then priority=nil end
				if CFG.sticky and held and APP.lock==e.key then priority=-1 end
				if (enemy or not CFG.teamCheck)and distance<=CFG.maxDistance and delta<=CFG.fov and priority and priority<aimRequestScore then
					aimRequest,aimRequestScore=request,priority
				end
				lineOfSight,aimClear=cachedVisibility(e.key,cf.Position,aimPosition,now)
			end
			if enemy then
				if lineOfSight==true then APP.stats.visibleEnemies=APP.stats.visibleEnemies+1
				elseif lineOfSight==false then APP.stats.blockedEnemies=APP.stats.blockedEnemies+1
				else APP.stats.visibilityUnknown=APP.stats.visibilityUnknown+1 end
			end
			local state={e=e,enemy=enemy,position=head,distance=distance,screen=screen,hp=hp,lineOfSight=lineOfSight}
			if distance<=CFG.visualRange and (enemy or CFG.showAllies) then states[#states+1]=state end
			if CFG.teamCheck and not enemy or distance>CFG.maxDistance then return end
			if not aimPosition or not canAimAt(aimClear) then return end
			local aimScreen,visible=screen,true
			if CFG.targetPart=="Torso"then aimScreen,visible=Drawing3D.WorldToViewportPoint(aimPosition)end
			if not visible then return end
			local delta=(Vector2.new(aimScreen.X,aimScreen.Y)-center).Magnitude;if delta>CFG.fov then return end
			local priority=delta
			if CFG.targetMode=="Closest to player" then priority=distance elseif CFG.targetMode=="Lowest health" then priority=state.hp end
			if priority==nil then return end
			if CFG.sticky and held and APP.lock==e.key then priority=-1 end
			if priority<score then score=priority;best={e=e,point=aimScreen} end
		end)
		if not ok then report(err) end
	end
	visibilityRequests=requests;APP.visibilityPriority=aimRequest
	for _,state in ipairs(states) do local ok,err=pcall(renderEntity,state,best and best.e.key==state.e.key,view);if not ok then report(err) end end
	local enabled=true;if input.get_status then local ok,info=pcall(input.get_status);if ok then enabled=info.enabled end end
	local reason=not CFG.aim and "Disabled" or APP.menuOpen and "Menu open" or not input.is_window_focused() and "Game unfocused" or not enabled and "Input disabled" or not held and "Hold aim key" or not best and (CFG.wallCheck and "No visible target / FOV / range" or "No target in FOV / range") or "Tracking"
	if not best then APP.lock=nil end
	if best then
		APP.stats.target=best.e.name or "Enemy"
		if CFG.targetLine then drawLine(targetLine,center,Vector2.new(best.point.X,best.point.Y),CFG.targetColor) end
	end
	if reason=="Tracking" then
		APP.lock=best.e.key
		local factor=CFG.smoothing<=0 and 1 or 1-math.exp(-60*dt/CFG.smoothing)
		local limit=CFG.smoothing<=0 and CFG.fov or 35
		local dx=math.clamp((best.point.X-center.X)*factor,-limit,limit);local dy=math.clamp((best.point.Y-center.Y)*factor,-limit,limit)
		if math.abs(dx)>1e-6 or math.abs(dy)>1e-6 then local ok,err=pcall(input.mouse_move_relative,Vector2.new(dx,dy));if not ok then reason="Input error";report(err) else APP.stats.mouseCalls=(APP.stats.mouseCalls or 0)+1 end end
	end
	APP.stats.aimReason,APP.stats.frames,APP.stats.drawn=reason,(APP.stats.frames or 0)+1,#states
	if now-lastStatus>=.15 then
		lastStatus=now
		local text=string.format("PF JoX | %s | Enemies %d | Drawn %d | %s",reason,APP.stats.enemies,#states,APP.stats.target or "No target")
		if status.Text~=text then status.Text=text end
	end
	status.Visible=CFG.showStatus
	finishDrawings()
end
--=========================== CORE START ==========================--
if read(game,"PlaceId")~=292439477 then warn("[PF_ASSIST] This adapter requires Phantom Forces (292439477).");APP.stop();return end
if type(entities)~="table" or type(entities.new)~="function" or type(entities.get_parts_snapshot)~="function" then
	warn("[PF_ASSIST] Requires Jael X 1.31.5 Entity List. Update the app first.");APP.stop();return
end
ring=Drawing.new("Circle");ring.NumSides=64;ring.Thickness=1
status=Drawing.new("Text");status.Position=Vector2.new(20,12);status.Size=14;status.Color=Color3.fromRGB(235,235,245);status.Outline=true
APP.connections[#APP.connections+1]=UIS.InputBegan:Connect(function(event)
	if not running() then return end
	local key=event.KeyCode.Name
	if key=="F4" or key=="End" then APP.stop()
	elseif key=="F2" then CFG.aim=not CFG.aim;if APP.aimControl then APP.aimControl:Set(CFG.aim,true) end
	elseif key=="F3" then CFG.chams=not CFG.chams;APP.styleRevision=APP.styleRevision+1;if APP.chamsControl then APP.chamsControl:Set(CFG.chams,true) end end
end)
APP.connections[#APP.connections+1]=RS.PreRender:Connect(function(dt)if running() then local ok,err=pcall(frame,dt);if not ok then hideAll();report(err) end end end)
-- Register after the adapter callback: descriptor poses/styles belong to the current render frame.
APP.entityList=entities.new({HideDead=true,Filter=function(entry)
	local v=entry.Options.Adapter
	return running() and CFG.esp and v.draw
end})
-- Visibility uses short batches with a time budget, independent of overlay FPS.
 task.spawn(function()
	local cursor,nextPrune=0,0
	while running()do
		if os.clock()>=nextPrune then
			nextPrune=os.clock()+2
			APP.stats.luaMemoryMB=collectgarbage("count")/1024
			for key in pairs(visibilityEntries)do if not read(key,"Parent")then visibilityEntries[key]=nil end end
		end
		local requests=visibilityRequests
		if (CFG.wallCheck or CFG.visibilityColors)and #requests>0 then
			cursor=updateVisibilityBatch(requests,APP.visibilityPriority,cursor,CFG.lightweight and 6 or 8,.002)
		end
		task.wait(CFG.lightweight and .016 or .01)
	end
 end)
task.spawn(function()while running() do local ok,err=pcall(refreshRoster);if not ok then roster={};report(err) end;task.wait(CFG.rosterRate) end end)
--=========================== JOX INTERFACE ==========================--
local okUI,whyUI=pcall(function()
	local ok,Library=pcall(function()
		local localOK,fn=pcall(loadfile,"scripts/JoX-Library.lua")
		if localOK and fn then return fn() end
		local source=game:HttpGet("https://raw.githubusercontent.com/TrollLexBR/Jael-X/main/JoX-Library.lua")
		local compiled,err=loadstring(source,"@JoX-Library.lua");assert(compiled,err);return compiled()
	end)
	assert(ok and type(Library)=="table",tostring(Library))
	APP.Library=Library
	local w=Library:NewWindow({title="Phantom Forces",subtitle="JOX / ENTITY LIST ESP",configId="PFJoX",width=900,height=640,
		configAliases={["pf/thickness"]="pf/chamsThickness"}})
	APP.window=w;APP.controls={}
	local function changed(key,value)
		CFG[key]=normalizeSetting(key,value);APP.styleRevision=APP.styleRevision+1;saveConfig()
	end
	local function color(section,key,title)
		local handle=section:AddColorPicker({text=title,flag="pf/"..key,default=CFG[key],callback=function(value)changed(key,value)end})
		APP.controls[key]=handle;return handle
	end
	local function toggle(section,key,title)
		local handle=section:AddToggle({text=title,flag="pf/"..key,default=CFG[key],callback=function(value)changed(key,value)end})
		APP.controls[key]=handle;return handle
	end
	local function slider(section,key,title,min,max,step)
		local handle=section:AddSlider({text=title,flag="pf/"..key,min=min,max=max,step=step,default=CFG[key],callback=function(value)changed(key,value)end})
		APP.controls[key]=handle;return handle
	end
	local function dropdown(section,key,title,options)
		local handle=section:AddDropdown({text=title,flag="pf/"..key,options=options,default=CFG[key],callback=function(value)changed(key,value)end})
		APP.controls[key]=handle;return handle
	end
	local combat=w:NewTab("Aim","Activation, targeting and motion")
	local targeting=combat:NewSection("Targeting","left")
	APP.aimControl=toggle(targeting,"aim","Enable aim")
	dropdown(targeting,"targetMode","Target priority",{"Closest to crosshair","Closest to player","Lowest health"})
	dropdown(targeting,"targetPart","Target part",{"Head","Torso"})
	toggle(targeting,"teamCheck","Aim team check")
	toggle(targeting,"wallCheck","Aim visibility check (raycast)")
	toggle(targeting,"sticky","Keep selected target while holding")
	slider(targeting,"maxDistance","Aim range (studs)",10,10000,10)
	targeting:AddParagraph({text="Lowest health uses the replicated health-bar percentage. Unknown health is excluded. Targeting remains inside the FOV and selected range."})
	local behavior=combat:NewSection("Activation & motion","right")
	behavior:AddKeybind({text="Aim activation (hold)",flag="pf/aimKey",default=CFG.aimKey,mode="Hold",onChanged=function(key)changed("aimKey",key)end})
	slider(behavior,"smoothing","Smooth (0 = instant)",0,100,.5)
	slider(behavior,"fov","FOV radius (pixels)",40,400,1)
	toggle(behavior,"showFov","Show FOV")
	toggle(behavior,"targetLine","Line to selected target")
	behavior:AddParagraph({text="Close the menu before aiming. The selected Roblox window must be focused and Mouse & keyboard enabled. Jael X 1.30 preserves fractional mouse movements."})
	local visuals=w:NewTab("ESP","Entity membership, range and visibility")
	local players=visuals:NewSection("Entity List","left")
	toggle(players,"esp","Enable ESP")
	toggle(players,"showAllies","Show allies")
	slider(players,"visualRange","ESP range (studs)",10,10000,10)
	toggle(players,"visibilityColors","Visibility colors")
	players:AddParagraph({text="Models are explicitly added to one Entity List. Roster changes retire old characters; poses are read in one fresh native batch each frame. ESP does not depend on Player.Character."})
	local overview=visuals:NewSection("Features","right")
	APP.chamsControl=toggle(overview,"chams","Body chams")
	toggle(overview,"box2d","Boxes")
	toggle(overview,"skeleton","Skeleton")
	toggle(overview,"nametags","Player names")
	toggle(overview,"nameDistance","Distance labels")
	toggle(overview,"healthBars","Health bars")
	toggle(overview,"tracers","Player tracers")
	local chams=w:NewTab("Chams","Silhouette, wireframe and volume styles")
	local fill=chams:NewSection("Fill","left")
	dropdown(fill,"chamsStyle","Chams style",{"Silhouette","Wireframe","Volumes"})
	toggle(fill,"filledChams","Filled chams")
	slider(fill,"opacity","Chams opacity",0,1,.01)
	toggle(fill,"chamsUseEntityColor","Use team / visibility color")
	color(fill,"chamsColor","Custom fill color")
	fill:AddParagraph({text="Silhouette unions all visible body volumes and applies opacity once. Wireframe draws part edges; Volumes preserves individual faces. Bodies remain approximations of R6 anatomy."})
	local outline=chams:NewSection("Outline / wire","right")
	toggle(outline,"chamsOutline","Show outline / wire")
	color(outline,"chamsOutlineColor","Outline / wire color")
	slider(outline,"chamsOutlineOpacity","Outline / wire opacity",0,1,.01)
	slider(outline,"chamsThickness","Outline / wire thickness",.1,8,.1)
	local boxes=w:NewTab("Boxes","Full, corner, dashed and 3D boxes")
	local boxLines=boxes:NewSection("Lines","left")
	dropdown(boxLines,"boxStyle","Box style",{"Corners","Full box","Dashed","3D"})
	toggle(boxLines,"boxUseEntityColor","Use team / visibility color")
	color(boxLines,"boxColor","Custom line color")
	slider(boxLines,"boxOpacity","Line opacity",0,1,.01)
	slider(boxLines,"boxThickness","Line thickness",.1,8,.1)
	slider(boxLines,"boxCornerLength","Corner fraction",.05,.5,.01)
	slider(boxLines,"boxDashLength","Dash length",1,40,1)
	slider(boxLines,"boxGapLength","Dash gap",1,40,1)
	local boxBorder=boxes:NewSection("Border & fill","right")
	toggle(boxBorder,"boxBorder","Show border")
	color(boxBorder,"boxBorderColor","Border color")
	slider(boxBorder,"boxBorderOpacity","Border opacity",0,1,.01)
	slider(boxBorder,"boxBorderThickness","Border thickness",.1,8,.1)
	toggle(boxBorder,"boxFilled","Filled box")
	color(boxBorder,"boxFillColor","Fill color")
	slider(boxBorder,"boxFillOpacity","Fill opacity",0,1,.01)
	local skeleton=w:NewTab("Skeleton","Head, torso and limb-center links")
	local bones=skeleton:NewSection("Links","left")
	toggle(bones,"skeletonUseEntityColor","Use team / visibility color")
	color(bones,"skeletonColor","Custom skeleton color")
	slider(bones,"skeletonOpacity","Skeleton opacity",0,1,.01)
	slider(bones,"skeletonThickness","Skeleton thickness",.1,8,.1)
	bones:AddParagraph({text="The PF adapter links the tagged head and discovered torso to other body-part centers. Missing poses skip their links. This is an approximate stick figure, not engine joint extraction."})
	local boneBorder=skeleton:NewSection("Border","right")
	toggle(boneBorder,"skeletonBorder","Show border")
	color(boneBorder,"skeletonBorderColor","Border color")
	slider(boneBorder,"skeletonBorderOpacity","Border opacity",0,1,.01)
	slider(boneBorder,"skeletonBorderThickness","Border thickness",.1,8,.1)
	local labels=w:NewTab("Labels & health","Names, distance and available health")
	local names=labels:NewSection("Text","left")
	toggle(names,"nameUseEntityColor","Use team / visibility color")
	color(names,"nameColor","Custom text color")
	slider(names,"nameOpacity","Text opacity",0,1,.01)
	slider(names,"nameSize","Text size",6,64,1)
	dropdown(names,"nameFont","Font",{"Segoe UI","Arial","Consolas","Tahoma"})
	toggle(names,"nameOutline","Text outline")
	slider(names,"nameOffset","Text offset",0,30,1)
	local bars=labels:NewSection("Health","right")
	dropdown(bars,"healthSide","Bar side",{"Left","Right","Bottom"})
	color(bars,"healthColor","Health color")
	slider(bars,"healthOpacity","Health opacity",0,1,.01)
	color(bars,"healthBackgroundColor","Background color")
	slider(bars,"healthBackgroundOpacity","Background opacity",0,1,.01)
	slider(bars,"healthThickness","Bar thickness",.1,12,.1)
	slider(bars,"healthOffset","Bar offset",0,30,1)
	toggle(bars,"healthText","Health percentage")
	bars:AddParagraph({text="Health reads a usable visible game nametag percentage, not server HP. Hidden, missing or invalid health is omitted. Lowest health excludes unknown values."})
	local tracers=w:NewTab("Tracers","Origins, destinations and line styling")
	local tracerLines=tracers:NewSection("Lines","left")
	dropdown(tracerLines,"tracerOrigin","Origin",{"Bottom","Center","Top","Mouse"})
	dropdown(tracerLines,"tracerTarget","Destination",{"Top","Center","Bottom"})
	toggle(tracerLines,"tracerUseEntityColor","Use team / visibility color")
	color(tracerLines,"tracerColor","Custom line color")
	slider(tracerLines,"tracerOpacity","Line opacity",0,1,.01)
	slider(tracerLines,"tracerThickness","Line thickness",.1,8,.1)
	local tracerBorders=tracers:NewSection("Border","right")
	toggle(tracerBorders,"tracerBorder","Show border")
	color(tracerBorders,"tracerBorderColor","Border color")
	slider(tracerBorders,"tracerBorderOpacity","Border opacity",0,1,.01)
	slider(tracerBorders,"tracerBorderThickness","Border thickness",.1,8,.1)
	local style=w:NewTab("Appearance","Colors and screen elements")
	local colors=style:NewSection("Overlay colors","left")
	for _,entry in ipairs({{"visibleColor","Visible enemy color"},{"blockedColor","Blocked enemy color"},{"unknownColor","Unknown visibility color"},{"enemyColor","Enemy color"},{"allyColor","Ally color"},{"targetColor","Target color"},{"fovColor","FOV / crosshair color"}})do
		local key,title=entry[1],entry[2]
		colors:AddColorPicker({text=title,flag="pf/"..key,default=CFG[key],callback=function(value)changed(key,value)end})
	end
	local screen=style:NewSection("Screen elements","right")
	toggle(screen,"crosshair","Custom crosshair")
	toggle(screen,"showStatus","Runtime status")
	screen:AddLabel({text="Aim state",get=function()return "Aim: "..(APP.stats.aimReason or "Starting")end})
	screen:AddLabel({text="Entities",get=function()return string.format("Enemies %d / allies %d / drawn %d",APP.stats.enemies or 0,APP.stats.allies or 0,APP.stats.drawn or 0)end})
	screen:AddLabel({text="Last error",get=function()return APP.stats.lastError or "No errors" end})
	local utility=w:NewTab("Runtime","Performance, profiles and lifecycle")
	screen:AddLabel({text="Raycast state",get=function()return APP.stats.raycastState or "Waiting for scan"end})
	screen:AddLabel({text="Ray query cost",get=function()return string.format("Ray calls %d / last %.2f ms",APP.stats.rayCalls or 0,APP.stats.rayMs or 0)end})
	screen:AddLabel({text="Visibility counts",get=function()return string.format("Visible %d / Blocked %d / Unknown %d",APP.stats.visibleEnemies or 0,APP.stats.blockedEnemies or 0,APP.stats.visibilityUnknown or 0)end})
	screen:AddParagraph({text="Map-only approximate raycast checks the selected head/torso point. Certified map snapshots remain usable during rebuilding (up to 5 seconds). Aim requires a recent point check; ESP retains confirmed colors briefly. Large maps use a static spatial grid until the map changes or you rebuild it. Initial or invalid geometry stays unknown. Terrain and exact mesh silhouettes are not supported by the external raycast."})
	local performance=utility:NewSection("Performance","full")
	toggle(performance,"lightweight","Lightweight visibility batches")
	performance:AddLabel({text="ESP follows the Jael X overlay refresh rate"})
	slider(performance,"rosterRate","Roster refresh (seconds)",.2,2,.1)
	performance:AddParagraph({text="Rendering follows the app overlay rate with no script FPS cap. One native pose batch feeds all Entity List features. Silhouette applies fill once per character. The registry loop only discovers or removes models."})
	performance:AddButton({text="Rebuild visibility cache",callback=function()
		local root=workspace:FindFirstChild("Map");assert(root,"Map unavailable");root=root:FindFirstChild("MapParts")or root
		prepareRayCache(root,true);Library:Notify("Map cache","Rebuilding map scan; aim waits until complete")
	end})
	performance:AddButton({text="Refresh players now",callback=function()local ok,err=pcall(refreshRoster);if not ok then report(err)else Library:Notify("Roster refreshed",#roster.." character models")end end})
	performance:AddButton({text="Save current settings",callback=function()saveConfig();local ok,err=w:SaveConfig("Last session");assert(ok,err);Library:Notify("Saved","Current settings and JoX profile saved")end})
	performance:AddButton({text="Unload everything",callback=APP.stop})
	performance:AddParagraph({text="RightCtrl: menu. F2: aim. F3: chams. F4 or End: unload. Options autosave; Configs stores named profiles. Unload disconnects every signal and removes all Drawing objects."})
	combat:Select();Library:SetVisible(false)
	Library:Notify("PF JoX","RightCtrl opens settings. Hold your aim key with the menu closed.")
end)
if not okUI then
	APP.menuOpen=false
	if APP.Library then pcall(function()APP.Library:Unload()end);APP.Library=nil end
	warn("[PF_ASSIST] JoX UI unavailable: "..tostring(whyUI)..". Core remains active; F2/F3/F4 work.")
end
print("[PF_ASSIST] JoX hub loaded. RightCtrl menu; F2 aim; F3 chams; F4/End unload.")
while running()do task.wait(.25)end
