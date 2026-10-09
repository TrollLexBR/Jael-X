--[[
	PF_SLEEVE_TEST — isolated sleeve Color diagnostic.
	Place: Phantom Forces. F4: restore and stop.
	Console: shared.PF_SLEEVE_TEST.stop()
	One direct Sleeves mesh only; no Material, transforms, joints or texture writes.
	Prior sleeve experimentation preceded a rig regression; not a verified visual fix.
	Jael X 1.31.26 rejects camera appearance writes. Do not bypass that capability.
]]
local CFG={SleeveIndex=1,Seconds=20,Property="Color",Value=Color3.fromRGB(255,60,180)}
local ENV=shared
if ENV.PF_SLEEVE_TEST and ENV.PF_SLEEVE_TEST.stop then
	local ok,result=pcall(ENV.PF_SLEEVE_TEST.stop)
	if not ok or result==false then warn("[PF_SLEEVE_TEST] Previous restoration failed; test cancelled.");return end
end
local APP={alive=true,connections={}}
ENV.PF_SLEEVE_TEST=APP
local part,parent,original,applied
local function read(object,key)
	local ok,value=pcall(function()return object[key]end)
	return ok and value or nil
end
local function equal(a,b)
	if typeof(a)=="Color3" and typeof(b)=="Color3"then
		return math.abs(a.R-b.R)<.005 and math.abs(a.G-b.G)<.005 and math.abs(a.B-b.B)<.005
	end
	return tostring(a)==tostring(b)
end
function APP.stop()
	APP.alive=false
	for _,connection in ipairs(APP.connections)do pcall(function()connection:Disconnect()end)end
	APP.connections={}
	if part and applied and read(part,"Parent")==parent and read(part,"Name")=="Sleeves" and read(part,"ClassName")=="MeshPart" and equal(read(part,CFG.Property),CFG.Value)then
		local ok,err=pcall(function()part[CFG.Property]=original end)
		if not ok then warn("[PF_SLEEVE_TEST] Restore failed: "..tostring(err));return false end
		print("[PF_SLEEVE_TEST] Original "..CFG.Property.." restored.")
	end
	applied=false
	if ENV.PF_SLEEVE_TEST==APP then ENV.PF_SLEEVE_TEST=nil end
	return true
end
local ok,err=pcall(function()
	local camera=workspace.CurrentCamera
	local sleeves={}
	for _,model in ipairs(camera:GetChildren())do
		if model.ClassName=="Model"then
			local arm=model:FindFirstChild("Arm")
			if arm and arm.ClassName=="Part"then
				local sleeve=model:FindFirstChild("Sleeves")
				if sleeve and sleeve.ClassName=="MeshPart"then sleeves[#sleeves+1]=sleeve end
			end
		end
	end
	part=assert(sleeves[CFG.SleeveIndex],"Requested sleeve is unavailable")
	assert(part:CanWriteProperty(CFG.Property),"Native capability rejects sleeve "..CFG.Property)
	parent,original=part.Parent,part[CFG.Property]
	APP.connections[1]=game:GetService("UserInputService").InputBegan:Connect(function(event)
		if event.KeyCode.Name=="F4"then APP.stop()end
	end)
	-- Capture ownership before assignment so a partial setter failure can restore.
	applied=true
	part[CFG.Property]=CFG.Value
	print("[PF_SLEEVE_TEST] "..CFG.Property.." value applied to one sleeve; check visually. Automatic restore in "..CFG.Seconds.." seconds.")
	local elapsed=0
	while APP.alive and ENV.PF_SLEEVE_TEST==APP and elapsed<CFG.Seconds do
		task.wait(.1);elapsed=elapsed+.1
		if read(part,"Parent")~=parent then break end
	end
end)
if not ok then warn("[PF_SLEEVE_TEST] "..tostring(err))end
APP.stop()
