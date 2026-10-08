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

Queries use current camera and selected Head/Torso coordinates. Aim requires a positive point sample less than 200 ms old, with camera/target displacement at most 2 studs. A retained green display cannot authorize aim. Display colors may retain their last confirmed result for up to 3 seconds during an unavailable sample; new entities and expired samples stay gray.

## Snapshot backend

Small scenes use native oriented-box rays. A certified completed native snapshot stays usable during its rebuild for up to 5 seconds, with current ray endpoints. Initial, skipped, truncated and unreadable data never proves clear. Thin readable colliders are tested separately rather than silently ignored.

Large scenes exceed native limits (8192 parts / 20000 traversal nodes). These use a numeric spatial grid assembled in small cooperative batches. Breadth-first child traversal avoids the `GetDescendants` hard limit and drops processed references. Boxes are assigned to intersected 64-stud cells; segment grid traversal tests only relevant boxes plus oversized objects. It preserves thin geometry and fails closed on unreadable parts.

The large-map spatial snapshot represents static map geometry until MapParts changes or Runtime > Rebuild visibility cache is clicked. Rebuild after moving/destructible geometry changes. Terrain and exact mesh/wedge/CSG silhouettes remain unsupported; visibility is approximate box intersection, not the game's engine depth buffer.

## Performance and memory

Rendering follows the Jael X overlay rate without a script FPS cap. Old `fpsCap` settings are ignored. The script leaves global app rendering/HDR settings unchanged. Runtime > Lightweight visibility batches defaults on: up to six samples per 16 ms worker interval, with a 2 ms cooperative time budget and an 80 ms per-player refresh target (normal mode: eight / 10 ms / 50 ms). A single native query can exceed that cooperative budget. The closest valid aim candidate receives a 40 ms refresh target even when the aim key is released. Fair round-robin progression advances only for visited requests; priority work never consumes another player's slot. Actual latency depends on roster size and query cost. Out-of-range and team-excluded objects are not queried. Removed entity cache entries are pruned. No native raycast work runs inside the overlay render callback. Large-map initial construction can take around 15–20 seconds on the tested machine; gray during that first build is expected.

One fresh native `entities.get_parts_snapshot()` batch feeds current poses to every ESP feature and the existing targeting adapter each render frame. Part dimensions are cached on discovery and corrected to approximate R6 volumes when PF reports near-zero sizes. Team/health metadata is sampled separately. The Entity List uses descriptor poses already read by the adapter; it does not reread them. Only screen elements retain independent Drawing objects. Style handles are reconfigured after UI/profile changes, not recreated every frame.

Memory policy belongs to Jael X 1.31.4: Settings > General > Script memory limit (0.25–4 GB). The script no longer has its own budget slider or soft ceiling. It retains compact data, cooperative builds and garbage-collection steps; app worker/allocator limits govern the execution. Old `pf/memoryBudgetMB` flags in saved profiles are ignored.

## Verification

Offline checks compile the script and test native rebuild certification/expiry, thin OBB intersection, spatial obstruction/clear rays, visual cache expiry, movement/stale aim rejection, missing/invalid scenes. Live 1.31.2 validation on a large map completed a compact snapshot of 16443 parts with no unreadable geometry, avoiding the initial proxy-memory failure. Sampled steady spatial queries took approximately 0.06–0.10 ms and sampled Lua usage was 16–26 MB; values depend on scene, UI and machine. A second live build using bounded child traversal and the 48 MB budget completed 27924 parts with zero unreadable geometry; the sampled query took 0.09 ms and Lua usage was about 31 MB. Aim input was disabled during diagnostics. These measurements are not a shader FPS benchmark.

Current offline regressions run the full hub with the actual JoX library and native Entity List in a private 1.31.5 development worker. They cover all ESP feature handles, UI setting changes, hidden health, failed and moving poses, ally/master toggles, respawn/removal and two clean lifecycle cycles. A 60-character fixture verifies one pose batch per frame and 60 silhouette commands. All mouse/game access is mocked; these checks are not live gameplay or FPS measurements.

Run the checked-in tests with `JAELX_TEST_ROOT` set to a private Jael X 1.31.5 development fixture:

```text
node --test tests/phantom-entities.cjs tests/phantom-visibility.cjs
```

Visibility scheduler regression tests cover every player in an even-sized roster with a priority target, avoid re-querying fresh results, and preserve the fair cursor when one expensive query exhausts the time budget. This fixes the previous held-aim slot starvation. ESP still checks the selected head/torso point and uses approximate map boxes; scheduler improvements do not remove geometric false occlusion.
