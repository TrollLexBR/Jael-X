--[[
	JoX Library — standalone interface library for Jael X (Lua 5.4).
	External Drawing primitives only; no Roblox instances or gameplay writes.
	RightControl toggles all windows. Call Library:Unload() to disconnect signals.
	See README.md and examples/demo.lua for the public API and packaging instructions.
]]
local RS = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HTTP = game:GetService("HttpService")
assert(immediate and immediate.push_clip and font, "JoX Library requires Jael X with clipping support")
local previous=shared.JoXLibrary or shared.JaelDrawingUI
if previous and previous.Unload then pcall(function() previous:Unload() end) end
local Library = { Version = "1.0.0", Windows = {}, Connections = {}, Alive = true, Visible = true, ToggleKey = "RightControl",
	Rounding = 6, Notifications = true, NotificationDuration = 4, NotificationPosition = "Bottom right" }
shared.JaelDrawingUI = Library
shared.JoXLibrary = Library
local Theme = {
	background = Color3.fromRGB(16,17,22), panel = Color3.fromRGB(23,25,32),
	header = Color3.fromRGB(29,31,40), field = Color3.fromRGB(34,37,48),
	border = Color3.fromRGB(51,55,70), text = Color3.fromRGB(231,233,242),
	muted = Color3.fromRGB(143,150,172), accent = Color3.fromRGB(151,105,255),
	danger = Color3.fromRGB(241,99,120), success = Color3.fromRGB(92,214,154),
}
Library.Theme = Theme
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
		visible=opts.visible~=false,disabled=opts.disabled==true,window=section.tab.window,section=section,
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
	if stateful or kind=="progress" then c.value=normalize(c,default) end
	c.flag=opts.flag or (section.tab.title.."/"..section.title.."/"..c.title)
	local window=c.window
	if stateful then assert(not window.flags[c.flag],"Duplicate flag: "..c.flag);window.flags[c.flag]=c end
	section.elements[#section.elements+1]=c
	local h={_control=c};c.handle=h
	function h:GetValue() return copy(c.value) end
	h.Get=h.GetValue
	function h:SetValue(v,silent) return set(c,v,silent) end
	h.Set=h.SetValue
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
		tabs={},flags={},visible=true,minimized=false,tabScroll=0,aliases=opts.configAliases or {}}
	w.width,w.height=math.max(650,w.width),math.max(420,w.height)
	Library.Windows[#Library.Windows+1]=w
	function w:NewTab(title,description)
		local t={window=self,title=title,description=description or "",sections={},scroll={left=0,right=0,full=0}}
		if self.tabs[#self.tabs] and self.tabs[#self.tabs]._config then table.insert(self.tabs,#self.tabs,t)
		else self.tabs[#self.tabs+1]=t end
		if not self.active or self.active._config then self.active=t end
		function t:NewSection(title,column) return newSection(self,title,column) end
		t.Section=t.NewSection
		function t:Select() self.window.active=self;clearFocus();return self end
		return t
	end
	w.Tab=w.NewTab
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
		s:AddParagraph({text="Configs restore callbacks. Explicit flags stay stable when visible labels change. Files are stored in Jael X script-data/JaelUI."})
		local appearance=tab:NewSection("Appearance","right")
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
function Library:SetVisible(v) self.Visible=not not v;clearFocus() end
function Library:IsInteracting() return running() and self.Visible and (editing~=nil or drag~=nil or slider~=nil or popup~=nil or capture~=nil) end
function Library:IsMouseOverUI()
	if not self.Visible then return false end
	for _,w in ipairs(self.Windows) do if w.visible and inside(mouse,w.x,w.y,w.width,w.minimized and 62 or w.height) then return true end end
	return false
end
function Library:Notify(title,body,duration,kind)
	if not self.Notifications then return end
	if #notifications>=5 then table.remove(notifications,1) end
	duration=duration or self.NotificationDuration
	assert(finite(duration) and duration>0,"Notification duration must be positive")
	notifications[#notifications+1]={title=tostring(title),body=tostring(body or ""),untilTime=os.clock()+duration,duration=duration,kind=kind}
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
	if c.kind=="divider" then return 18 end
	if c.kind=="paragraph" then return #wrap(c.title,width-28)*18+12 end
	if c.kind=="slider" or c.kind=="input" or c.kind=="dropdown" then return 60 end
	if c.kind=="progress" then return 50 end
	return 36
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
	local function interact(bx,by,bw,bh,fn)
		if active then buttonHit(c,bx,by,bw,bh,fn) end
	end
	if c.kind=="divider" then line(x+14,y+8,width-28);return height end
	if c.kind=="paragraph" then for i,s in ipairs(wrap(c.title,width-28)) do text(x+14,y+4+(i-1)*18,s,Theme.muted) end;return height end
	if c.kind=="label" then
		local v=c.title;if c.getter then local ok,result=pcall(c.getter);if ok then v=result end end
		text(x+14,y+9,v,fg);return height
	end
	if c.kind=="button" then
		rect(x+14,y+3,width-28,29,inside(mouse,x+14,y+3,width-28,29) and Theme.header or Theme.field,5)
		text(x+24,y+10,c.title,fg)
		interact(x+14,y+3,width-28,29,function() callback(c.callback) end);return height
	end
	text(x+14,y+7,c.title,fg)
	if c.kind=="toggle" then
		rect(x+width-51,y+8,35,19,c.value and Theme.accent or Theme.field,9)
		immediate.circle(Vector2.new(x+width-(c.value and 25 or 42),y+17),6,true,false,Theme.text)
		interact(x+10,y,width-20,height,function() set(c,not c.value) end)
	elseif c.kind=="slider" then
		local display=editing and editing.control==c and editing.buffer.."|" or string.format("%.4g",c.value)
		rect(x+width-84,y+3,68,22,Theme.field,4);text(x+width-77,y+7,display,Theme.accent)
		interact(x+width-84,y+3,68,22,function() startEdit(c,function(v)set(c,v)end,c.value) end)
		local barX,barW=x+16,width-32
		rect(barX,y+37,barW,5,Theme.field,3)
		local fraction=(c.value-c.min)/(c.max-c.min)
		rect(barX,y+37,math.max(1,barW*fraction),5,Theme.accent,3)
		immediate.circle(Vector2.new(barX+barW*fraction,y+39),5,true,false,Theme.accent)
		interact(barX,y+29,barW,20,function() beginSlider(c,barX,barW) end)
		if active and not c.disabled then hit(x+12,y,width-24,height,nil,c.tooltip,c.window,function(delta)set(c,c.value+delta*(c.step or (c.max-c.min)/100))end) end
	elseif c.kind=="input" or c.kind=="dropdown" then
		rect(x+14,y+27,width-28,27,Theme.field,4)
		local value=editing and editing.control==c and editing.buffer.."|" or valueText(c)
		clip(x+21,y+28,width-56,25);text(x+23,y+33,value=="" and c.placeholder or value,fg);immediate.pop_clip()
		if c.kind=="dropdown" then text(x+width-32,y+33,"v",Theme.muted) end
		interact(x+14,y+27,width-28,27,function()
			if c.kind=="input" then startEdit(c,function(v)set(c,v)end,c.value)
			else popup=popup and popup.control==c and nil or {control=c,x=x+14,y=y+56,width=width-28,scroll=0} end
		end)
	elseif c.kind=="keybind" then
		local binding=capture==c and "Press a key..." or c.value
		rect(x+width-128,y+4,112,26,Theme.field,4);text(x+width-119,y+10,binding,Theme.accent)
		interact(x+width-128,y+4,112,26,function() capture=c;popup=nil;editing=nil end)
	elseif c.kind=="color" then
		rect(x+width-92,y+6,76,22,Color3.fromRGB(table.unpack(c.value)),4)
		interact(x+width-92,y+6,76,22,function() popup=popup and popup.control==c and nil or {control=c,x=x+width-230,y=y+36,width=214} end)
	elseif c.kind=="progress" then
		local v=c.getter and c.getter() or c.value;v=finite(v) and clamp(v,0,1) or 0
		rect(x+14,y+29,width-28,7,Theme.field,4);rect(x+14,y+29,math.max(1,(width-28)*v),7,Theme.accent,4)
	end
	return height
end
local function renderWindow(w)
	local x,y,width,height=w.x,w.y,w.width,w.minimized and 62 or w.height
	hit(x,y,width,height,function()clearFocus()end,nil,w,function()end)
	rect(x+5,y+7,width,height,Color3.fromRGB(8,9,12),9)
	rect(x,y,width,height,Theme.background,8);rect(x,y,width,height,Theme.border,8,false)
	rect(x+1,y+1,width-2,3,Theme.accent,0)
	text(x+20,y+14,w.title,Theme.text,21);text(x+20,y+40,w.subtitle,Theme.muted,12)
	text(x+width-68,y+21,w.minimized and "+" or "-",Theme.muted,18);text(x+width-36,y+21,"x",Theme.muted,16)
	hit(x+width-78,y+10,32,36,function()w.minimized=not w.minimized;clearFocus()end,nil,w)
	hit(x+width-43,y+10,32,36,function()w:SetVisible(false)end,"Hide window",w)
	hit(x+8,y+6,width-90,51,function()drag={window=w,dx=mouse.X-x,dy=mouse.Y-y}end,nil,w)
	region(x,y,width,height)
	if w.minimized then return end
	local side=172
	rect(x+1,y+63,side,height-64,Theme.panel,0);line(x+1,y+62,width-2)
	local navHeight=height-102;local navTotal=#w.tabs*52
	w.tabScroll=clamp(w.tabScroll,0,math.max(0,navTotal-navHeight))
	clip(x+8,y+77,side-15,navHeight)
	for i,t in ipairs(w.tabs) do
		local ty=y+77+(i-1)*52-w.tabScroll
		if ty+45>=y+77 and ty<=y+77+navHeight then
			if w.active==t then rect(x+9,ty,side-17,44,Theme.header,5);rect(x+9,ty+7,3,30,Theme.accent,1) end
			text(x+26,ty+8,t.title,w.active==t and Theme.text or Theme.muted,14)
			clip(x+26,ty+25,side-36,17);text(x+26,ty+26,t.description,Theme.muted,10);immediate.pop_clip()
			if ty>=y+77 and ty+44<=y+77+navHeight then hit(x+9,ty,side-17,44,function()w.active=t;clearFocus()end,nil,w) end
		end
	end
	immediate.pop_clip()
	hit(x+8,y+77,side-15,navHeight,nil,nil,w,function(d)w.tabScroll=clamp(w.tabScroll-d*36,0,math.max(0,navTotal-navHeight))end)
	text(x+20,y+height-23,"JOX / DRAWING",Theme.muted,10)
	local t=w.active;if not t then return end
	local cx,cy,cw,ch=x+side+18,y+80,width-side-35,height-119
	text(cx,y+height-24,"RightCtrl to toggle  /  "..Library.Version,Theme.muted,11)
	local columns=t.layout=="full" and {"full"} or {"left","right"}
	for index,column in ipairs(columns) do
		local firstHit=#hits+1
		local colWidth=t.layout=="full" and cw or (cw-14)/2
		local colX=cx+(index-1)*(colWidth+14)
		local total=0
		for _,s in ipairs(t.sections) do if s.visible and s.column==column then
			local h=37
			if not s.collapsed then for _,c in ipairs(s.elements) do if c.visible then h=h+controlHeight(c,colWidth) end end;h=h+8 end
			s.height=h;total=total+h+14
		end end
		t.scroll[column]=clamp(t.scroll[column],0,math.max(0,total-ch))
		clip(colX,cy,colWidth,ch)
		local sy=cy-t.scroll[column]
		for _,s in ipairs(t.sections) do if s.visible and s.column==column then
			if sy+s.height>=cy and sy<=cy+ch then
				rect(colX,sy,colWidth,s.height,Theme.panel,6);rect(colX,sy,colWidth,s.height,Theme.border,6,false)
				text(colX+14,sy+11,s.title,Theme.text,14);text(colX+colWidth-24,sy+11,s.collapsed and "+" or "-",Theme.muted)
				if sy>=cy and sy+35<=cy+ch then hit(colX,sy,colWidth,35,function()s.collapsed=not s.collapsed;clearFocus()end,nil,w) end
				if not s.collapsed then
					line(colX+12,sy+35,colWidth-24)
					local ey=sy+39
					for _,c in ipairs(s.elements) do if c.visible then ey=ey+renderControl(c,colX,ey,colWidth,cy,cy+ch) end end
				end
			end
			sy=sy+s.height+14
		end end
		immediate.pop_clip()
		-- Scroll fallback is below widget hits; a slider consumes its own wheel.
		table.insert(hits,firstHit,{x=colX,y=cy,w=colWidth,h=ch,owner=w,wheel=function(d)t.scroll[column]=clamp(t.scroll[column]-d*36,0,math.max(0,total-ch));popup=nil end})
		if total>ch then local bar=math.max(20,ch*ch/total);rect(colX+colWidth-3,cy+(ch-bar)*t.scroll[column]/(total-ch),3,bar,Theme.accent,1) end
	end
	hit(x+width-16,y+height-16,16,16,function()drag={window=w,resize=true,dx=mouse.X-width,dy=mouse.Y-height}end,"Resize window",w)
	text(x+width-14,y+height-16,"/",Theme.muted)
end
local function renderPopup(view)
	if not popup then return end
	local p,c=popup,popup.control
	if not c.window.visible or c.window.minimized then popup=nil;return end
	local height=c.kind=="color" and 175 or math.min(236,#c.options*28+8)
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
			text(p.x+12,oy+7,(yes and "+ " or "  ")..option,yes and Theme.accent or Theme.text)
			if oy>=p.y+3 and oy+27<=p.y+height-3 then hit(p.x+4,oy,p.width-8,27,function()
				if c.multi then local v=copy(c.value);if yes then for j,x in ipairs(v) do if x==option then table.remove(v,j);break end end else v[#v+1]=option end;set(c,v)
				else set(c,option);popup=nil end
			end,nil,c.window) end
		end
		immediate.pop_clip()
	else
		text(p.x+12,p.y+10,"Color / RGB + Hex",Theme.text,14)
		for i,name in ipairs({"R","G","B"}) do
			local yy=p.y+40+(i-1)*31
			text(p.x+12,yy,name,Theme.muted);text(p.x+p.width-37,yy,c.value[i],Theme.text,11)
			local bx,bw=p.x+33,p.width-82
			rect(bx,yy+6,bw,5,Theme.field,2);rect(bx,yy+6,math.max(1,bw*c.value[i]/255),5,Theme.accent,2)
			hit(bx,yy-3,bw,22,function()
				slider={control=c,x=bx,width=bw,apply=function(f)local v=copy(c.value);v[i]=clamp(f,0,1)*255;set(c,v)end};slider.apply((mouse.X-bx)/bw)
			end,nil,c.window)
		end
		rect(p.x+12,p.y+139,p.width-24,25,Theme.field,4)
		text(p.x+22,p.y+145,editing and editing.control==c and editing.buffer.."|" or valueText(c),Theme.text)
		hit(p.x+12,p.y+139,p.width-24,25,function()
			startEdit(c,function(v)
				local hex=v:gsub("#","");assert(hex:match("^%x%x%x%x%x%x$"),"Use #RRGGBB")
				set(c,{tonumber(hex:sub(1,2),16),tonumber(hex:sub(3,4),16),tonumber(hex:sub(5,6),16)})
			end,valueText(c))
		end,nil,c.window)
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
	if name==Library.ToggleKey then Library:SetVisible(not Library.Visible);return end
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
	if popup then if inside(mouse,popup.x,popup.y,popup.width,popup.height or 0) then popup.scroll=clamp((popup.scroll or 0)-e.Position.Z*28,0,math.max(0,#popup.control.options*28-(popup.height or 0)+8)) end;return end
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
		if slider then slider.apply((mouse.X-slider.x)/slider.width) end
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
				rect(nx,ny,318,h,Theme.panel,7);rect(nx,ny,3,h,n.kind=="error" and Theme.danger or Theme.accent,1)
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
