--[[
	JoX Library — standalone interface library for Jael X (Lua 5.4).
	External Drawing primitives only; no Roblox instances or gameplay writes.
	RightControl toggles all windows. Call Library:Unload() to disconnect signals.
	See README.md and demo.lua for the public API and packaging instructions.
]]
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HTTP = game:GetService("HttpService")
assert(immediate and immediate.push_clip and font, "JoX Library requires Jael X with clipping support")
local previous=shared.JoXLibrary or shared.JaelDrawingUI
if previous and previous.Unload then pcall(function() previous:Unload() end) end
local Library = { Version = "1.1.2", Windows = {}, Connections = {}, Alive = true, Visible = true, ToggleKey = "RightControl",
	Rounding = 2, Notifications = true, NotificationDuration = 4, NotificationPosition = "Bottom right" }
shared.JaelDrawingUI = Library
shared.JoXLibrary = Library
local Theme = {
	background = Color3.fromRGB(19,9,15), panel = Color3.fromRGB(24,11,18),
	header = Color3.fromRGB(33,15,24), field = Color3.fromRGB(31,14,23),
	border = Color3.fromRGB(57,25,41), text = Color3.fromRGB(211,197,204),
	muted = Color3.fromRGB(146,118,132), accent = Color3.fromRGB(160,36,84),
	danger = Color3.fromRGB(241,99,120), success = Color3.fromRGB(92,214,154),
}
Library.Theme = Theme
local themeDefaults={};for k,v in pairs(Theme) do themeDefaults[k]=v end
local themePresets={Wine={160,36,84},Violet={166,139,250},Ocean={56,189,248},Emerald={52,211,153},Rose={251,113,133},Amber={251,191,36}}
Library.ThemePresets={"Wine","Violet","Ocean","Emerald","Rose","Amber"}
local fonts, notifications, hits = {}, {}, {}
local mouse = Vector2.new(0,0)
local drag, slider, editing, capture, popup, hover
local keyStates, lastError, serial = {}, 0, 0
local configPath = "JaelUI/configs.json"
local function running() return Library.Alive and shared.JoXLibrary == Library end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function copy(v)
	if type(v)~="table" then return v end
	local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t
end
local function fd(size)
	fonts[size]=fonts[size] or font.get_font_descriptor("Segoe UI",size)
	return fonts[size]
end
local function rect(x,y,w,h,color,radius,filled)
	if w<=0 or h<=0 then return end
	local corner=math.min((radius or 4)*Library.Rounding/6,w/2,h/2)
	immediate.rectangle(Vector2.new(x,y),Vector2.new(x+w,y+h),corner,filled~=false,false,color)
end
local function text(x,y,s,color,size)
	immediate.text(Vector2.new(x,y),tostring(s),fd(size or 13),false,color or Theme.text)
end
-- DirectWrite draws a text layout from its top, not from the visible glyph top.
-- Center the measured line box consistently instead of per-control Y offsets.
local measureCache,measureCount={},0
local function textBounds(value,size)
	local key=tostring(size).."/"..value
	if not measureCache[key]then
		if measureCount>=512 then measureCache={};measureCount=0 end
		local ok,bounds=pcall(immediate.calculate_text_size,value,fd(size))
		measureCache[key]=ok and bounds or Vector2.new(#value*size*.52,size*1.33)
		measureCount=measureCount+1
	end
	return measureCache[key]
end
local function rowText(x,y,width,height,value,color,size,align)
	size=size or 12;value=tostring(value)
	local bounds=textBounds(value,size)
	if align=="center"then x=x+(width-bounds.X)/2 elseif align=="right"then x=x+width-bounds.X end
	text(x,y+(height-bounds.Y)/2,value,color,size)
end
local function line(x,y,w,color) rect(x,y,w,1,color or Theme.border,0) end
local function inside(p,x,y,w,h) return p.X>=x and p.Y>=y and p.X<x+w and p.Y<y+h end
local function clip(x,y,w,h) immediate.push_clip(Vector2.new(x,y),Vector2.new(x+w,y+h)) end
local function region(x,y,w,h) immediate.interactive_region(Vector2.new(x,y),Vector2.new(x+w,y+h)) end
local function hit(x,y,w,h,action,tip,owner,wheel)
	hits[#hits+1]={x=x,y=y,w=w,h=h,action=action,tip=tip,owner=owner,wheel=wheel}
end
local function callback(fn,...)
	if type(fn)~="function" then return end
	local args={...}
	task.spawn(function()
		if not running() then return end
		local ok,err=pcall(fn,table.unpack(args))
		if not ok then Library:Notify("Callback error",tostring(err),5,"error") end
	end)
end
local function makeId(prefix) serial=serial+1; return prefix.."/"..serial end
local function keyName(key) return type(key)=="string" and key or key.Name end
local function normalize(control,value)
	if control.kind=="toggle" then assert(type(value)=="boolean","Expected boolean");return value end
	if control.kind=="progress" then assert(finite(value),"Expected a finite progress value");return clamp(value,0,1) end
	if control.kind=="slider" or control.numeric then
		local n=tonumber((tostring(value):gsub(",",".")))
		assert(finite(n),"Expected a finite number")
		n=clamp(n,control.min,control.max)
		if control.step then n=control.min+math.floor((n-control.min)/control.step+.5)*control.step end
		return clamp(n,control.min,control.max)
	end
	if control.kind=="dropdown" then
		if control.multi then
			assert(type(value)=="table","Expected a selection list")
			local result={}
			for _,option in ipairs(control.options) do for _,v in ipairs(value) do if option==v then result[#result+1]=option;break end end end
			return result
		end
		for _,option in ipairs(control.options) do if value==option then return value end end
		error("Unknown dropdown option")
	end
	if control.kind=="color" then
		if typeof(value)=="Color3" then value={value.R*255,value.G*255,value.B*255} end
		assert(type(value)=="table","Expected Color3 or RGB list")
		local result={}
		for i=1,3 do assert(finite(value[i]),"Expected finite RGB channels");result[i]=clamp(math.floor(value[i]+.5),0,255) end
		return result
	end
	if control.kind=="keybind" then
		value=keyName(value);assert(value=="None" or value:match("^MB[123]$") or pcall(function() assert(Enum.KeyCode[value]) end),"Unknown key")
		return value
	end
	assert(type(value)=="string","Expected text")
	return value:sub(1,control.maxLength or 128)
end
local function selected(list,value) for _,v in ipairs(list) do if v==value then return true end end; return false end
local function emit(c)
	local v=c.value
	if c.kind=="keybind" then callback(c.changed,v);return end
	if c.kind=="color" then v=Color3.fromRGB(v[1],v[2],v[3]) else v=copy(v) end
	callback(c.callback,v)
end
local function set(c,value,silent)
	c.value=normalize(c,value)
	if not silent then emit(c) end
	return c.handle
end
local function editCommit()
	if not editing then return true end
	local e=editing;editing=nil
	local ok,err=pcall(e.apply,e.buffer)
	if not ok then Library:Notify("Invalid input",tostring(err),3,"error") end
	return ok
end
local function clearFocus() editCommit(); drag=nil;slider=nil;capture=nil;popup=nil end
local function startEdit(c,apply,value)
	editing={control=c,apply=apply,buffer=tostring(value),selectAll=true}
	if c.kind~="color" then popup=nil end
end

--=========================== PUBLIC ELEMENT API ==========================--
local function element(section,kind,opts)
	opts=opts or {};assert(type(opts)=="table","Use an options table")
	local c={kind=kind,title=opts.text or opts.title or kind,callback=opts.callback,tooltip=opts.tooltip,
		style=opts.style or "secondary",visible=opts.visible~=false,disabled=opts.disabled==true,window=section.tab.window,section=section,
		min=opts.min or 0,max=opts.max or 100,step=opts.step,numeric=opts.numeric==true,
		options=copy(opts.options or {}),multi=opts.multi==true,maxLength=opts.maxLength or 128,
		mode=opts.mode or "Toggle",active=false,getter=opts.get,changed=opts.onChanged,placeholder=opts.placeholder or "Enter a value"}
	assert(c.min<c.max,"min must be lower than max")
	if kind=="keybind" then assert(c.mode=="Hold" or c.mode=="Toggle" or c.mode=="Press","Unknown keybind mode") end
	local default=opts.default
	if default==nil then
		if kind=="toggle" then default=false
		elseif kind=="progress" then default=0
		else default=kind=="slider" and c.min or c.numeric and c.min or kind=="dropdown" and (c.multi and {} or c.options[1])
			or kind=="color" and {151,105,255} or kind=="keybind" and "None" or "" end
	end
	if kind=="dropdown" then assert(#c.options>0,"Dropdown requires options") end
	local stateful=kind=="toggle" or kind=="slider" or kind=="dropdown" or kind=="input" or kind=="keybind" or kind=="color"
	if stateful or kind=="progress" then c.value=normalize(c,default);c.default=copy(c.value) end
	c.flag=opts.flag or (section.tab.title.."/"..section.title.."/"..c.title)
	local window=c.window
	if stateful then assert(not window.flags[c.flag],"Duplicate flag: "..c.flag);window.flags[c.flag]=c end
	section.elements[#section.elements+1]=c
	local h={_control=c};c.handle=h
	function h:GetValue() return copy(c.value) end
	h.Get=h.GetValue
	function h:SetValue(v,silent) return set(c,v,silent) end
	h.Set=h.SetValue
	function h:Reset(silent) assert(c.default~=nil,"Control has no value");return set(c,copy(c.default),silent) end
	function h:SetStyle(v) assert(kind=="button" and (v=="primary" or v=="secondary" or v=="danger"),"Unknown button style");c.style=v;return self end
	function h:SetText(v) c.title=tostring(v);return self end
	function h:SetVisible(v) c.visible=not not v;return self end
	function h:SetDisabled(v) c.disabled=not not v;return self end
	function h:SetTooltip(v) c.tooltip=v;return self end
	function h:GetState() return kind=="keybind" and c.active or c.value end
	function h:SetOptions(options,keepSelection)
		assert(kind=="dropdown" and #options>0,"Expected nonempty dropdown options")
		c.options=copy(options)
		local ok=keepSelection and pcall(function() set(c,c.value,true) end)
		if not ok then set(c,c.multi and {} or c.options[1]) end
		if popup and popup.control==c then popup=nil end
		return self
	end
	function h:SetKey(key) assert(kind=="keybind");set(c,key);return self end
	function h:SetMode(mode) assert(kind=="keybind" and (mode=="Hold" or mode=="Toggle" or mode=="Press"));c.mode=mode;return self end
	function h:Remove()
		if editing and editing.control==c then editing=nil end
		if popup and popup.control==c then popup=nil end
		if capture==c then capture=nil end
		if slider and slider.control==c then slider=nil end
		window.flags[c.flag]=nil
		for i,x in ipairs(section.elements) do if x==c then table.remove(section.elements,i);break end end
	end
	if opts.fireOnInit and stateful then emit(c) end
	return h
end
local function newSection(tab,title,column)
	column=column or "left";assert(column=="left" or column=="right" or column=="full","Unknown section column")
	assert(not tab.layout or tab.layout==(column=="full" and "full" or "split"),"Do not mix full and split sections")
	tab.layout=column=="full" and "full" or "split"
	local s={tab=tab,title=title,column=column,elements={},collapsed=false,visible=true}
	tab.sections[#tab.sections+1]=s
	for name,kind in pairs({Toggle="toggle",Slider="slider",Dropdown="dropdown",Input="input",Keybind="keybind",ColorPicker="color",Button="button",Label="label",Divider="divider",Paragraph="paragraph",Progress="progress"}) do
		s["Add"..name]=function(self,opts) return element(self,kind,opts) end
		s["New"..name]=s["Add"..name]
	end
	function s:AddMultiSelect(opts) opts=copy(opts or {});opts.multi=true;return element(self,"dropdown",opts) end
	function s:SetCollapsed(v) self.collapsed=not not v;return self end
	function s:SetVisible(v) self.visible=not not v;return self end
	return s
end
local function loadDatabase()
	local ok,result=pcall(function() return HTTP:JSONDecode(buffer.tostring(fs.read_async(configPath))) end)
	return ok and type(result)=="table" and result or {}
end
local function persist(database)
	local ok,err=pcall(function()
		if not fs.is_directory("JaelUI") then fs.create_directory("JaelUI") end
		fs.write_async(configPath,HTTP:JSONEncode(database))
	end)
	return ok,err
end
function Library:NewWindow(opts)
	opts=opts or {}
	local w={title=opts.title or "JoX Library",subtitle=opts.subtitle or "Drawing interface",id=opts.configId or opts.title or "JoX Library",
		x=opts.x or 70,y=opts.y or 55,width=opts.width or 880,height=opts.height or 610,
		tabs={},flags={},visible=true,minimized=false,tabScroll=0,aliases=opts.configAliases or {},query=""}
	w.width,w.height=math.max(650,w.width),math.max(420,w.height)
	Library.Windows[#Library.Windows+1]=w
	function w:NewTab(title,description,options)
		options=options or {}
		local t={window=self,title=title,description=description or "",icon=options.icon,badge=options.badge,sections={},scroll={left=0,right=0,full=0}}
		if self.tabs[#self.tabs] and self.tabs[#self.tabs]._config then table.insert(self.tabs,#self.tabs,t)
		else self.tabs[#self.tabs+1]=t end
		if not self.active or self.active._config then self.active=t end
		function t:NewSection(title,column) return newSection(self,title,column) end
		t.Section=t.NewSection
		function t:Select() clearFocus();self.window.active=self;self.window.query="";return self end
		return t
	end
	w.Tab=w.NewTab
	function w:SetSearch(value) self.query=tostring(value or ""):sub(1,64);for _,t in ipairs(self.tabs)do t.scroll={left=0,right=0,full=0} end;return self end
	function w:GetSearch() return self.query end
	function w:ResetDefaults(includeAppearance)
		clearFocus();local count=0
		for flag,c in pairs(self.flags)do if includeAppearance or flag:sub(1,1)~="_" then set(c,copy(c.default));count=count+1 end end
		return count
	end
	function w:GetFlag(flag) return self.flags[flag] and self.flags[flag].handle:GetValue() end
	function w:ExportConfig()
		local values={};for flag,c in pairs(self.flags) do values[flag]={value=copy(c.value),mode=c.mode} end
		return HTTP:JSONEncode({version=1,values=values,position={self.x,self.y},size={self.width,self.height}})
	end
	function w:ImportConfig(raw)
		local config=type(raw)=="string" and HTTP:JSONDecode(raw) or raw
		assert(type(config)=="table" and type(config.values)=="table","Invalid config format")
		local accepted,rejected={},{}
		for old,entry in pairs(config.values) do
			local flag=self.aliases[old] or old;local c=self.flags[flag]
			if c then
				local value=entry;if type(entry)=="table" and entry.value~=nil then value=entry.value end
				local ok,result=pcall(normalize,c,value)
				if ok then accepted[#accepted+1]={c=c,v=result,mode=type(entry)=="table" and entry.mode}
				else rejected[#rejected+1]=flag end
			end
		end
		-- Apply a preset before explicit colors so custom theme values survive import.
		local function priority(entry)
			if entry.c.flag=="_uiPreset"then return 0 end
			return entry.c.flag:sub(1,9)=="_uiColor/" and 2 or 1
		end
		table.sort(accepted,function(a,b)return priority(a)<priority(b)end)
		for _,entry in ipairs(accepted) do
			entry.c.value=entry.v
			if entry.c.kind=="keybind" and (entry.mode=="Hold" or entry.mode=="Toggle" or entry.mode=="Press") then entry.c.mode=entry.mode end
			emit(entry.c)
		end
		if config.position and finite(config.position[1]) and finite(config.position[2]) then self.x,self.y=config.position[1],config.position[2] end
		if config.size and finite(config.size[1]) and finite(config.size[2]) then self.width,self.height=clamp(config.size[1],650,1600),clamp(config.size[2],420,1000) end
		return #accepted,rejected
	end
	function w:SaveConfig(name)
		assert(type(name)=="string" and name:match("%S") and #name<=64,"Choose a config name (1-64 characters)")
		local db=loadDatabase();db[self.id]=db[self.id] or {};db[self.id][name]=HTTP:JSONDecode(self:ExportConfig())
		return persist(db)
	end
	function w:LoadConfig(name)
		local entry=(loadDatabase()[self.id] or {})[name];assert(entry,"Config not found")
		return self:ImportConfig(entry)
	end
	function w:DeleteConfig(name)
		local db=loadDatabase();if db[self.id] then db[self.id][name]=nil end;return persist(db)
	end
	function w:ListConfigs()
		local result={};for name in pairs(loadDatabase()[self.id] or {}) do result[#result+1]=name end;table.sort(result);return result
	end
	function w:SetVisible(v) self.visible=not not v;clearFocus();return self end
	function w:Toggle() return self:SetVisible(not self.visible) end
	function w:Notify(...) return Library:Notify(...) end
	function w:Remove()
		if self.visible then clearFocus() end
		for i,win in ipairs(Library.Windows) do if win==self then table.remove(Library.Windows,i);break end end
	end
	if opts.configs~=false then
		local tab=w:NewTab("Configs","Save and restore your settings")
		tab._config=true
		local s=tab:NewSection("Configuration manager","left")
		local name=s:AddInput({text="Config name",flag="_configName",default="Default"})
		local choices=w:ListConfigs();if #choices==0 then choices={"(none)"} end
		local list=s:AddDropdown({text="Saved configs",flag="_configList",options=choices})
		local function refresh() local items=w:ListConfigs();list:SetOptions(#items>0 and items or {"(none)"}) end
		s:AddButton({text="Save config",callback=function() local ok,err=w:SaveConfig(name:Get());assert(ok,err);refresh();Library:Notify("Config saved",name:Get(),3) end})
		s:AddButton({text="Load selected",callback=function() local count,bad=w:LoadConfig(list:Get());Library:Notify("Config loaded",count.." settings restored; "..#bad.." rejected",3) end})
		s:AddButton({text="Refresh list",callback=refresh})
		local confirm
		s:AddButton({text="Delete selected (click twice)",callback=function()
			local selectedName=list:Get()
			if confirm~=selectedName then confirm=selectedName;Library:Notify("Confirm deletion","Click Delete again for "..selectedName,4);return end
			local ok,err=w:DeleteConfig(selectedName);assert(ok,err);confirm=nil;refresh()
		end})
		s:AddButton({text="Copy config JSON",callback=function() assert(setclipboard,"Clipboard unavailable");setclipboard(w:ExportConfig());Library:Notify("Copied","Configuration JSON copied",3) end})
		s:AddButton({text="Restore feature defaults",callback=function()local count=w:ResetDefaults();Library:Notify("Defaults restored",count.." controls reset")end})
		s:AddParagraph({text="Configs restore callbacks. Explicit flags stay stable when visible labels change. Files are stored in Jael X script-data/JaelUI."})
		local appearance=tab:NewSection("Appearance","right")
		appearance:AddDropdown({text="Theme preset",flag="_uiPreset",options=Library.ThemePresets,default="Wine",callback=function(v)Library:SetThemePreset(v)end})
		for _,entry in ipairs({{"Accent color","accent"},{"Background","background"},{"Section background","panel"},{"Header / popups","header"},{"Input background","field"},{"Borders","border"},{"Main text","text"},{"Secondary text","muted"}}) do
			local key=entry[2]
			appearance:AddColorPicker({text=entry[1],flag="_uiColor/"..key,default=Theme[key],callback=function(v)Theme[key]=v end})
		end
		appearance:AddSlider({text="Corner rounding",flag="_uiRounding",min=0,max=14,step=1,default=Library.Rounding,callback=function(v)Library.Rounding=v end})
		local settings=tab:NewSection("Menu and notifications","right")
		settings:AddKeybind({text="Open / close menu",flag="_uiMenuKey",default=Library.ToggleKey,onChanged=function(v)Library:SetToggleKey(v)end,tooltip="Click to capture a key. Escape cancels; Backspace unbinds."})
		settings:AddToggle({text="Show notifications",flag="_uiNotifications",default=true,callback=function(v)Library.Notifications=v end})
		settings:AddSlider({text="Notification duration",flag="_uiNoticeDuration",min=1,max=10,step=0.5,default=4,callback=function(v)Library.NotificationDuration=v end})
		settings:AddDropdown({text="Notification corner",flag="_uiNoticeCorner",options={"Bottom right","Top right","Bottom left","Top left"},default="Bottom right",callback=function(v)Library.NotificationPosition=v end})
		settings:AddButton({text="Preview notification",callback=function()Library:Notify("JoX Library","Your theme is ready.")end})
	end
	return w
end
Library.Window=Library.NewWindow
function Library:SetToggleKey(key) self.ToggleKey=keyName(key) end
function Library:SetTheme(values) for key,v in pairs(values) do if Theme[key] then assert(typeof(v)=="Color3","Theme colors must be Color3");Theme[key]=v end end end
function Library:SetThemePreset(name)
	assert(themePresets[name],"Unknown theme preset")
	for k,v in pairs(themeDefaults)do Theme[k]=v end
	Theme.accent=Color3.fromRGB(table.unpack(themePresets[name]))
	for _,w in ipairs(self.Windows)do for key,value in pairs(Theme)do local c=w.flags["_uiColor/"..key];if c then set(c,value,true)end end end
	return self
end
function Library:SetVisible(v) self.Visible=not not v;clearFocus() end
function Library:IsInteracting() return running() and self.Visible and (editing~=nil or drag~=nil or slider~=nil or popup~=nil or capture~=nil) end
function Library:IsMouseOverUI()
	if not self.Visible then return false end
	for _,w in ipairs(self.Windows) do if w.visible and inside(mouse,w.x,w.y,w.width,w.minimized and 28 or w.height) then return true end end
	return false
end
function Library:Notify(title,body,duration,kind)
	if not self.Notifications then return end
	if #notifications>=5 then table.remove(notifications,1) end
	duration=duration or self.NotificationDuration
	assert(finite(duration) and duration>0,"Notification duration must be positive")
	local notice={title=tostring(title),body=tostring(body or ""),untilTime=os.clock()+duration,duration=duration,kind=kind}
	function notice:Dismiss()self.untilTime=0 end
	notifications[#notifications+1]=notice
	return notice
end
function Library:Unload()
	if not self.Alive then return end
	self.Alive=false
	for _,c in ipairs(self.Connections) do pcall(function() c:Disconnect() end) end
	self.Connections={};self.Windows={};hits={};notifications={}
	drag=nil;slider=nil;editing=nil;capture=nil;popup=nil
	if shared.JaelDrawingUI==self then shared.JaelDrawingUI=nil end
	if shared.JoXLibrary==self then shared.JoXLibrary=nil end
end

--=========================== RENDERING ==========================--
local function wrap(value,width,size)
	local result,current={},""
	for word in tostring(value):gmatch("%S+") do
		local candidate=current=="" and word or current.." "..word
		local ok,bounds=pcall(immediate.calculate_text_size,candidate,fd(size or 13))
		if current~="" and (ok and bounds.X or #candidate*7)>width then result[#result+1]=current;current=word else current=candidate end
	end
	if current~="" then result[#result+1]=current end
	return result
end
local function controlHeight(c,width)
	if c.kind=="divider"then return 12 end
	if c.kind=="paragraph"then return #wrap(c.title,width-24,12)*16+10 end
	if c.kind=="slider" or c.kind=="input" or c.kind=="dropdown"then return 40 end
	if c.kind=="progress"then return 36 end
	return 24
end
local function valueText(c)
	if c.kind=="dropdown" and c.multi then return #c.value==0 and "None selected" or table.concat(c.value,", ") end
	if c.kind=="color" then return string.format("#%02X%02X%02X",table.unpack(c.value)) end
	return tostring(c.value or "")
end
local function buttonHit(c,x,y,w,h,action)
	if not c.disabled then hit(x,y,w,h,action,c.tooltip,c.window) end
end
local function beginSlider(c,x,width)
	slider={control=c,x=x,width=width,apply=function(f) set(c,c.min+(c.max-c.min)*clamp(f,0,1)) end}
	slider.apply((mouse.X-x)/width)
end
local function renderControl(c,x,y,width,clipTop,clipBottom)
	local height=controlHeight(c,width)
	if y+height<clipTop or y>clipBottom then return height end
	local active=y>=clipTop and y+height<=clipBottom
	local fg=c.disabled and Theme.muted or Theme.text
	local function interact(bx,by,bw,bh,fn)if active then buttonHit(c,bx,by,bw,bh,fn)end end
	if c.kind=="divider"then line(x+10,y+5,width-20);return height end
	if c.kind=="paragraph"then for i,s in ipairs(wrap(c.title,width-24,12))do text(x+12,y+4+(i-1)*16,s,Theme.muted,12)end;return height end
	if c.kind=="label"then
		local v=c.title;if c.getter then local ok,result=pcall(c.getter);if ok then v=result end end
		rowText(x+12,y,width-24,20,v,fg,12);return height
	end
	if c.kind=="button"then
		local color=not c.disabled and (c.style=="primary" and Theme.accent or c.style=="danger" and Theme.danger)or Theme.field
		rect(x+12,y+2,width-24,19,color,1);rect(x+12,y+2,width-24,19,inside(mouse,x+12,y+2,width-24,19)and Theme.accent or Theme.border,1,false)
		rowText(x+20,y+2,width-40,19,c.title,fg,12)
		interact(x+12,y+2,width-24,19,function()callback(c.callback)end);return height
	end
	rowText(x+(c.kind=="toggle" and 31 or 12),y,width-45,20,c.title,fg,12)
	if c.kind=="toggle"then
		rect(x+12,y+4,12,12,c.value and Theme.accent or Theme.field,1)
		rect(x+12,y+4,12,12,c.value and Theme.accent or Theme.border,1,false)
		interact(x+9,y,width-18,height,function()set(c,not c.value)end)
	elseif c.kind=="slider"then
		local bx,bw=x+12,width-24;local fraction=(c.value-c.min)/(c.max-c.min)
		rect(bx,y+21,bw,12,Theme.field,1);rect(bx,y+21,math.max(1,bw*fraction),12,Theme.accent,1);rect(bx,y+21,bw,12,Theme.border,1,false)
		local display=editing and editing.control==c and editing.buffer.."|" or string.format("%.4g",c.value)
		rowText(bx,y+21,bw,12,display,fg,11,"center")
		interact(bx,y+18,bw,19,function()beginSlider(c,bx,bw)end)
		interact(bx+bw/2-30,y+21,60,12,function()startEdit(c,function(v)set(c,v)end,c.value)end)
		if active and not c.disabled then hit(bx,y,bw,height,nil,c.tooltip,c.window,function(delta)set(c,c.value+delta*(c.step or (c.max-c.min)/100))end)end
	elseif c.kind=="input" or c.kind=="dropdown"then
		rect(x+12,y+19,width-24,18,Theme.field,1);rect(x+12,y+19,width-24,18,Theme.border,1,false)
		local value=editing and editing.control==c and editing.buffer.."|" or valueText(c)
		clip(x+17,y+19,width-44,18);rowText(x+18,y+19,width-44,18,value=="" and c.placeholder or value,fg,11);immediate.pop_clip()
		if c.kind=="dropdown"then rowText(x+width-30,y+19,18,18,"+",Theme.muted,11,"center")end
		interact(x+12,y+19,width-24,18,function()
			if c.kind=="input"then startEdit(c,function(v)set(c,v)end,c.value)
			else popup=popup and popup.control==c and nil or {control=c,x=x+12,y=y+39,width=width-24,scroll=0}end
		end)
	elseif c.kind=="keybind"then
		local binding=capture==c and "Press a key..." or c.value
		rect(x+width-114,y+1,102,18,Theme.field,1);rect(x+width-114,y+1,102,18,Theme.border,1,false)
		rowText(x+width-106,y+1,86,18,binding,Theme.muted,11)
		interact(x+width-114,y+2,102,18,function()capture=c;popup=nil;editing=nil end)
	elseif c.kind=="color"then
		rect(x+width-37,y+5,24,11,Color3.fromRGB(table.unpack(c.value)),0);rect(x+width-38,y+4,26,13,Theme.border,0,false)
		interact(x+width-40,y+1,31,21,function()popup=popup and popup.control==c and nil or {control=c,x=x+width-282,y=y+24,width=282}end)
	elseif c.kind=="progress"then
		local v=c.value;if c.getter then local ok,result=pcall(c.getter);if ok then v=result end end;v=finite(v)and clamp(v,0,1)or 0
		rect(x+12,y+21,width-24,8,Theme.field,0);rect(x+12,y+21,math.max(1,(width-24)*v),8,Theme.accent,0)
	end
	return height
end
local function renderWindow(w)
	local x,y,width,height=w.x,w.y,w.width,w.minimized and 28 or w.height
	hit(x,y,width,height,function()clearFocus()end,nil,w,function()end)
	rect(x+4,y+5,width,height,Color3.fromRGB(8,3,7),0)
	rect(x,y,width,height,Theme.background,1);rect(x,y,width,height,Theme.border,1,false)
	rect(x+3,y+3,width-6,height-6,Theme.accent,0,false)
	clip(x+12,y+5,width-290,18);rowText(x+12,y+4,width-290,20,w.title,Theme.muted,12);immediate.pop_clip()
	rowText(x+width-52,y+4,21,19,w.minimized and "+"or "-",Theme.muted,12,"center");rowText(x+width-29,y+4,21,19,"x",Theme.muted,12,"center")
	hit(x+width-52,y+4,21,19,function()w.minimized=not w.minimized;clearFocus()end,"Minimize",w)
	hit(x+width-29,y+4,21,19,function()w:SetVisible(false)end,"Hide window",w)
	hit(x+6,y+4,width-65,20,function()drag={window=w,dx=mouse.X-x,dy=mouse.Y-y}end,nil,w)
	region(x,y,width,height)
	if w.minimized then return end
	w.searchControl=w.searchControl or {kind="input",maxLength=64,window=w}
	local query=editing and editing.control==w.searchControl and editing.buffer or w.query
	local sx,sw=x+width-239,175
	rect(sx,y+6,sw,17,Theme.field,1)
	clip(sx+6,y+7,sw-23,15);rowText(sx+6,y+6,sw-23,17,query==""and "Search... / Ctrl+K"or query,Theme.muted,10);immediate.pop_clip()
	hit(sx,y+6,sw-20,17,function()startEdit(w.searchControl,function(v)w:SetSearch(v)end,w.query)end,"Search this page",w)
	if query~=""then rowText(sx+sw-20,y+6,20,17,"x",Theme.muted,10,"center");hit(sx+sw-20,y+6,20,17,function()editing=nil;w:SetSearch("")end,"Clear search",w)end
	local nx,nw,ny,nh=x+12,width-24,y+32,29
	local tabWidth=math.max(94,nw/math.max(1,#w.tabs));local navTotal=tabWidth*#w.tabs
	w.tabScroll=clamp(w.tabScroll,0,math.max(0,navTotal-nw))
	clip(nx,ny,nw,nh)
	for i,t in ipairs(w.tabs)do
		local tx=nx+(i-1)*tabWidth-w.tabScroll
		local active=w.active==t
		rect(tx,ny,tabWidth-2,nh,active and Theme.header or Theme.panel,0);rect(tx,ny,tabWidth-2,nh,Theme.border,0,false)
		if active then line(tx+1,ny+nh-2,tabWidth-4,Theme.accent)end
		local label=t.icon and (tostring(t.icon).." "..t.title)or t.title
		clip(tx+6,ny+5,tabWidth-(t.badge and 42 or 14),20);rowText(tx+6,ny,tabWidth-14,nh,label,active and Theme.accent or Theme.muted,12,"center");immediate.pop_clip()
		if t.badge then rowText(tx+tabWidth-27,ny,21,nh,t.badge,Theme.accent,10,"center")end
		if tx>=nx and tx+tabWidth-2<=nx+nw then hit(tx,ny,tabWidth-2,nh,function()t:Select()end,t.description,w)end
	end
	immediate.pop_clip()
	hit(nx,ny,nw,nh,nil,nil,w,function(d)w.tabScroll=clamp(w.tabScroll-d*64,0,math.max(0,navTotal-nw))end)
	local t=w.active;if not t then return end
	local cx,cy,cw,ch=x+16,y+94,width-32,height-120
	text(cx+7,y+73,t.title,Theme.accent,12)
	clip(cx+110,y+70,cw-117,18);text(cx+110,y+74,t.description,Theme.muted,11);immediate.pop_clip()
	line(cx,y+88,cw,Theme.border)
	local needle=query:lower()
	local function matches(c,s)
		return c.visible and (needle=="" or (s.title.." "..c.title.." "..(c.tooltip or "")):lower():find(needle,1,true)~=nil)
	end
	local function sectionShown(s)
		if not s.visible then return false end
		if needle==""then return true end
		for _,c in ipairs(s.elements)do if matches(c,s)then return true end end
		return false
	end
	local found=0
	for _,s in ipairs(t.sections)do if s.visible then for _,c in ipairs(s.elements)do if matches(c,s)then found=found+1 end end end end
	text(cx,y+height-24,Library.ToggleKey.." to toggle  /  "..found.." controls",Theme.muted,11)
	if found==0 and needle~=""then
		rect(cx,cy,cw,104,Theme.panel,8);text(cx+20,cy+23,"No matching controls",Theme.text,16)
		text(cx+20,cy+52,"Try another name or clear the search field.",Theme.muted,12)
	end
	local columns=t.layout=="full" and {"full"} or {"left","right"}
	for index,column in ipairs(columns) do
		local firstHit=#hits+1
		local colWidth=t.layout=="full" and cw or (cw-14)/2
		local colX=cx+(index-1)*(colWidth+14)
		local total=0
		for _,s in ipairs(t.sections) do if sectionShown(s) and s.column==column then
			local h=25
			if not s.collapsed or needle~=""then for _,c in ipairs(s.elements)do if matches(c,s)then h=h+controlHeight(c,colWidth)end end;h=h+6 end
			s.height=h;total=total+h+10
		end end
		t.scroll[column]=clamp(t.scroll[column],0,math.max(0,total-ch))
		clip(colX,cy,colWidth,ch)
		local sy=cy-t.scroll[column]
		for _,s in ipairs(t.sections)do if sectionShown(s) and s.column==column then
			if sy+s.height>=cy and sy<=cy+ch then
				rect(colX,sy,colWidth,s.height,Theme.panel,0);rect(colX,sy,colWidth,s.height,Theme.border,0,false);line(colX+1,sy,colWidth-2,Theme.accent)
				rowText(colX+10,sy,colWidth-35,23,s.title,Theme.text,12);rowText(colX+colWidth-26,sy,20,23,s.collapsed and "+"or "-",Theme.muted,11,"center")
				if sy>=cy and sy+23<=cy+ch then hit(colX,sy,colWidth,23,function()s.collapsed=not s.collapsed;clearFocus()end,nil,w)end
				if not s.collapsed or needle~=""then
					line(colX+10,sy+23,colWidth-20)
					local ey=sy+27
					for _,c in ipairs(s.elements)do if matches(c,s)then ey=ey+renderControl(c,colX,ey,colWidth,cy,cy+ch)end end
				end
			end
			sy=sy+s.height+10
		end end
		immediate.pop_clip()
		table.insert(hits,firstHit,{x=colX,y=cy,w=colWidth,h=ch,owner=w,wheel=function(d)t.scroll[column]=clamp(t.scroll[column]-d*36,0,math.max(0,total-ch));popup=nil end})
		if total>ch then
			local bar=math.max(20,ch*ch/total);local bx=colX+colWidth-4
			rect(bx,cy,3,ch,Theme.field,1);rect(bx,cy+(ch-bar)*t.scroll[column]/(total-ch),3,bar,Theme.accent,1)
			hit(bx-4,cy,11,ch,function()
				slider={update=function()t.scroll[column]=clamp((mouse.Y-cy-bar/2)/(ch-bar),0,1)*(total-ch)end};slider.update()
			end,"Drag to scroll",w)
		end
	end
	hit(x+width-16,y+height-16,16,16,function()drag={window=w,resize=true,dx=mouse.X-width,dy=mouse.Y-height}end,"Resize window",w)
	text(x+width-14,y+height-16,"/",Theme.muted)
end
local function rgbToHSV(rgb)
	local r,g,b=rgb[1]/255,rgb[2]/255,rgb[3]/255
	local hi,lo=math.max(r,g,b),math.min(r,g,b);local d=hi-lo;local h=0
	if d>0 then
		if hi==r then h=((g-b)/d)%6 elseif hi==g then h=(b-r)/d+2 else h=(r-g)/d+4 end
		h=h/6
	end
	return h,hi==0 and 0 or d/hi,hi
end
local function hsvRGB(h,s,v)
	local i=math.floor(h*6);local f=h*6-i;local p,q,t=v*(1-s),v*(1-f*s),v*(1-(1-f)*s)
	local values={{v,t,p},{q,v,p},{p,v,t},{p,q,v},{t,p,v},{v,p,q}}
	local rgb=values[i%6+1];return {rgb[1]*255,rgb[2]*255,rgb[3]*255}
end
local function renderPopup(view)
	if not popup then return end
	local p,c=popup,popup.control
	if not c.window.visible or c.window.minimized then popup=nil;return end
	local height=c.kind=="color" and 370 or math.min(236,#c.options*28+8)
	p.x=clamp(p.x,0,math.max(0,view.X-p.width));p.y=clamp(p.y,0,math.max(0,view.Y-height))
	p.height=height
	rect(p.x,p.y,p.width,height,Theme.header,5);rect(p.x,p.y,p.width,height,Theme.border,5,false)
	region(p.x,p.y,p.width,height)
	if c.kind=="dropdown" then
		local total=#c.options*28
		p.scroll=clamp(p.scroll,0,math.max(0,total-height+8))
		clip(p.x+2,p.y+3,p.width-4,height-6)
		for i,option in ipairs(c.options) do
			local oy=p.y+4+(i-1)*28-p.scroll
			local yes=c.multi and selected(c.value,option) or (not c.multi and c.value==option)
			if yes then rect(p.x+4,oy,p.width-8,27,Theme.field,3) end
			rowText(p.x+12,oy,p.width-24,27,(yes and "+ " or "  ")..option,yes and Theme.accent or Theme.text,13)
			if oy>=p.y+3 and oy+27<=p.y+height-3 then hit(p.x+4,oy,p.width-8,27,function()
				if c.multi then local v=copy(c.value);if yes then for j,x in ipairs(v) do if x==option then table.remove(v,j);break end end else v[#v+1]=option end;set(c,v)
				else set(c,option);popup=nil end
			end,nil,c.window) end
		end
		immediate.pop_clip()
	else
		local hue,saturation,value=rgbToHSV(c.value)
		if saturation>0 then p.hue=hue else hue=p.hue or hue end
		text(p.x+12,p.y+12,"Color studio",Theme.text,15)
		rect(p.x+p.width-43,p.y+10,30,19,Color3.fromRGB(table.unpack(c.value)),4)
		local gx,gy,gw,gh=p.x+12,p.y+42,p.width-24,132
		-- Rasterize the SV plane using native filled rectangles; no texture or
		-- HTTP dependency is needed in the external Drawing renderer.
		local cols,rows=48,32
		if p.planeHue~=hue then
			p.planeHue=hue;p.plane={}
			for row=0,rows-1 do for col=0,cols-1 do p.plane[row*cols+col+1]=Color3.fromRGB(table.unpack(hsvRGB(hue,col/(cols-1),1-row/(rows-1))))end end
		end
		for row=0,rows-1 do for col=0,cols-1 do rect(gx+col*gw/cols,gy+row*gh/rows,gw/cols+1,gh/rows+1,p.plane[row*cols+col+1],0)end end
		local px,py=gx+saturation*gw,gy+(1-value)*gh
		immediate.circle(Vector2.new(px,py),6,true,false,Theme.background)
		immediate.circle(Vector2.new(px,py),4,true,false,Theme.text)
		hit(gx,gy,gw,gh,function()
			slider={control=c,update=function()set(c,hsvRGB(p.hue or hue,clamp((mouse.X-gx)/gw,0,1),1-clamp((mouse.Y-gy)/gh,0,1)))end};slider.update()
		end,"Saturation and brightness",c.window)
		local hy=p.y+187
		for i=0,35 do rect(gx+i*gw/36,hy,gw/36+1,12,Color3.fromRGB(table.unpack(hsvRGB(i/36,1,1))),0)end
		rect(gx+hue*gw-3,hy-3,6,18,Theme.text,2,false)
		hit(gx,hy-4,gw,20,function()
			slider={control=c,update=function()
				p.hue=clamp((mouse.X-gx)/gw,0,.9999);local _,ss,vv=rgbToHSV(c.value);set(c,hsvRGB(p.hue,ss,vv))
			end};slider.update()
		end,"Hue",c.window)
		for i,rgb in ipairs({{166,139,250},{56,189,248},{52,211,153},{251,113,133},{251,191,36},{255,255,255},{0,0,0},{100,116,139}})do
			local xx=gx+(i-1)*32
			rect(xx,p.y+215,24,22,Color3.fromRGB(table.unpack(rgb)),4)
			hit(xx,p.y+215,24,22,function()set(c,rgb)end,"Apply color swatch",c.window)
		end
		for i,name in ipairs({"R","G","B"})do
			local xx=gx+(i-1)*88
			text(xx,p.y+247,name,Theme.muted,10)
			rect(xx,p.y+263,80,27,Theme.field,4)
			local current=editing and editing.control==c and editing.channel==i and editing.buffer.."|" or tostring(c.value[i])
			rowText(xx+10,p.y+263,60,27,current,Theme.text,12)
			hit(xx,p.y+263,80,27,function()
				startEdit(c,function(raw)local n=tonumber(raw);assert(finite(n) and n>=0 and n<=255,"Use an RGB channel from 0 to 255");local rgb=copy(c.value);rgb[i]=n;set(c,rgb)end,c.value[i]);editing.channel=i
			end,"Edit "..name.." channel",c.window)
		end
		text(gx,p.y+300,"HEX",Theme.muted,10)
		rect(gx,p.y+316,p.width-84,28,Theme.field,4)
		rowText(gx+10,p.y+316,p.width-104,28,editing and editing.control==c and not editing.channel and editing.buffer.."|" or valueText(c),Theme.text,12)
		hit(gx,p.y+316,p.width-84,28,function()
			startEdit(c,function(v)
				local hex=v:gsub("#","");assert(hex:match("^%x%x%x%x%x%x$"),"Use #RRGGBB")
				set(c,{tonumber(hex:sub(1,2),16),tonumber(hex:sub(3,4),16),tonumber(hex:sub(5,6),16)})
			end,valueText(c))
		end,"Edit hex color",c.window)
		rect(p.x+p.width-61,p.y+316,49,28,Theme.field,4);rowText(p.x+p.width-61,p.y+316,49,28,"Copy",Theme.accent,11,"center")
		hit(p.x+p.width-61,p.y+316,49,28,function()if setclipboard then pcall(setclipboard,valueText(c))end end,"Copy hex",c.window)
		text(gx,p.y+353,"Drag to preview  /  Enter to apply text",Theme.muted,10)
	end
end

--=========================== INPUT AND LIFECYCLE ==========================--
local function inputName(e)
	local map={MouseButton1="MB1",MouseButton2="MB2",MouseButton3="MB3"}
	return map[e.UserInputType.Name] or e.KeyCode.Name
end
local function topHit(wheelOnly)
	local first=popup and (Library._popupStart or #hits)+1 or 1
	for i=#hits,first,-1 do local h=hits[i];if inside(mouse,h.x,h.y,h.w,h.h) and (wheelOnly and h.wheel or not wheelOnly and h.action) then return h end end
end
local function bringForward(w)
	for i,x in ipairs(Library.Windows) do if x==w then table.remove(Library.Windows,i);Library.Windows[#Library.Windows+1]=w;break end end
end
local chars={Space=" ",Minus="-",Equals="=",Period=".",Comma=",",Slash="/",BackSlash="\\",Semicolon=";",Quote="'",LeftBracket="[",RightBracket="]",Backquote="`"}
local shifted={Space=" ",Minus="_",Equals="+",Period=">",Comma="<",Slash="?",BackSlash="|",Semicolon=":",Quote='"',LeftBracket="{",RightBracket="}",Backquote="~"}
local digits={Zero="0",One="1",Two="2",Three="3",Four="4",Five="5",Six="6",Seven="7",Eight="8",Nine="9"}
local shiftDigits={Zero=")",One="!",Two="@",Three="#",Four="$",Five="%",Six="^",Seven="&",Eight="*",Nine="("}
Library.Connections[#Library.Connections+1]=UIS.InputBegan:Connect(function(e)
	if not running() then return end
	mouse=UIS:GetMouseLocation();local name=inputName(e)
	if keyStates[name] then return end;keyStates[name]=true
	if capture then
		if name=="Escape" then capture=nil;return end
		if name=="Backspace" or name=="Delete" then name="None" end
		set(capture,name);capture=nil;return
	end
	if name==Library.ToggleKey and not editing then Library:SetVisible(not Library.Visible);return end
	if name=="Escape" and popup and not editing then popup=nil;return end
	if name=="K" and Library.Visible and not editing and (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)) then
		local w=Library.Windows[#Library.Windows]
		if w and w.visible and not w.minimized then w.searchControl=w.searchControl or {kind="input",maxLength=64,window=w};startEdit(w.searchControl,function(v)w:SetSearch(v)end,w.query)end
		return
	end
	if editing and e.UserInputType==Enum.UserInputType.Keyboard then
		if name=="Return" then editCommit();return end
		if name=="Escape" then editing=nil;return end
		local ctrl=UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)
		if ctrl and name=="A" then editing.selectAll=true;return end
		if ctrl and name=="C" then if setclipboard then pcall(setclipboard,editing.buffer) end;return end
		if ctrl and name=="V" then
			if getclipboard then local ok,v=pcall(getclipboard);if ok and type(v)=="string" then editing.buffer=(editing.selectAll and "" or editing.buffer)..v:gsub("[%c]","");editing.buffer=editing.buffer:sub(1,editing.control.maxLength or 128);editing.selectAll=false end end;return
		end
		if name=="Backspace" then editing.buffer=editing.selectAll and "" or editing.buffer:sub(1,-2);editing.selectAll=false;return end
		local shift=UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
		local ch=digits[name] and (shift and shiftDigits[name] or digits[name]) or (shift and shifted[name] or chars[name]) or name:match("^Keypad(%d)$")
		if #name==1 then ch=shift and name:upper() or name:lower() end
		if ch then editing.buffer=((editing.selectAll and "" or editing.buffer)..ch):sub(1,editing.control.maxLength or 128);editing.selectAll=false end
		return
	end
	if name=="MB1" and Library.Visible then
		editCommit()
		if popup and not inside(mouse,popup.x,popup.y,popup.width,popup.height or 0) then popup=nil;return end
		local h=topHit(false)
		if h then bringForward(h.owner);h.action();return end
	end
	if editing or Library:IsMouseOverUI() then return end
	for _,w in ipairs(Library.Windows) do for _,c in pairs(w.flags) do if c.kind=="keybind" and not c.disabled and c.value==name then
		if c.mode=="Toggle" then c.active=not c.active;callback(c.callback,c.active)
		elseif c.mode=="Hold" then c.active=true;callback(c.callback,true)
		else callback(c.callback,true) end
	end end end
end)
Library.Connections[#Library.Connections+1]=UIS.InputEnded:Connect(function(e)
	local name=inputName(e);keyStates[name]=nil
	if name=="MB1" then drag=nil;slider=nil end
	for _,w in ipairs(Library.Windows) do for _,c in pairs(w.flags) do if c.kind=="keybind" and c.mode=="Hold" and c.value==name and c.active then c.active=false;callback(c.callback,false) end end end
end)
Library.Connections[#Library.Connections+1]=UIS.InputChanged:Connect(function(e)
	if not running() or not Library.Visible or e.UserInputType~=Enum.UserInputType.MouseWheel then return end
	mouse=UIS:GetMouseLocation()
	if popup then if popup.control.kind=="dropdown" and inside(mouse,popup.x,popup.y,popup.width,popup.height or 0) then popup.scroll=clamp((popup.scroll or 0)-e.Position.Z*28,0,math.max(0,#popup.control.options*28-(popup.height or 0)+8)) end;return end
	local h=topHit(true);if h then h.wheel(e.Position.Z) end
end)
Library.Connections[#Library.Connections+1]=RS.PreRender:Connect(function()
	if not running() then return end
	local ok,err=pcall(function()
		hits={};mouse=UIS:GetMouseLocation();local view=Drawing3D.GetViewportSize()
		if drag then
			local w=drag.window
			if drag.resize then w.width=clamp(mouse.X-drag.dx,650,math.max(650,view.X));w.height=clamp(mouse.Y-drag.dy,420,math.max(420,view.Y))
			else w.x,w.y=mouse.X-drag.dx,mouse.Y-drag.dy end
		end
		if slider then if slider.update then slider.update() else slider.apply((mouse.X-slider.x)/slider.width)end end
		if Library.Visible then
			for _,w in ipairs(Library.Windows) do if w.visible then
				w.x,w.y=clamp(w.x,0,math.max(0,view.X-w.width)),clamp(w.y,0,math.max(0,view.Y-w.height))
				renderWindow(w)
			end end
			Library._popupStart=#hits
			renderPopup(view)
			local h=topHit(false)
			if h and h.tip and not popup then
				if not hover or hover.hit.tip~=h.tip then hover={hit=h,since=os.clock()} end
				if os.clock()-hover.since>.6 then
					local lines=wrap(h.tip,245,12);local tx,ty=clamp(mouse.X+14,0,view.X-269),clamp(mouse.Y+18,0,view.Y-#lines*17-20)
					rect(tx,ty,265,#lines*17+16,Theme.header,5);for i,s in ipairs(lines) do text(tx+10,ty+8+(i-1)*17,s,Theme.text,12) end
				end
			else hover=nil end
		end
		local atTop=Library.NotificationPosition:find("Top",1,true)~=nil
		local left=Library.NotificationPosition:find("left",1,true)~=nil
		local nx=left and 20 or view.X-338
		local ny=atTop and 20 or view.Y-20
		for i=#notifications,1,-1 do
			local n=notifications[i]
			if os.clock()>=n.untilTime then table.remove(notifications,i)
			else
				local body=wrap(n.body,278,12);local h=48+#body*16;if not atTop then ny=ny-h-10 end
				rect(nx,ny,318,h,Theme.panel,7);rect(nx,ny,318,h,Theme.border,7,false)
				local tone=n.kind=="error" and Theme.danger or n.kind=="success" and Theme.success or Theme.accent
				rect(nx,ny,3,h,tone,1)
				text(nx+292,ny+10,"x",Theme.muted,12)
				hit(nx+281,ny+4,30,27,function()n:Dismiss()end,"Dismiss notification",Library.Windows[#Library.Windows])
				text(nx+16,ny+10,n.title,Theme.text,14)
				for j,s in ipairs(body) do text(nx+16,ny+33+(j-1)*16,s,Theme.muted,12) end
				rect(nx+16,ny+h-6,286*clamp((n.untilTime-os.clock())/n.duration,0,1),2,Theme.accent,1)
				if atTop then ny=ny+h+10 end
			end
		end
	end)
	if not ok and os.clock()-lastError>3 then lastError=os.clock();warn("[JOX_LIBRARY] "..tostring(err)) end
end)
return Library
