// Partial-cover regressions use geometric boxes and mock input; no live game access.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const runtime = process.env.JAELX_TEST_ROOT;
if (!runtime) throw Error('Set JAELX_TEST_ROOT to a private Jael X 1.31.5 development fixture.');
const script = fs.readFileSync(path.resolve(__dirname, '../examples/PhantomF.lua'), 'utf8');
const helpers = script.slice(script.indexOf('local rayCache='), script.indexOf('local function drawLine('));
const fixture = { valid: true, viewport: [640,420], camera: { cframe: { __type: 'CFrame', components: [1,0,0,0,1,0,0,0,1,0,0,0] }, fov: 90, address: '0x10000' }, entities: [] };
function run(source) {
	const job=path.join(runtime,`pf-peek-${process.pid}.json`);
	fs.writeFileSync(job,JSON.stringify({source,maxMs:4000,testDrawingSnapshot:fixture}));
	try {
		const result=spawnSync(path.join(runtime,'JaelX.exe'),['--worker',job,'Local\\PFPeekFixture'],{cwd:runtime,encoding:'utf8',windowsHide:true,timeout:7000});
		assert.equal(result.status,0,result.stderr||result.stdout);
		const events=result.stdout.split(/\r?\n/).filter(Boolean).map(JSON.parse);
		const failures=events.filter(e=>e.level==='error'||e.level==='warning');
		assert.deepEqual(failures,[],failures.map(e=>e.text).join('\n'));
	} finally {fs.rmSync(job,{force:true});}
}
const setup=`
local APP={stats={}}
local CFG={wallCheck=true,adaptiveParts=true,surfacePoints=true,lightweight=true,targetPart="Head",fov=120,maxDistance=2000}
local function running()return true end
local function report(err)error(err)end
local function read(o,key)return o and o[key]end
${helpers}
local now=100;os.clock=function()return now end
local origin,center=Vector3.zero,Vector2.new(320,210)
local function body()
	local e={key={},partNames={"Head","Torso","Limb3"},poseNames={
		Head={CFrame=CFrame.new(0,1.8,-20),Size=Vector3.new(1.1,1.1,1.1)},
		Torso={CFrame=CFrame.new(0,0,-20),Size=Vector3.new(2,2,1)},
		Limb3={CFrame=CFrame.new(2,0,-20),Size=Vector3.new(.85,1.8,.85)}}}
	return e,{key=e.key,origin=origin,poses=e.poseNames,names=e.partNames}
end
local function sampleAll(request)
	local count=0
	for i=1,#bodyCandidates(request)do if sampleVisibility(request,.08)then count=count+1 end end
	return count
end
`;

test('head-only peek selects a confirmed head point when its center and torso are blocked',()=>run(setup+`
local e,request=body()
local wall={0,0,-10,1,0,0,0,1,0,0,0,1,10,1,.1}
pointVisibility=function(a,b)return not numericBoxIntersection(wall,a,b-a)end
assert(not pointVisibility(origin,e.poseNames.Head.CFrame.Position),"Head center should be covered")
assert(not pointVisibility(origin,e.poseNames.Torso.CFrame.Position),"Torso should be covered")
assert(sampleAll(request)==21)
local color,target=bodyVisibility(e,origin,center,now)
assert(color==true and target and target.partName=="Head","Exposed head was not selected")
assert(target.worldPoint.Y>e.poseNames.Head.CFrame.Position.Y,"Aim must use the exposed top sample")
assert(pointVisibility(origin,target.worldPoint),"Chosen aim point is blocked")
`));

test('arm-only peek falls back to that arm; no point can authorize another part or an old position',()=>run(setup+`
local e,request=body()
local wall={0,0,-10,1,0,0,0,1,0,0,0,1,.75,10,.1}
pointVisibility=function(a,b)return not numericBoxIntersection(wall,a,b-a)end
sampleAll(request)
local color,target=bodyVisibility(e,origin,center,now)
assert(color==true and target and target.partName=="Limb3","Visible arm must be selected instead of covered head")
assert(pointVisibility(origin,target.worldPoint))
local _,movedCamera=bodyVisibility(e,origin+Vector3.new(.3,0,0),center,now)
assert(movedCamera==nil,"Moved camera reused old clear sample")
e.poseNames.Limb3.CFrame=CFrame.new(2.3,0,-20)
local _,movedArm=bodyVisibility(e,origin,center,now)
assert(movedArm==nil,"Moved arm reused old clear sample")
e.poseNames.Limb3.CFrame=CFrame.new(2,0,-20)
local held,stale=bodyVisibility(e,origin,center,now+.21)
assert(held==true and stale==nil,"Retained green must not authorize stale aim")
pointVisibility=function()return nil end;now=now+.3
sampleAll(request)
local _,unknown=bodyVisibility(e,origin,center,now)
assert(unknown==nil,"Unknown map samples must not authorize aim")
`));

test('center-only mode omits edge probes, blocked body is rejected, and FOV/range remain enforced',()=>run(setup+`
CFG.surfacePoints=false
local e,request=body()
assert(#bodyCandidates(request)==3)
pointVisibility=function()return false end;sampleAll(request)
local color,target=bodyVisibility(e,origin,center,now)
assert(color==false and target==nil)
visibilityEntries={};pointVisibility=function()return true end
sampleAll(request);CFG.maxDistance=5
assert(select(2,bodyVisibility(e,origin,center,now))==nil,"Out-of-range body point accepted")
CFG.maxDistance=2000;CFG.fov=1
assert(select(2,bodyVisibility(e,origin,Vector2.new(100,100),now))==nil,"Out-of-FOV body point accepted")
`));

test('multi-part scheduler bounds total ray work and visits fair and priority requests despite expensive queries',()=>run(setup+`
local requests={}
for i=1,6 do local e,r=body();requests[i]=r end
local hits={};local actualSample=sampleVisibility
pointVisibility=function()now=now+.003;return false end
sampleVisibility=function(request,interval)hits[request.key]=(hits[request.key]or 0)+1;return actualSample(request,interval)end
local cursor=0
for i=1,16 do
	cursor=updateVisibilityBatch(requests,requests[1],cursor,6,.002)
	assert(APP.stats.rayBatchQueries<=6,"Exceeded query cap")
	now=now+.016
end
for _,request in ipairs(requests)do assert(hits[request.key],"Priority or fair request was starved")end
`));

test('fully exposed head requires one target projection rather than projecting every body probe',()=>run(setup+`
local e,request=body();pointVisibility=function()return true end;sampleAll(request)
APP.stats.visibilityPointProjections=0
local color,target=bodyVisibility(e,origin,center,now)
assert(color==true and target.partName=="Head")
assert(target.worldPoint==e.poseNames.Head.CFrame.Position)
assert(APP.stats.visibilityPointProjections==1,"Fully exposed player projected unnecessary body probes")
bodyVisibility(e,origin,center,now,false)
assert(APP.stats.visibilityPointProjections==1,"ESP colors should not project aim points when aim is disabled")
`));
