# Phantom Forces / JoX

`pf-jox.lua` mirrors GitHub `examples/PhantomF.lua`. Requires **Jael X 1.31.5** Entity List and raycast support. The legacy `pf-chams-aim.lua` remains separate.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/TrollLexBR/Jael-X/main/examples/PhantomF.lua"))()
```

## Entity List ESP

All player overlays now use one `entities.new()` list, exposed as `shared.PF_ASSIST.entityList`. The PF adapter adds explicit descriptors because `Player.Character` is unavailable and body names are obfuscated. The existing roster loop reconciles models and removes entries on character replacement/removal. Failed pose reads clear their current-frame data instead of retaining old geometry. F4/End unloads the list, UI and all owned callbacks; re-execution stops the previous instance first.

The menu has separate **ESP**, **Chams**, **Boxes**, **Skeleton**, **Labels & health** and **Tracers** pages. ESP provides the master switch, allies, range, visibility colors and feature toggles. Each visual can follow team/visibility/selected-target colors or use its own custom color.

- Chams: Silhouette (default), Wireframe or Volumes; fill, opacity, outline/wire color, opacity and thickness. Silhouette unions projected part volumes and fills/outlines the character once.
- Boxes: full, corner, dashed or 3D; line color/opacity/thickness, border color/opacity/thickness, fill color/opacity, corner fraction and dash/gap length.
- Skeleton: color, opacity, thickness and optional border. The adapter links tagged head, identified torso and limb centers; it does not recover hidden engine joints. Missing torso/part poses omit their links.
- Labels: names, distance in studs, font, size, color, opacity, outline and offset.
- Health: side (left/right/bottom), foreground/background colors and opacities, width, offset and optional percentage text on the enabled bar. Only usable visible game nametag percentages are displayed. Missing/hidden/unreadable values produce no bar or fabricated HP.
- Tracers: top/center/bottom/mouse origin, top/center/bottom destination, custom color/opacity/thickness and optional border styling.

Existing stable `pf/*` flags are retained. Legacy JSON line thickness seeds new feature-specific thicknesses; legacy named-profile `pf/thickness` maps to the chams thickness control. Old body-bounds and per-script FPS flags are retired. Appearance still controls shared team/visibility colors, FOV/crosshair and runtime status. The existing aim and visibility scheduler remain separate from ESP rendering.

## Visibility and targeting

Aim visibility check and separate ESP visibility colors default on. Green means visible, red blocked, gray no usable result. Selected visible enemies use the target color. Team checks, range, sticky targets, target priority and configuration flags remain available.

**Aim at exposed body parts** defaults on. Head/Torso becomes the preferred part, rather than a requirement that rejects another exposed part. The adapter tests the head, torso and each discovered limb separately. **Probe partial peeks inside body parts** also defaults on: it adds six sample points inside each approximate volume (35% of its size on each local axis) to its center. A fresh clear preferred center wins immediately; otherwise a clear edge point on that part wins, followed by another exposed body part. The selected exact point drives mouse movement and the optional target line. Appearance displays the currently selected body-part identifier; obfuscated limbs retain stable `LimbN` identifiers.

Each part/sample has its own result. A clear arm ray never authorizes a blocked head. Adaptive aim accepts only a known positive sample less than 200 ms old, with camera displacement at most 0.25 studs and point displacement at most 0.15 studs. It checks the selected point's current screen position, FOV and range. Unreadable/missing poses, expired results and unknown map queries cannot authorize aim. If adaptive mode is disabled, legacy preferred-center targeting remains available with its original 2-stud movement tolerance. A retained green display cannot authorize aim. Display colors can retain a confirmed result for up to 3 seconds; fully blocked is reported only after all available part samples are confirmed blocked.

## Snapshot backend

Small scenes use native oriented-box rays. A certified completed native snapshot stays usable during its rebuild for up to 5 seconds, with current ray endpoints. Initial, skipped, truncated and unreadable data never proves clear. Thin readable colliders are tested separately rather than silently ignored.

Large scenes exceed native limits (8192 parts / 20000 traversal nodes). These use a numeric spatial grid assembled in small cooperative batches. Breadth-first child traversal avoids the `GetDescendants` hard limit and drops processed references. Boxes are assigned to intersected 64-stud cells; segment grid traversal tests only relevant boxes plus oversized objects. It preserves thin geometry and fails closed on unreadable parts.

The large-map spatial snapshot represents static map geometry until MapParts changes or Runtime > Rebuild visibility cache is clicked. Rebuild after moving/destructible geometry changes. Terrain and exact mesh/wedge/CSG silhouettes remain unsupported; visibility is approximate box intersection, not the game's engine depth buffer.

## Performance and memory

Rendering follows the Jael X overlay rate without a script FPS cap. Old `fpsCap` settings are ignored. The script leaves global app rendering/HDR settings unchanged. Runtime > Lightweight visibility batches defaults on: up to six ray queries per 16 ms worker interval, with a 2 ms cooperative time budget (normal mode: eight / 10 ms). One query can exceed that cooperative budget. Work is scheduled per entity, then rotates through that entity's point samples. The closest eligible aim candidate can use up to four priority queries per light batch; the useful clear point has a 40 ms refresh target and other points have an 80 ms refresh target. These are scheduling targets, not guaranteed complete-body scan latency. Fair/priority first turns alternate so one expensive query cannot permanently starve either group. Unknown points continue discovery. Fair progression advances only for visited requests. Actual latency depends on roster, sample count and query cost. Removed entity caches are pruned. Native raycast work and construction of body probe positions occur in the visibility worker, not the overlay callback. Historical large-map construction timings above remain unchanged; gray during the first build is expected.

One fresh native `entities.get_parts_snapshot()` batch feeds current poses to every ESP feature and targeting each render frame. Part dimensions are cached on discovery and corrected to approximate R6 volumes when PF reports near-zero sizes. Team/health metadata is sampled separately. The Entity List uses descriptor poses already read by the adapter; it does not reread them. Only screen elements retain independent Drawing objects. Style edits update existing feature handles. Label strings are rebuilt only when the name or rounded distance changes.

Runtime > **Lightweight bounds for names / boxes / bars / tracers** defaults on. When chams and skeleton are off, information ESP uses head/torso reads and one approximate body bound instead of six projected limb volumes. Turn it off for full part-derived bounds. Detailed reads remain enabled for full-body chams/skeleton and adaptive aim candidates near the FOV. Behind-camera/out-of-range ESP characters use coarse tracking, skip limb reads and produce no volume projections. Re-entering the viewport/FOV can take one frame to regain detailed limbs; every accepted aim point still requires a fresh current pose and ray. ESP and aim disabled means no native pose batch or body projection. Runtime reports requested part count and measured pose/adapter CPU milliseconds; these omit Entity List/native rendering, compositor and the game's FPS.

More visible characters with more enabled features still cost more than one character. These changes remove redundant work; they do not promise identical one-player and full-server frame rates.

Memory policy belongs to Jael X 1.31.4: Settings > General > Script memory limit (0.25–4 GB). The script no longer has its own budget slider or soft ceiling. It retains compact data, cooperative builds and garbage-collection steps; app worker/allocator limits govern the execution. Old `pf/memoryBudgetMB` flags in saved profiles are ignored.

## Verification

Offline checks compile the script and test native rebuild certification/expiry, thin OBB intersection, spatial obstruction/clear rays, visual cache expiry, movement/stale aim rejection, missing/invalid scenes. Live 1.31.2 validation on a large map completed a compact snapshot of 16443 parts with no unreadable geometry, avoiding the initial proxy-memory failure. Sampled steady spatial queries took approximately 0.06–0.10 ms and sampled Lua usage was 16–26 MB; values depend on scene, UI and machine. A second live build using bounded child traversal and the 48 MB budget completed 27924 parts with zero unreadable geometry; the sampled query took 0.09 ms and Lua usage was about 31 MB. Aim input was disabled during diagnostics. These measurements are not a shader FPS benchmark.

Current offline regressions run the full hub with the actual JoX library and native Entity List in a private 1.31.5 development worker. They cover all ESP feature handles, UI setting changes, hidden health, failed and moving poses, ally/master toggles, respawn/removal and two clean lifecycle cycles. Partial-cover fixtures verify a head-top point with a blocked head center, arm-only exposure, unknown/stale/moved samples, FOV/range and expensive-query fairness. The full hub's actual visibility worker also selects head/arm peek points with a mocked map reader and disabled native input. A fully exposed head needs one target-point projection, rather than projecting every probe.

A 60-character fixture verifies one pose batch per frame and 60 silhouette commands. Information-only mode reduces requested parts from 360 to 120 and projected volumes from 360 to 60. One visible character and 59 behind the camera requests 124 parts and projects just the visible body's volumes. Disabled ESP/aim does zero pose/projection work. All game/input access is mocked; these counts are not live gameplay, shader timings or FPS measurements.

Run the checked-in tests with `JAELX_TEST_ROOT` set to a private Jael X 1.31.5 development fixture:

```text
node --test tests/phantom-entities.cjs tests/phantom-visibility.cjs tests/phantom-peek.cjs
```

Visibility scheduler regression tests cover every player in an even-sized roster with a priority target, avoid re-querying fresh results, and preserve the fair cursor when one expensive query exhausts the time budget. This fixes the previous held-aim slot starvation. ESP still checks the selected head/torso point and uses approximate map boxes; scheduler improvements do not remove geometric false occlusion.


## 2026-10-09: environment controls and viewmodel safeguard

- Environment tab: Full bright and Custom ambient color, with independent RGB controls. The custom color takes precedence over white ambient when both are enabled. Disabling Full bright restores brightness/shadows while the tint remains enabled; disabling both restores the original lighting.
- Viewmodel controls were prepared for arms, separate sleeves and the active equipped item, including material dropdowns. They are explicitly unavailable: the live renderer refresh detached the PF rig and Reset VM did not recover its visual. No working viewmodel customization is claimed. Native 1.31.26 rejects camera-model appearance writes as a regression safeguard.
- `pf-viewmodel-test.lua` is now a Lighting-only test by default (Full bright + pink tint). Camera model mutations are blocked. F4 restores and unloads. Existing mesh textures are retained; TextureID/SurfaceAppearance removal is unavailable.

### Restricted hand/equipped-item follow-up

The user identified the earlier successful hand/weapon test separately from the later sleeve regression. Fresh Jael X 1.31.24 tests reproduced a pink SkinTone mesh and cyan Neon equipped weapon with sleeves excluded, then restored their original appearance after 25 seconds. Color alone did not visibly recolor the tested hand; Color plus a material change to Neon did. This is a bounded live test, not validation across animations, all equipment or game updates.

The Viewmodel tab now targets only SkinTone in identified arm models and the uniquely identified equipped item. Sleeves, invisible Arm anchors and unidentified hand accessories remain untouched. Sleeve controls are removed; old sleeve configuration values are retained but cannot activate writes. Features still default OFF; new material defaults use the tested Neon path. Native capability checks remain mandatory: Jael X 1.31.26's camera safeguard rejects these writes, and that native guard has not been removed by this script update. Existing texture maps are retained.

### Separate sleeve diagnostics (not part of the hub)

`pf-sleeve-color-test.lua` changes only Color to pink. `pf-sleeve-material-test.lua` changes only Material to Neon and preserves Color. Run one at a time. Each targets one direct Sleeves MeshPart in a camera model with an Arm anchor, using `SleeveIndex=1` by default; change to 2 to test the other discovered sleeve separately. Discovery order does not identify left/right. Both restore after 20 seconds or F4, and skip restoration if the game replaced the part's parent or property value. They do not write transforms, joints, model parents or textures. Capability rejection is respected.

Ten private fixture cases passed for cleanup, F4, unsupported writes, game overrides and object replacement. These sleeve scripts have not been executed in the live game; they are diagnostics, not a verified fix for the earlier rig regression. A property assignment alone can remain visually cached, and the native renderer refresh still applies. The main hub continues to exclude sleeves.
