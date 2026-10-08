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
	Requires Jael X 1.31.2 raycast APIs and fractional mouse movement. Menu starts closed.
	Status reports distance/FOV/input blockers; RightCtrl opens settings.
	Name ESP reads ContentText: confirmed readable on Jael X 1.30 while Text
	fails with "Unsupported string layout" for these PlayerTag labels.
	Health follows visible PlayerTag.Health.Percent; hidden templates are not HP.
	Gray bars marked HP ? mean the client has not exposed a usable health value.
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
	filledChams = true, chamsMode = "Body bounds", rosterRate = 0.4,
	fovColor = Color3.fromRGB(160, 110, 255),
	fov = 160, smoothing = 6, maxDistance = 2000, opacity = 0.18,
	enemyColor = Color3.fromRGB(255, 70, 90),
	targetColor = Color3.fromRGB(255, 200, 65),
	allyColor = Color3.fromRGB(30, 230, 200),
}
APP.config = CFG
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
	local values=HTTP:JSONDecode(raw);values.smoothing=values.smoothing or values.smooth
	local ranges={smoothing={0,100},fov={40,400},maxDistance={10,10000},visualRange={10,10000},opacity={0,1},nameSize={8,24},thickness={1,4},rosterRate={.2,2}}
	local choices={chamsMode={"Body bounds","Body parts"},targetMode={"Closest to crosshair","Closest to player","Lowest health"},targetPart={"Head","Torso"},boxStyle={"Corners","Full box"},tracerOrigin={"Top","Center","Bottom"}}
	for key,value in pairs(values) do
		if type(CFG[key])=="boolean" and type(value)=="boolean" then CFG[key]=value
		elseif ranges[key] and type(value)=="number" and value==value then CFG[key]=math.clamp(value,ranges[key][1],ranges[key][2])
		elseif choices[key] then for _,choice in ipairs(choices[key])do if value==choice then CFG[key]=value end end
		elseif key=="aimKey" and type(value)=="string" and (value:match("^MB[123]$") or Enum.KeyCode[value]) then CFG[key]=value
		elseif typeof(CFG[key])=="Color3" and type(value)=="table" and #value==3 then
			if type(value[1])=="number" and type(value[2])=="number" and type(value[3])=="number" then CFG[key]=Color3.fromRGB(math.clamp(value[1],0,255),math.clamp(value[2],0,255),math.clamp(value[3],0,255)) end
		end
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
	for _, box in ipairs(v.boxes) do pcall(function() hide(box);box:Remove() end) end
	for _, d in ipairs(v.extra or {}) do pcall(function() hide(d);d:Remove() end) end
	if v.tag then pcall(function() hide(v.tag);v.tag:Remove() end) end
end
function APP.stop()
	if not APP.alive then return end
	APP.alive = false
	for _, c in ipairs(APP.connections) do pcall(function() c:Disconnect() end) end
	for _, v in pairs(APP.visuals) do removeVisual(v) end
	APP.visuals = {}
	if ring then pcall(function() ring:Remove() end) end
	if status then pcall(function() status:Remove() end) end
	saveConfig()
	for _, d in ipairs(UI.objects) do pcall(function() hide(d);d:Remove() end) end
	if APP.Library then pcall(function() APP.Library:Unload() end) end
	if ENV.PF_ASSIST == APP then ENV.PF_ASSIST = nil end
	print("[PF_ASSIST] unloaded.")
end
local function hideAll()
	for _, v in pairs(APP.visuals) do
		for _, b in ipairs(v.boxes) do hide(b) end
		for _, d in ipairs(v.extra or {}) do hide(d) end
		if v.tag then hide(v.tag) end
	end
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
local function visual(e)
	local v = APP.visuals[e.key]
	if v then v.entity=e;return v end
	v = { entity = e, boxes = {} }
	APP.visuals[e.key] = v
	v.tag = Drawing.new("Text")
	v.tag.Size, v.tag.Center, v.tag.Outline = CFG.nameSize, true, CFG.nameOutline
	return v
end

--=========================== EXTENDED DRAWING ==========================--
local function drawable(v, kind)
	local d = Drawing.new(kind);v.extra = v.extra or {};v.extra[#v.extra + 1] = d
	return d
end
local function extended(e)
	local v = visual(e)
	if not v.lines then
		v.lines = {};for i = 1, 8 do v.lines[i] = drawable(v, "Line") end
		v.tracer = drawable(v,"Line")
		v.healthBg = drawable(v,"Square");v.healthBg.Filled = true
		v.healthFill = drawable(v,"Square");v.healthFill.Filled = true
		v.healthLabel = drawable(v,"Text");v.healthLabel.Center = true;v.healthLabel.Outline = true
	end
	return v
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
local function renderEntity(state, selected, view)
	local e, position, distance = state.e,state.position,state.distance
	local color = visibilityColor(state,selected)
	local v = extended(e)
	local top, topOn = Drawing3D.WorldToViewportPoint(position+Vector3.new(0,1.2,0))
	local bottom, bottomOn = Drawing3D.WorldToViewportPoint(position-Vector3.new(0,4.5,0))
	-- These bounds approximate the measured R6 body; they are not mesh silhouettes.
	local height = bottom.Y-top.Y
	if top.Z>0 and bottom.Z>0 and height>1 then
		local width = height*.55;local x,y = top.X-width/2,top.Y
		if CFG.box2d then
			local tl,tr,br,bl=Vector2.new(x,y),Vector2.new(x+width,y),Vector2.new(x+width,y+height),Vector2.new(x,y+height)
			local segments
			if CFG.boxStyle == "Full box" then segments={{tl,tr},{tr,br},{br,bl},{bl,tl}}
			else
				local a,b=width*.25,height*.2
				segments={{tl,tl+Vector2.new(a,0)},{tl,tl+Vector2.new(0,b)},{tr,tr-Vector2.new(a,0)},{tr,tr+Vector2.new(0,b)},
					{br,br-Vector2.new(a,0)},{br,br-Vector2.new(0,b)},{bl,bl+Vector2.new(a,0)},{bl,bl-Vector2.new(0,b)}}
			end
			for i,segment in ipairs(segments) do drawLine(v.lines[i],segment[1],segment[2],color) end
		end
		if CFG.nametags or CFG.nameDistance then
			local name=CFG.nametags and (e.name or (state.enemy and "Enemy" or "Ally")) or ""
			local text=name..(CFG.nameDistance and string.format(" [%d studs]",math.floor(distance)) or "")
			if v.tag.Text~=text then v.tag.Text=text end
			v.tag.Position=Vector2.new(top.X,y-CFG.nameSize-3)
			if v.tag.Color~=color then v.tag.Color=color end
			if v.tag.Size~=CFG.nameSize then v.tag.Size=CFG.nameSize end
			if v.tag.Outline~=CFG.nameOutline then v.tag.Outline=CFG.nameOutline end
			show(v.tag)
		end
		if state.hp ~= nil then
			if CFG.healthBars then
				v.healthBg.Position,v.healthBg.Size,v.healthBg.Color=Vector2.new(x-7,y),Vector2.new(4,height),Color3.fromRGB(20,20,20);show(v.healthBg)
				v.healthFill.Position,v.healthFill.Size,v.healthFill.Color=Vector2.new(x-6,y+height*(1-state.hp)),Vector2.new(2,height*state.hp),Color3.new(1-state.hp,state.hp,.15);show(v.healthFill)
			end
			if CFG.healthText then
				v.healthLabel.Text=string.format("%d%%",math.floor(state.hp*100+.5));v.healthLabel.Position=Vector2.new(top.X,y+height+3)
				v.healthLabel.Color,v.healthLabel.Size=color,CFG.nameSize;show(v.healthLabel)
			end
		elseif CFG.healthBars or CFG.healthText then
			-- Unknown health stays visibly distinct instead of displaying a fake 100%.
			if CFG.healthBars then
				v.healthBg.Position,v.healthBg.Size,v.healthBg.Color=Vector2.new(x-7,y),Vector2.new(4,height),Color3.fromRGB(95,100,110);show(v.healthBg)
			end
			v.healthLabel.Text="HP ?";v.healthLabel.Position=Vector2.new(top.X,y+height+3)
			v.healthLabel.Size,v.healthLabel.Color=CFG.nameSize,Color3.fromRGB(180,185,195);show(v.healthLabel)
		end
	end
	if CFG.tracers then
		local start = CFG.tracerOrigin=="Center" and Vector2.new(view.X/2,view.Y/2) or CFG.tracerOrigin=="Top" and Vector2.new(view.X/2,0) or Vector2.new(view.X/2,view.Y)
		drawLine(v.tracer,start,Vector2.new(state.screen.X,state.screen.Y),color)
	end
	if CFG.chams then
		local function updateBox(index,cf,size)
			local box=v.boxes[index]
			if not box then box=Drawing3D.new("Box");v.boxes[index]=box end
			box.CFrame=cf
			if box.Size~=size then box.Size=size end
			if box.Color~=color then box.Color=color end
			if box.Filled~=CFG.filledChams then box.Filled=CFG.filledChams end
			if box.Transparency~=CFG.opacity then box.Transparency=CFG.opacity end
			if box.Thickness~=CFG.thickness then box.Thickness=CFG.thickness end
			show(box)
		end
		if CFG.chamsMode=="Body bounds" then
			-- One body volume avoids six pose reads and six box submissions per frame.
			local cf=read(e.torso or e.head,"CFrame")
			if cf then
				if not e.torso then cf=cf*CFrame.new(0,-2,0)end
				updateBox(1,cf,Vector3.new(3.7,5.5,1.5))
			end
		else
			for i,part in ipairs(e.parts)do
				local cf=read(part,"CFrame")
				if cf then updateBox(i,cf,e.sizes[part])end
			end
		end
	end
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
			local head=read(e.head,"Position");if not head then return end
			local distance=(head-cf.Position).Magnitude;if distance<4 then return end
			local screen,on=Drawing3D.WorldToViewportPoint(head);if not on or screen.Z<=0 then return end
			local aimPosition=CFG.targetPart=="Torso" and read(e.torso,"Position") or head
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
	visibilityRequests=requests;APP.visibilityPriority=held and aimRequest or nil
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
ring=Drawing.new("Circle");ring.NumSides=64;ring.Thickness=1
status=Drawing.new("Text");status.Position=Vector2.new(20,12);status.Size=14;status.Color=Color3.fromRGB(235,235,245);status.Outline=true
APP.connections[#APP.connections+1]=UIS.InputBegan:Connect(function(event)
	if not running() then return end
	local key=event.KeyCode.Name
	if key=="F4" or key=="End" then APP.stop()
	elseif key=="F2" then CFG.aim=not CFG.aim;if APP.aimControl then APP.aimControl:Set(CFG.aim,true) end
	elseif key=="F3" then CFG.chams=not CFG.chams;if APP.chamsControl then APP.chamsControl:Set(CFG.chams,true) end end
end)
-- One bounded ray query per worker interval, independent of overlay FPS.
-- Alternate aim-priority samples with round-robin ESP to prevent starvation.
 task.spawn(function()
	local cursor,turn,nextPrune=0,0,0
	while running()do
		if os.clock()>=nextPrune then
			nextPrune=os.clock()+2
			APP.stats.luaMemoryMB=collectgarbage("count")/1024
			for key in pairs(visibilityEntries)do if not read(key,"Parent")then visibilityEntries[key]=nil end end
		end
		local requests=visibilityRequests
		if (CFG.wallCheck or CFG.visibilityColors)and #requests>0 then
			cursor=cursor%#requests+1;turn=turn+1
			local request=turn%2==0 and APP.visibilityPriority or requests[cursor]
			local ok,err=pcall(sampleVisibility,request or requests[cursor])
			if not ok then report(err)end
		end
		task.wait(CFG.lightweight and .04 or .025)
	end
 end)
task.spawn(function()while running() do local ok,err=pcall(refreshRoster);if not ok then roster={};report(err) end;task.wait(CFG.rosterRate) end end)
APP.connections[#APP.connections+1]=RS.PreRender:Connect(function(dt)if running() then local ok,err=pcall(frame,dt);if not ok then hideAll();report(err) end end end)
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
	local w=Library:NewWindow({title="Phantom Forces",subtitle="JOX / EXTERNAL AIM & ESP",configId="PFJoX",width=900,height=640})
	APP.window=w;APP.controls={}
	local function changed(key,value) CFG[key]=value;saveConfig() end
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
	local visuals=w:NewTab("ESP","Player information and overlays")
	local players=visuals:NewSection("Player overlay","left")
	toggle(players,"box2d","2D boxes")
	dropdown(players,"boxStyle","Box style",{"Corners","Full box"})
	toggle(players,"nametags","Player names")
	toggle(players,"nameDistance","Distance labels")
	toggle(players,"healthBars","Health bars")
	toggle(players,"healthText","Health percentage")
	toggle(players,"showAllies","Show allies")
	slider(players,"visualRange","ESP range (studs)",10,10000,10)
	local detail=visuals:NewSection("Chams & tracers","right")
	APP.chamsControl=toggle(detail,"chams","Body chams")
	toggle(detail,"filledChams","Filled chams")
	dropdown(detail,"chamsMode","Chams detail",{"Body bounds","Body parts"})
	toggle(detail,"visibilityColors","Separate visible / blocked ESP colors")
	slider(detail,"opacity","Chams opacity",0,1,.01)
	toggle(detail,"tracers","Player tracers")
	dropdown(detail,"tracerOrigin","Tracer origin",{"Bottom","Center","Top"})
	slider(detail,"thickness","Line thickness",1,4,.5)
	slider(detail,"nameSize","ESP text size",8,24,1)
	toggle(detail,"nameOutline","Text outline")
	detail:AddParagraph({text="2D bounds and chams approximate the R6 body. Health reads the visible game nametag, not server health. Hidden or unavailable health appears gray with HP ?. Lowest health skips unknown values."})
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
	toggle(performance,"lightweight","Lightweight ray updates (max 25 per second)")
	performance:AddLabel({text="ESP follows the Jael X overlay refresh rate"})
	slider(performance,"rosterRate","Roster refresh (seconds)",.2,2,.1)
	performance:AddParagraph({text="Rendering follows the app overlay rate with no script FPS cap. Body bounds uses one chams volume; Body parts preserves individual limbs. The slower registry loop only discovers or removes character models."})
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
