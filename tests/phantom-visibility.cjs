"use strict";
const fs=require("fs"),path=require("path"),assert=require("assert/strict"),{spawnSync}=require("child_process");
const runtime=process.env.JAELX_TEST_ROOT;
if(!runtime)throw Error("Set JAELX_TEST_ROOT to a private Jael X development fixture.");
const script=fs.readFileSync(path.join(__dirname,"../examples/PhantomF.lua"),"utf8");
const helper=script.slice(script.indexOf("local rayCache="),script.indexOf("local function drawLine("));
const source=`assert(loadstring(${JSON.stringify(script)},"@pf-jox.lua"))
local APP={stats={}};local CFG={wallCheck=true,visibilityColors=true,visibleColor="green",blockedColor="red",unknownColor="gray",targetColor="gold",enemyColor="old",allyColor="cyan"}
local function running()return true end
local function report(e)error(e)end
local function read(o,k)return o and o[k]end
RaycastParams={new=function()return {}end}
local map={Parent=true,FindFirstChild=function()return nil end,GetChildren=function()return {}end,GetDescendants=function()return {}end};local current=map
workspace={FindFirstChild=function(_,name)assert(name=="Map");return current end}
local answer=true;local scan={Complete=true,Truncated=false,Skipped=0};local failure=false
raycast={cast=function(root,origin,direction)assert(root==map,"Only map geometry may be scanned");if failure then error("Reader unavailable")end;local hit;if not answer then hit={Distance=1}end;return hit,scan end}
${helper}
local origin,point=Vector3.zero,Vector3.new(0,0,-30)
local plate={CFrame=CFrame.new(0,0,-5),Size=Vector3.new(10,.001,10)}
assert(thinIntersection(plate,Vector3.new(0,2,-5),Vector3.new(0,-2,-5))==true,"Thin collider must still block")
assert(thinIntersection(plate,Vector3.new(20,2,-5),Vector3.new(20,-2,-5))==false,"Clear ray must pass beside thin collider")
assert(pointVisibility(origin,point)==true and canAimAt(true))
answer=false;assert(pointVisibility(origin,point)==false and not canAimAt(false))
answer=true;scan.Complete=false;assert(pointVisibility(origin,point)==nil and not canAimAt(nil))
scan.Complete=true;assert(pointVisibility(origin,point)==true)
scan.Complete=false;scan.Parts=20;scan.AgeMs=300
assert(pointVisibility(origin,point)==true,"Certified snapshot must stay usable during rebuild")
scan.AgeMs=6000;assert(pointVisibility(origin,point)==nil,"Old snapshots must expire")
scan.AgeMs=300;sampleVisibility({key="enemy",origin=origin,point=point})
local display,aim=cachedVisibility("enemy",origin,point,os.clock());assert(display==true and aim==true)
display,aim=cachedVisibility("enemy",origin+Vector3.new(3,0,0),point,os.clock());assert(display==true and aim==false,"Camera movement must invalidate aim while retaining display")
display,aim=cachedVisibility("enemy",origin,point,os.clock()+.3);assert(display==true and aim==false,"Stale green must not authorize aim")
answer=false;sampleVisibility({key="enemy",origin=origin,point=point});display,aim=cachedVisibility("enemy",origin,point,os.clock());assert(display==false and aim==false,"Blocked cache must retain false")
scan.Skipped=1;sampleVisibility({key="enemy",origin=origin,point=point});display,aim=cachedVisibility("enemy",origin,point,os.clock());assert(display==false and aim==false,"Unknown sample must not flicker confirmed red")
display,aim=cachedVisibility("enemy",origin,point,os.clock()+4);assert(display==nil and aim==false,"Visual cache must expire")
scan.Skipped=0;scan.Complete=true;scan.Truncated=true;assert(pointVisibility(origin,point)==nil);spatialCache={building=false,ready=false,failed=0,cells={},large={},parts=0}
scan.Truncated=false;scan.Skipped=1;assert(pointVisibility(origin,point)==nil)
scan.Skipped=0;failure=true;assert(pointVisibility(origin,point)==nil)
failure=false;current=nil;assert(pointVisibility(origin,point)==nil)
current=map;raycast=nil;assert(pointVisibility(origin,point)==nil)
local wall={0,0,-10,1,0,0,0,1,0,0,0,1,5,5,.5}
spatialCache={ready=true,parts=1,failed=0,cells={["0:0:-1"]={wall}},large={}}
assert(spatialVisibility(origin,point)==false,"Spatial grid must detect blocking OBB")
assert(spatialVisibility(Vector3.new(20,0,0),Vector3.new(20,0,-30))==true,"Spatial grid must permit clear segments")
spatialCache={ready=true,parts=1,failed=0,cells={},large={wall}}
assert(spatialVisibility(origin,point)==false,"Oversized collider list must remain blocking")
CFG.wallCheck=false;assert(canAimAt(nil) and canAimAt(false))
assert(visibilityColor({enemy=true,lineOfSight=true},false)=="green")
assert(visibilityColor({enemy=true,lineOfSight=false},true)=="red")
assert(visibilityColor({enemy=true},true)=="gray")
assert(visibilityColor({enemy=false,lineOfSight=false},false)=="cyan")
CFG.visibilityColors=false;assert(visibilityColor({enemy=true},false)=="old")
-- The scheduler must cover every member of an even-sized roster while holding.
local realClock=os.clock;local fakeTime=100;local sampleCost=0
os.clock=function()return fakeTime end
visibilityEntries={};local sampled={};local requests={}
for i=1,10 do requests[i]={key=i};end
sampleVisibility=function(request)
 sampled[request.key]=(sampled[request.key]or 0)+1
 visibilityEntries[request.key]={checkedAt=fakeTime}
 fakeTime=fakeTime+sampleCost
end
local cursor=0
for i=1,2 do cursor=updateVisibilityBatch(requests,requests[1],cursor,6,.002);fakeTime=fakeTime+.016 end
for i=1,10 do assert(sampled[i],"Priority must not starve roster slot "..i)end
local before=0;for _,n in pairs(sampled)do before=before+n end
updateVisibilityBatch(requests,requests[1],cursor,6,.002)
local after=0;for _,n in pairs(sampled)do after=after+n end
assert(after==before,"Fresh samples must not be queried repeatedly")
visibilityEntries={};sampled={};fakeTime=200;sampleCost=.003
cursor=updateVisibilityBatch(requests,requests[1],0,6,.002)
assert(cursor==0 and sampled[1]==1 and not sampled[2],"Expensive priority must preserve fair cursor")
cursor=updateVisibilityBatch(requests,requests[1],cursor,6,.002)
assert(cursor==2 and sampled[2]==1,"Next batch must visit the unsampled player")
assert(updateVisibilityBatch({},nil,8,6,.002)==0)
os.clock=realClock
print("[PF_VISIBILITY_TEST] PASS: full script compiles; clear/blocked/incomplete/truncated/skipped/error/missing map cases; certified rebuild snapshots, visual hold/expiry, stale/moved aim rejection independent ESP colors and bounded/fair visibility batches")`;
const job=path.join(runtime,"pf-visibility-offline-test.json");fs.writeFileSync(job,JSON.stringify({source,maxMs:4000}));
try{const r=spawnSync(path.join(runtime,"JaelX.exe"),["--worker",job,"Local\\PFVisibilityOffline"],{encoding:"utf8",windowsHide:true,timeout:7000});assert.equal(r.status,0,r.stderr);const events=r.stdout.trim().split(/\r?\n/).filter(Boolean).map(x=>JSON.parse(x));const errors=events.filter(e=>e.level==="error");assert.equal(errors.length,0,errors.map(e=>e.text).join("\n"));const pass=events.find(e=>(e.text||"").startsWith("[PF_VISIBILITY_TEST] PASS"));assert(pass);console.log(pass.text);}finally{fs.rmSync(job,{force:true});}
