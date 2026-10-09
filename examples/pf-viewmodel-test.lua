--[[
	PF_VIEWMODEL_TEST — local arms and equipped item appearance test.
	F4: restore and unload. shared.PF_VIEWMODEL_TEST.stop(): restore and unload.
	Texture removal is unavailable in the current Jael API. Color/Material only.
]]
local ENV=shared
if ENV.PF_VIEWMODEL_TEST and ENV.PF_VIEWMODEL_TEST.stop then pcall(ENV.PF_VIEWMODEL_TEST.stop);task.wait(.15)end
local APP={alive=true,stats={},connections={}}
ENV.PF_VIEWMODEL_TEST=APP
local CFG={fullBright=true,environmentEnabled=true,environmentRed=255,environmentGreen=80,environmentBlue=180,sleevesEnabled=false,sleevesRed=255,sleevesGreen=80,sleevesBlue=180,armsEnabled=false,armsRed=255,armsGreen=60,armsBlue=180,armsMaterial="Neon",weaponEnabled=false,weaponRed=80,weaponGreen=200,weaponBlue=255,weaponMaterial="Neon"}
local function running()return APP.alive and ENV.PF_VIEWMODEL_TEST==APP end
local function read(o,k)if o==nil then return nil end;local ok,v=pcall(function()return o[k]end);return ok and v or nil end
local function children(o)if o==nil then return {}end;local ok,v=pcall(function()return o:GetChildren()end);return ok and v or {}end
local function report(err)warn("[PF_VIEWMODEL_TEST] "..tostring(err))end
local restoreViewmodel=function()end
local restoreEnvironment=function()end
APP.config=CFG
--=========================== LOCAL VIEWMODEL ==========================--
-- Camera children are used instead of obfuscated model names. Arm models have
-- a direct BasePart named Arm; the current weapon is the unique other mesh model.
local viewmodelAppearanceReady=true
local viewmodelSnapshots={}
local function sameAppearance(a,b)
	if typeof(a)=="Color3" and typeof(b)=="Color3" then
		return math.abs(a.R-b.R)<.5/255+.00001 and math.abs(a.G-b.G)<.5/255+.00001 and math.abs(a.B-b.B)<.5/255+.00001
	end
	return tostring(a)==tostring(b)
end
local function restoreViewProperty(part,record,key)
	local state=record[key]
	if not state then return end
	if read(part,"Parent")==record.parent and sameAppearance(read(part,key),state.last) then
		local ok,err=pcall(function()part[key]=state.original end)
		if not ok then report("Viewmodel restore: "..tostring(err)) end
	end
	record[key]=nil
end
restoreViewmodel=function()
	for part,record in pairs(viewmodelSnapshots) do
		for _,key in ipairs({"Color","Material"})do restoreViewProperty(part,record,key)end
	end
	viewmodelSnapshots={}
end
local function setViewProperty(part,record,key,value)
	if value==nil then restoreViewProperty(part,record,key);return end
	local state=record[key]
	if state and sameAppearance(state.desired,value) then return end
	if record.retry and os.clock()<record.retry then return end
	local current=read(part,key)
	if current==nil then return end
	local ok,err=pcall(function()
		assert(part:CanWriteProperty(key),"Current renderer does not support "..key)
		part[key]=value
	end)
	if not ok then record.retry=os.clock()+2;APP.stats[record.errorScope or "viewmodelError"]=tostring(err);return end
	state=state or {original=current}
	state.desired=value;state.last=value;record[key]=state
end
local function collectViewParts(model)
	local parts,stack,visited={},{{model,0}},0
	while #stack>0 and #parts<256 and visited<512 do
		visited=visited+1
		local next=table.remove(stack)
		for _,child in ipairs(children(next[1]))do
			local ok,part=pcall(function()return child:IsA("BasePart")end)
			if ok and part then parts[#parts+1]=child
			elseif next[2]<6 then stack[#stack+1]={child,next[2]+1}end
		end
	end
	return parts
end
local function refreshViewmodel()
	-- Only the restricted hand/equipped-item path is enabled. Native capability
	-- checks still reject unsupported pieces and builds, including the 1.31.26 guard.
	if not viewmodelAppearanceReady then restoreViewmodel();APP.stats.viewmodelParts=0;APP.stats.viewmodelError="Viewmodel customization is temporarily disabled after an animation regression";return end
	if not CFG.armsEnabled and not CFG.sleevesEnabled and not CFG.weaponEnabled then restoreViewmodel();APP.stats.viewmodelParts=0;return end
	local camera=read(workspace,"CurrentCamera")
	local arms,weapons={},{}
	for _,model in ipairs(children(camera))do
		if read(model,"ClassName")=="Model"then
			local arm,parts=false,0
			for _,part in ipairs(children(model))do
				if read(part,"Name")=="Arm" and read(part,"ClassName")=="Part"then arm=true end
				local ok,isPart=pcall(function()return part:IsA("BasePart")end)
				if ok and isPart then parts=parts+1 end
			end
			if arm then arms[#arms+1]=model elseif parts>0 then weapons[#weapons+1]=model end
		end
	end
	local active={}
	APP.stats.viewmodelError=nil
	local function apply(model,prefix)
		local color=Color3.fromRGB(CFG[prefix.."Red"],CFG[prefix.."Green"],CFG[prefix.."Blue"])
		local selected=CFG[prefix.."Material"]
		local material=selected~="Original" and Enum.Material[selected] or nil
		for _,part in ipairs(collectViewParts(model))do
			local sleeve=prefix=="arms" and read(part,"Name")=="Sleeves"
			-- SkinTone is the independently tested hand mesh. Leave the sleeve,
			-- invisible Arm anchor and unidentified glove/accessory meshes alone.
			local allowed=not sleeve and (prefix~="arms" or read(part,"Name")=="SkinTone")
			if allowed and CFG[prefix.."Enabled"]then
			active[part]=true
			local parent=read(part,"Parent")
			local record=viewmodelSnapshots[part]
			if not record or record.parent~=parent then record={parent=parent};viewmodelSnapshots[part]=record end
			setViewProperty(part,record,"Color",color);setViewProperty(part,record,"Material",material)
			end
		end
	end
	if CFG.armsEnabled or CFG.sleevesEnabled then for _,model in ipairs(arms)do apply(model,"arms")end end
	-- Ambiguous camera models remain untouched rather than recoloring effects.
	if CFG.weaponEnabled and #arms>0 and #weapons==1 then apply(weapons[1],"weapon")
	elseif CFG.weaponEnabled then APP.stats.viewmodelError="Equipped item is unavailable or ambiguous"end
	local count=0
	for part,record in pairs(viewmodelSnapshots)do
		if active[part]then count=count+1 else
			for _,key in ipairs({"Color","Material"})do restoreViewProperty(part,record,key)end
			viewmodelSnapshots[part]=nil
		end
	end
	APP.stats.viewmodelParts=count
end
local environmentOwner,environmentRecord=nil,nil
local environmentKeys={"Ambient","OutdoorAmbient","Brightness","GlobalShadows"}
restoreEnvironment=function()
	if environmentOwner and environmentRecord then
		for _,key in ipairs(environmentKeys)do restoreViewProperty(environmentOwner,environmentRecord,key)end
	end
	environmentOwner,environmentRecord=nil,nil
end
local function refreshEnvironment()
	if not CFG.fullBright and not CFG.environmentEnabled then restoreEnvironment();return end
	local lighting=game:GetService("Lighting")
	if lighting~=environmentOwner then restoreEnvironment();environmentOwner=lighting;environmentRecord={parent=read(lighting,"Parent"),errorScope="environmentError"}end
	APP.stats.environmentError=nil
	-- Custom tint takes precedence over the white full-bright ambient.
	local tint=CFG.environmentEnabled and Color3.fromRGB(CFG.environmentRed,CFG.environmentGreen,CFG.environmentBlue)or Color3.new(1,1,1)
	setViewProperty(lighting,environmentRecord,"Ambient",tint)
	setViewProperty(lighting,environmentRecord,"OutdoorAmbient",tint)
	setViewProperty(lighting,environmentRecord,"Brightness",CFG.fullBright and 3 or nil)
	local shadows=nil;if CFG.fullBright then shadows=false end
	setViewProperty(lighting,environmentRecord,"GlobalShadows",shadows)
end
APP.refreshEnvironment=refreshEnvironment
APP.restoreEnvironment=restoreEnvironment
 task.spawn(function()
	while running()do local ok,err=pcall(refreshEnvironment);if not ok then APP.stats.environmentError=tostring(err)end;task.wait(.5)end
 end)
APP.refreshViewmodel=refreshViewmodel
APP.restoreViewmodel=restoreViewmodel
 task.spawn(function()
	while running()do local ok,err=pcall(refreshViewmodel);if not ok then APP.stats.viewmodelError=tostring(err)end;task.wait(.5)end
 end)


function APP.stop()
	if not APP.alive then return end
	APP.alive=false;restoreViewmodel();restoreEnvironment()
	for _,connection in ipairs(APP.connections)do pcall(function()connection:Disconnect()end)end
	if ENV.PF_VIEWMODEL_TEST==APP then ENV.PF_VIEWMODEL_TEST=nil end
	print("[PF_VIEWMODEL_TEST] restored and unloaded.")
end
APP.connections[1]=game:GetService("UserInputService").InputBegan:Connect(function(event)if event.KeyCode.Name=="F4"then APP.stop()end end)
print("[PF_VIEWMODEL_TEST] Full bright + pink ambient by default. Optional hand/equipped-item appearance uses native capabilities; sleeves excluded. F4 restores and unloads.")
local lastReport=nil
while running()do
	local message=APP.stats.environmentError or APP.stats.viewmodelError
	if message and message~=lastReport then
		lastReport=message
		print("[PF_VIEWMODEL_TEST] "..message)
	end
	task.wait(.5)
end
