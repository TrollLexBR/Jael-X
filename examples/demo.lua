--[[
	JoX Library — component gallery (no gameplay changes).
	RightControl: show/hide. End: unload this demo and its library.
	Loads the published JoX Library from GitHub.
]]
if shared.JaelUIDemo and shared.JaelUIDemo.stop then pcall(shared.JaelUIDemo.stop) end
local APP={alive=true,connections={}}
shared.JaelUIDemo=APP
local ok,Library=pcall(function()
	local source=game:HttpGet("https://raw.githubusercontent.com/TrollLexBR/Jael-X/main/JoX-Library.lua")
	local fn,err=loadstring(source,"@jael-drawing-library.lua");assert(fn,err);return fn()
end)
if not ok then warn("[JOX_DEMO] Library load failed: "..tostring(Library));shared.JaelUIDemo=nil;return end
local window=Library:NewWindow({title="JoX Library",subtitle="DRAWING UI / COMPONENT GALLERY",configId="JaelDrawingDemo",width=900,height=640})
local combat=window:NewTab("Combat","Aim and targeting")
local aim=combat:NewSection("Aim settings","left")
aim:AddToggle({text="Enable aim",flag="aim/enabled",default=false,tooltip="This gallery changes interface state only."})
aim:AddDropdown({text="Target priority",flag="aim/priority",options={"Closest to crosshair","Closest to player","Lowest health"}})
aim:AddSlider({text="Smooth",flag="aim/smooth",min=0,max=100,step=.5,default=6,tooltip="Drag, scroll over the slider, or click its numeric value."})
aim:AddSlider({text="FOV radius",flag="aim/fov",min=20,max=400,step=1,default=160})
aim:AddKeybind({text="Aim activation",flag="aim/key",default="MB2",mode="Hold"})
aim:AddToggle({text="Team check",flag="aim/team",default=true})
aim:AddMultiSelect({text="Target parts",flag="aim/parts",options={"Head","Torso","Arms","Legs"},default={"Head","Torso"}})
local behavior=combat:NewSection("Behavior","right")
behavior:AddToggle({text="Show FOV",flag="aim/showFov",default=true})
behavior:AddColorPicker({text="FOV color",flag="aim/color",default={151,105,255}})
behavior:AddInput({text="Profile label",flag="aim/profile",default="Default profile",placeholder="Type a label"})
behavior:AddInput({text="Maximum range",flag="aim/range",numeric=true,min=10,max=10000,default=2000})
behavior:AddButton({text="Show notification",callback=function()Library:Notify("JoX Library","Every setting has its own flag and callback.")end})
behavior:AddProgress({text="Example progress",default=.68})
behavior:AddParagraph({text="The interface is rendered outside Roblox. Configs, clipboard, keybinds and scroll work through Jael X. No game features run in this demo."})
local visuals=window:NewTab("Visuals","ESP and appearance")
local esp=visuals:NewSection("Player overlay","left")
esp:AddToggle({text="Name ESP",flag="visual/names",default=true})
esp:AddSlider({text="Text size",flag="visual/size",min=8,max=24,step=1,default=12})
esp:AddToggle({text="Show distance",flag="visual/distance",default=false})
esp:AddToggle({text="Text outline",flag="visual/outline",default=true})
esp:AddColorPicker({text="Enemy color",flag="visual/enemy",default={255,82,108}})
local details=visuals:NewSection("Details","right")
details:AddDropdown({text="Box style",flag="visual/style",options={"Corners","Full box","Body volumes"}})
details:AddSlider({text="Opacity",flag="visual/opacity",min=0,max=100,step=1,default=30})
details:AddMultiSelect({text="Extra information",flag="visual/details",options={"Health","Weapon","Team","Distance"},default={"Health"}})
details:AddLabel({text="Dynamic status",get=function()return "Library "..Library.Version.." / ready" end})
details:AddDivider({})
details:AddButton({text="Disabled action",disabled=true})
local utility=window:NewTab("Utilities","Reusable interface features")
local actions=utility:NewSection("Quick actions","full")
actions:AddParagraph({text="Window dragging and resize grip; separate column scroll; collapsible sections; editable numeric sliders; popups that stay above the page; config import/export; multiple independent windows."})
actions:AddButton({text="Open a second window",callback=function()
	local other=Library:NewWindow({title="Quick settings",subtitle="Another window",configId="JaelQuickSettings",configs=false,x=200,y=130,width=650,height=420})
	local section=other:NewTab("Controls","Independent window"):NewSection("Settings","full")
	section:AddSlider({text="Value",min=0,max=10,step=.1,default=5})
	section:AddButton({text="Close this window",callback=function()other:Remove()end})
end})
function APP.stop()
	if not APP.alive then return end;APP.alive=false
	for _,c in ipairs(APP.connections) do pcall(function()c:Disconnect()end) end
	Library:Unload();if shared.JaelUIDemo==APP then shared.JaelUIDemo=nil end
end
APP.connections[#APP.connections+1]=game:GetService("UserInputService").InputBegan:Connect(function(e)
	if e.KeyCode==Enum.KeyCode.End then APP.stop() end
end)
combat:Select()
Library:Notify("JoX Library","RightCtrl toggles the menu. Configs is always the last tab.")
print("[JOX_DEMO] loaded. RightCtrl toggles, End unloads.")
while APP.alive and shared.JaelUIDemo==APP do task.wait(.25) end
