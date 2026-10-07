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
	These external volumes have no mesh silhouettes or depth/visibility test.
	Camera.CFrame is read-only here: aim uses bounded relative mouse movement.
	Requires Jael X 1.30 for fractional mouse movement. Menu starts closed.
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
	nameSize = 12, nameDistance = false, nameOutline = true,
	targetMode = "Closest to crosshair", targetPart = "Head", aimKey = "MB2", sticky = false,
	box2d = true, boxStyle = "Corners", tracers = false, tracerOrigin = "Bottom",
	healthBars = true, healthText = false, showAllies = false, visualRange = 2000,
	crosshair = false, targetLine = false, showStatus = true, thickness = 1,
	filledChams = true, fpsCap = 120, rosterRate = 0.4,
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
	local ranges={smoothing={0,100},fov={40,400},maxDistance={10,10000},visualRange={10,10000},opacity={0,1},nameSize={8,24},thickness={1,4},fpsCap={30,240},rosterRate={.2,2}}
	local choices={targetMode={"Closest to crosshair","Closest to player","Lowest health"},targetPart={"Head","Torso"},boxStyle={"Corners","Full box"},tracerOrigin={"Top","Center","Bottom"}}
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
local function removeVisual(v)
	for _, box in ipairs(v.boxes) do pcall(function() box:Remove() end) end
	for _, d in ipairs(v.extra or {}) do pcall(function() d:Remove() end) end
	if v.tag then pcall(function() v.tag:Remove() end) end
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
	for _, d in ipairs(UI.objects) do pcall(function() d:Remove() end) end
	if APP.Library then pcall(function() APP.Library:Unload() end) end
	if ENV.PF_ASSIST == APP then ENV.PF_ASSIST = nil end
	print("[PF_ASSIST] unloaded.")
end
local function hideAll()
	for _, v in pairs(APP.visuals) do
		for _, b in ipairs(v.boxes) do b.Visible = false end
		for _, d in ipairs(v.extra or {}) do d.Visible = false end
		if v.tag then v.tag.Visible = false end
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
	if e.head and e.label and #e.parts >= 5 and #e.parts <= 8 then return e end
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
	for _ = 1, #e.parts do
		local box = Drawing3D.new("Box")
		v.boxes[#v.boxes + 1] = box
		box.Filled = true
		box.Thickness = 1
	end
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
local function activation()
	local key = CFG.aimKey
	if key == "MB1" then return input.is_mouse_down(Enum.KeyCode.LeftButton)
	elseif key == "MB2" then return input.is_mouse_down(Enum.KeyCode.RightButton)
	elseif key == "MB3" then return input.is_mouse_down(Enum.KeyCode.MiddleButton)
	elseif key ~= "None" and Enum.KeyCode[key] then return UIS:IsKeyDown(Enum.KeyCode[key]) end
	return false
end
local function drawLine(d,a,b,color)
	d.From,d.To,d.Color,d.Thickness,d.Visible = a,b,color,CFG.thickness,true
end
local function renderEntity(state, selected, view)
	local e, position, distance = state.e,state.position,state.distance
	local color = selected and CFG.targetColor or state.enemy and CFG.enemyColor or CFG.allyColor
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
			v.tag.Text=name..(CFG.nameDistance and string.format(" [%d studs]",math.floor(distance)) or "")
			v.tag.Position,v.tag.Color,v.tag.Size,v.tag.Outline,v.tag.Visible=Vector2.new(top.X,y-CFG.nameSize-3),color,CFG.nameSize,CFG.nameOutline,true
		end
		if state.hp ~= nil then
			if CFG.healthBars then
				v.healthBg.Position,v.healthBg.Size,v.healthBg.Color,v.healthBg.Visible=Vector2.new(x-7,y),Vector2.new(4,height),Color3.fromRGB(20,20,20),true
				v.healthFill.Position,v.healthFill.Size,v.healthFill.Color,v.healthFill.Visible=Vector2.new(x-6,y+height*(1-state.hp)),Vector2.new(2,height*state.hp),Color3.new(1-state.hp,state.hp,.15),true
			end
			if CFG.healthText then
				v.healthLabel.Text=string.format("%d%%",math.floor(state.hp*100+.5));v.healthLabel.Position=Vector2.new(top.X,y+height+3)
				v.healthLabel.Color,v.healthLabel.Size,v.healthLabel.Visible=color,CFG.nameSize,true
			end
		elseif CFG.healthBars or CFG.healthText then
			-- Unknown health stays visibly distinct instead of displaying a fake 100%.
			if CFG.healthBars then
				v.healthBg.Position,v.healthBg.Size,v.healthBg.Color,v.healthBg.Visible=Vector2.new(x-7,y),Vector2.new(4,height),Color3.fromRGB(95,100,110),true
			end
			v.healthLabel.Text="HP ?";v.healthLabel.Position=Vector2.new(top.X,y+height+3)
			v.healthLabel.Size,v.healthLabel.Color,v.healthLabel.Visible=CFG.nameSize,Color3.fromRGB(180,185,195),true
		end
	end
	if CFG.tracers then
		local start = CFG.tracerOrigin=="Center" and Vector2.new(view.X/2,view.Y/2) or CFG.tracerOrigin=="Top" and Vector2.new(view.X/2,0) or Vector2.new(view.X/2,view.Y)
		drawLine(v.tracer,start,Vector2.new(state.screen.X,state.screen.Y),color)
	end
	if CFG.chams then
		for i,part in ipairs(e.parts) do
			local cf = read(part,"CFrame")
			if cf then
				local box=v.boxes[i];local size=read(part,"Size")
				if not size or size.X<.05 or size.Y<.05 then size=part==e.head and Vector3.new(1.1,1.1,1.1) or part==e.torso and Vector3.new(2,2,1) or Vector3.new(.85,1.8,.85) end
				box.CFrame,box.Size,box.Color,box.Filled,box.Transparency,box.Thickness,box.Visible=cf,size,color,CFG.filledChams,CFG.opacity,CFG.thickness,true
			end
		end
	end
end
local targetLine=Drawing.new("Line");local cross={Drawing.new("Line"),Drawing.new("Line")}
UI.objects={targetLine,cross[1],cross[2]}
local lastFrame=0
local function frame(dt)
	local now=os.clock();if now-lastFrame<1/CFG.fpsCap then return end
	dt=math.min(.05,now-lastFrame);lastFrame=now
	hideAll();targetLine.Visible=false;for _,d in ipairs(cross) do d.Visible=false end
	APP.menuOpen=APP.Library and APP.Library.Visible and APP.window and APP.window.visible or false
	APP.stats.enemies,APP.stats.allies,APP.stats.unknown,APP.stats.target=0,0,0,nil
	APP.stats.healthKnown,APP.stats.healthUnknown=0,0
	local camera=workspace.CurrentCamera;local cf=read(camera,"CFrame");local view=Drawing3D.GetViewportSize()
	if not cf or view.X<1 or view.Y<1 then ring.Visible=false;return end
	local center=Vector2.new(view.X/2,view.Y/2)
	ring.Position,ring.Radius,ring.Color,ring.Visible=center,CFG.fov,CFG.fovColor,CFG.showFov and CFG.aim
	if CFG.crosshair then drawLine(cross[1],center-Vector2.new(5,0),center+Vector2.new(5,0),CFG.fovColor);drawLine(cross[2],center-Vector2.new(0,5),center+Vector2.new(0,5),CFG.fovColor) end
	local best,score,states=nil,math.huge,{}
	local held=activation();if not held then APP.lock=nil end
	for _,e in ipairs(roster) do
		local ok,err=pcall(function()
			local enemy=classify(e);if enemy==nil then APP.stats.unknown=APP.stats.unknown+1;return end
			if enemy then APP.stats.enemies=APP.stats.enemies+1 else APP.stats.allies=APP.stats.allies+1 end
			local hp=health(e)
			if hp==nil then APP.stats.healthUnknown=APP.stats.healthUnknown+1 else APP.stats.healthKnown=APP.stats.healthKnown+1 end
			if not alive(e,hp) then return end
			local head=read(e.head,"Position");if not head then return end
			local distance=(head-cf.Position).Magnitude;if distance<4 then return end
			local screen,on=Drawing3D.WorldToViewportPoint(head);if not on or screen.Z<=0 then return end
			local state={e=e,enemy=enemy,position=head,distance=distance,screen=screen,hp=hp}
			if distance<=CFG.visualRange and (enemy or CFG.showAllies) then states[#states+1]=state end
			if CFG.teamCheck and not enemy or distance>CFG.maxDistance then return end
			local aimPosition=CFG.targetPart=="Torso" and read(e.torso,"Position") or head
			if not aimPosition then return end
			local aimScreen,visible=Drawing3D.WorldToViewportPoint(aimPosition);if not visible then return end
			local delta=(Vector2.new(aimScreen.X,aimScreen.Y)-center).Magnitude;if delta>CFG.fov then return end
			local priority=delta
			if CFG.targetMode=="Closest to player" then priority=distance elseif CFG.targetMode=="Lowest health" then priority=state.hp end
			if priority==nil then return end
			if CFG.sticky and held and APP.lock==e.key then priority=-1 end
			if priority<score then score=priority;best={e=e,point=aimScreen} end
		end)
		if not ok then report(err) end
	end
	for _,state in ipairs(states) do local ok,err=pcall(renderEntity,state,best and best.e.key==state.e.key,view);if not ok then report(err) end end
	local enabled=true;if input.get_status then local ok,info=pcall(input.get_status);if ok then enabled=info.enabled end end
	local reason=not CFG.aim and "Disabled" or APP.menuOpen and "Menu open" or not input.is_window_focused() and "Game unfocused" or not enabled and "Input disabled" or not held and "Hold aim key" or not best and "No target in FOV / range" or "Tracking"
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
	status.Text=string.format("PF JoX | %s | Enemies %d | Drawn %d | %s",reason,APP.stats.enemies,#states,APP.stats.target or "No target")
	status.Visible=CFG.showStatus
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
	slider(detail,"opacity","Chams opacity",0,1,.01)
	toggle(detail,"tracers","Player tracers")
	dropdown(detail,"tracerOrigin","Tracer origin",{"Bottom","Center","Top"})
	slider(detail,"thickness","Line thickness",1,4,.5)
	slider(detail,"nameSize","ESP text size",8,24,1)
	toggle(detail,"nameOutline","Text outline")
	detail:AddParagraph({text="2D bounds and chams approximate the R6 body. Health reads the visible game nametag, not server health. Hidden or unavailable health appears gray with HP ?. Lowest health skips unknown values."})
	local style=w:NewTab("Appearance","Colors and screen elements")
	local colors=style:NewSection("Overlay colors","left")
	for _,entry in ipairs({{"enemyColor","Enemy color"},{"allyColor","Ally color"},{"targetColor","Target color"},{"fovColor","FOV / crosshair color"}})do
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
	local performance=utility:NewSection("Performance","full")
	slider(performance,"fpsCap","Overlay update limit",30,240,1)
	slider(performance,"rosterRate","Roster refresh (seconds)",.2,2,.1)
	performance:AddParagraph({text="The update limit cannot exceed the app's overlay rate. Positions are read in PreRender; the slower registry loop only discovers or removes character models."})
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
