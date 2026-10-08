// Run against a private Jael X development fixture; never sends live input.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const runtime = process.env.JAELX_TEST_ROOT;
if (!runtime) throw Error('Set JAELX_TEST_ROOT to a private Jael X 1.31.5 development fixture.');
const script = path.resolve(__dirname, '../examples/PhantomF.lua').replaceAll('\\', '/');
const library = path.resolve(__dirname, '../JoX-Library.lua').replaceAll('\\', '/');
const fixture = { valid: true, viewport: [960, 720], camera: { cframe: { __type: 'CFrame', components: [1,0,0,0,1,0,0,0,1,0,0,0] }, fov: 90, address: '0x10000' }, entities: [] };

function run(body) {
	const job = path.join(runtime, `pf-entities-${process.pid}.json`);
	fs.writeFileSync(job, JSON.stringify({ source: body, maxMs: 8000, testDrawingSnapshot: fixture,
		testDrawingInput: [{ focused: false, keys: [], buttons: [], mouse: [480,360], viewport: [960,720], wheelSequence: 0, wheel: 0 }] }));
	try {
		const result = spawnSync(path.join(runtime, 'JaelX.exe'), ['--worker', job, 'Local\\PFEntitiesFixture'],
			{ cwd: runtime, windowsHide: true, encoding: 'utf8', timeout: 15000, maxBuffer: 40 * 1024 * 1024 });
		assert.equal(result.status, 0, result.stderr || result.stdout);
		const events = result.stdout.split(/\r?\n/).filter(Boolean).map(JSON.parse);
		const errors = events.filter(e => e.level === 'error' || e.level === 'warning');
		assert.deepEqual(errors, [], errors.map(e => e.text).join('\n'));
		return events;
	} finally { fs.rmSync(job, { force: true }); }
}

const setup = `
local realGame=game;local RS=game:GetService("RunService")
local realLoadfile=loadfile
loadfile=function(file) if file=="scripts/JoX-Library.lua" then return realLoadfile(${JSON.stringify(library)}) end;return realLoadfile(file) end
local function makeCharacter(name,x,color)
	local healthBar={Size={X={Scale=.6,Offset=0}}}
	local healthFrame={Visible=true};function healthFrame:FindFirstChild(n)if n=="Percent"then return healthBar end end
	local label={Parent=true,ContentText=name,TextColor3=color};function label:IsA(c)return c=="TextLabel"end
	function label:FindFirstChild(n)if n=="Health" then return healthFrame end end
	local billboard={IsA=function(_,c)return c=="BillboardGui"end,GetChildren=function()return {label}end}
	local light={IsA=function(_,c)return c=="SpotLight"end}
	local offsets={{0,1.5},{0,0},{-1.5,0},{1.5,0},{-.5,-2},{.5,-2}}
	local parts={};for i,offset in ipairs(offsets)do
		local children=i==1 and {billboard}or i==2 and {light}or {}
		local part={Name="Obfuscated"..i,Size=Vector3.new(.001,.001,.001),CFrame=CFrame.new(x+offset[1],offset[2],-25)}
		function part:IsA(c)return c=="BasePart"end;function part:GetChildren()return children end;parts[i]=part
	end
	local model={Name="Hidden",Parent=true,IsA=function(_,c)return c=="Model"end,GetChildren=function()return parts end}
	return {model=model,parts=parts,healthFrame=healthFrame,healthBar=healthBar,label=label}
end
local enemy=makeCharacter("Enemy",-2,Color3.fromRGB(255,10,20))
local ally=makeCharacter("Ally",2,Color3.fromRGB(0,230,230))
local models={enemy.model,ally.model}
local team={GetChildren=function()return models end}
local folder={Parent=true,GetChildren=function()return {team}end}
workspace={CurrentCamera={CFrame=CFrame.identity},FindFirstChild=function(_,name)if name=="Players"then return folder end end}
game={PlaceId=292439477,GetService=function(_,name)if name=="Players"then return {}end;return realGame:GetService(name)end}
local settings={aim=false,wallCheck=false,visibilityColors=false,rosterRate=.2,showAllies=false,
	chams=true,box2d=true,nametags=true,healthBars=true,thickness=2,boxStyle="Corners"}
local json=realGame:GetService("HttpService"):JSONEncode(settings)
fs={read_async=function()return buffer.fromstring(json)end,write_async=function()end,is_directory=function()return true end}
input={is_window_focused=function()return false end,is_mouse_down=function()return false end,
	get_status=function()return {enabled=false}end,mouse_move_relative=function()error("Fixture must never send mouse input")end}
local batchCalls=0
entities.get_parts_snapshot=function(parts)
	batchCalls=batchCalls+1;local result={parts={}}
	for i,part in ipairs(parts)do if part.invalid then result.parts[i]=false else result.parts[i]={cframe=part.CFrame,size=part.Size}end end
	return result
end
`;

test('complete PF hub: real Entity List, all ESP controls, live options, stale poses, health, respawn and two cleanup cycles', () => {
	const events = run(setup + `
for cycle=1,2 do
	models={enemy.model,ally.model};enemy.healthFrame.Visible=true;enemy.healthBar.Size.X.Scale=.6
	local driver=task.spawn(function()
		task.wait(.13)
		local app=assert(shared.PF_ASSIST);assert(app.Library and app.window,"Real JoX UI failed")
		local list=assert(app.entityList);assert(list.Count==2 and list.LastError==nil)
		local entry=assert(app.visuals[enemy.model]).entry
		assert(entry.Features.Chams.Kind=="Chams" and entry.Features.Box.Kind=="Box")
		assert(entry.Health==60 and entry.Active and not app.visuals[ally.model].entry.Active)
		assert(entry.PoseNames.Head.Size.X>1,"PF tiny part dimensions must be corrected")
		assert(entry.Features.Chams.Options.Style=="Silhouette")
		assert(entry.Features.Box.Options.Thickness==2,"Legacy thickness was lost")
		for _,key in ipairs({"esp","skeleton","chamsStyle","chamsOutline","boxDashLength","skeletonBorder",
			"tracerTarget","nameFont","healthSide","healthBackgroundOpacity"}) do assert(app.controls[key],key) end
		app.controls.skeleton:SetValue(true);app.controls.tracers:SetValue(true);app.controls.showAllies:SetValue(true)
		app.controls.chamsStyle:SetValue("Wireframe");app.controls.boxStyle:SetValue("Dashed")
		app.controls.healthSide:SetValue("Bottom");app.controls.healthText:SetValue(true)
		app.controls.chamsUseEntityColor:SetValue(false);app.controls.chamsColor:SetValue(Color3.new(1,.2,.65))
		app.controls.chamsOutlineColor:SetValue(Color3.new(1,1,1));app.controls.chamsOutlineOpacity:SetValue(.75)
		app.controls.tracerOrigin:SetValue("Mouse");app.controls.tracerTarget:SetValue("Top")
		task.wait(.07)
		assert(entry.Features.Skeleton.Options.Enabled and #entry.Features.Skeleton.Options.Connections==5)
		assert(entry.Features.Tracer.Options.Origin=="Mouse" and entry.Features.Tracer.Options.Target=="Top")
		assert(entry.Features.Chams.Options.Style=="Wireframe" and entry.Features.Box.Options.Style=="Dashed")
		assert(entry.Features.Chams.Options.Color(entry)==app.config.chamsColor)
		assert(app.visuals[ally.model].entry.Active,"Ally toggle did not update list filter")
		enemy.healthFrame.Visible=false;task.wait(.16);assert(entry.Health==nil,"Hidden HP was fabricated")
		enemy.parts[1].invalid=true;task.wait(.05);assert(entry.PoseNames.Head==nil,"Failed pose left a stale head")
		enemy.parts[1].invalid=false;enemy.parts[1].CFrame=CFrame.new(-1,1.5,-25)
		enemy.healthFrame.Visible=true;enemy.healthBar.Size.X.Scale=.25
		task.wait(.16);assert(entry.Health==25 and entry.PoseNames.Head.CFrame.Position.X==-1,"Current pose was not refreshed")
		app.controls.esp:SetValue(false);task.wait(.05);assert(not entry.Active)
		app.controls.esp:SetValue(true);app.controls.chamsStyle:SetValue("Silhouette")
		app.controls.boxStyle:SetValue("3D");task.wait(.05);assert(entry.Features.Box.Options.Style=="3D")
		models={ally.model};task.wait(.25);assert(list.Count==1 and entry.Removed,"Removed character stayed in list")
		local replacement=makeCharacter("Respawn",-2,Color3.fromRGB(255,10,20))
		models={ally.model,replacement.model};task.wait(.25);assert(list.Count==2 and app.visuals[replacement.model])
		assert(batchCalls>20,"Expected fresh per-frame pose batches")
		app.stop();assert(list.Destroyed and list.Count==0 and shared.PF_ASSIST==nil)
	end)
	assert(realLoadfile(${JSON.stringify(script)}))()
	print("[PF_ENTITY_TEST] cycle",cycle,"passed")
end
`);
	assert.equal(events.filter(e => e.text?.startsWith('[PF_ENTITY_TEST] cycle')).length, 2);
	const commands = events.filter(e => e.type === 'drawing-frame').flatMap(e => e.commands);
	assert(commands.some(c => c.kind === 'silhouette' && c.parts.length === 6));
	assert(commands.some(c => c.kind === 'line' && c.thickness === 2));
	assert(commands.some(c => c.kind === 'text' && c.text === 'Enemy'));
});

test('60 obfuscated characters share one native pose batch per frame and one silhouette command per character', () => {
	const events = run(setup + `
models={}
for i=1,60 do local character=makeCharacter("Player "..i,(i%10)-5,Color3.fromRGB(255,10,20));models[i]=character.model end
task.spawn(function()
	task.wait(.12)
	local app=assert(shared.PF_ASSIST);assert(app.entityList.Count==60,"Roster not fully registered")
	assert(app.stats.drawn==60 and app.stats.poseParts==360)
	assert(batchCalls==app.stats.frames,"More than one native pose batch per frame")
	for _,v in pairs(app.visuals) do assert(#v.entity.poses==6 and v.entry.Active) end
	app.stop()
end)
assert(realLoadfile(${JSON.stringify(script)}))()
`);
	const frames = events.filter(e => e.type === 'drawing-frame');
	assert(frames.some(frame => frame.commands.filter(c => c.kind === 'silhouette').length === 60));
});
