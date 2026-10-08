# Phantom Forces / JoX

`pf-jox.lua` mirrors GitHub `examples/PhantomF.lua`. Requires Jael X 1.31.2 raycast support. The legacy `pf-chams-aim.lua` remains separate.

## Visibility and targeting

Aim visibility check and separate ESP visibility colors default on. Green means visible, red blocked, gray no usable result. Selected visible enemies use the target color. Team checks, range, sticky targets, target priority and configuration flags remain available.

Queries use current camera and selected Head/Torso coordinates. Aim requires a positive point sample less than 200 ms old, with camera/target displacement at most 2 studs. A retained green display cannot authorize aim. Display colors may retain their last confirmed result for up to 3 seconds during an unavailable sample; new entities and expired samples stay gray.

## Snapshot backend

Small scenes use native oriented-box rays. A certified completed native snapshot stays usable during its rebuild for up to 5 seconds, with current ray endpoints. Initial, skipped, truncated and unreadable data never proves clear. Thin readable colliders are tested separately rather than silently ignored.

Large scenes exceed native limits (8192 parts / 20000 traversal nodes). These use a numeric spatial grid assembled in small cooperative batches. Breadth-first child traversal avoids the `GetDescendants` hard limit and drops processed references. Boxes are assigned to intersected 64-stud cells; segment grid traversal tests only relevant boxes plus oversized objects. It preserves thin geometry and fails closed on unreadable parts.

The large-map spatial snapshot represents static map geometry until MapParts changes or Runtime > Rebuild visibility cache is clicked. Rebuild after moving/destructible geometry changes. Terrain and exact mesh/wedge/CSG silhouettes remain unsupported; visibility is approximate box intersection, not the game's engine depth buffer.

## Performance and memory

Rendering follows the Jael X overlay rate without a script FPS cap. Old `fpsCap` settings are ignored. The script leaves global app rendering/HDR settings unchanged. Runtime > Lightweight ray updates defaults on: roughly 25 ray samples/second, independent of player count. Aim-priority samples alternate with round-robin ESP updates. Out-of-range and team-excluded objects are not queried. Removed entity cache entries are pruned. No native raycast work runs inside the overlay render callback. Large-map initial construction can take around 15–20 seconds on the tested machine; gray during that first build is expected.

Body bounds is the default chams mode: one approximate body volume and one pose read per drawn entity instead of six limb volumes. Body parts remains available for individual limbs. Part dimensions are cached on character discovery. Team/health metadata is sampled separately from current positions. Retained drawings are hidden only when unused, and static styling/text is changed only when needed.

Memory policy belongs to Jael X 1.31.4: Settings > General > Script memory limit (0.25–4 GB). The script no longer has its own budget slider or soft ceiling. It retains compact data, cooperative builds and garbage-collection steps; app worker/allocator limits govern the execution. Old `pf/memoryBudgetMB` flags in saved profiles are ignored.

## Verification

Offline checks compile the script and test native rebuild certification/expiry, thin OBB intersection, spatial obstruction/clear rays, visual cache expiry, movement/stale aim rejection, missing/invalid scenes. Live 1.31.2 validation on a large map completed a compact snapshot of 16443 parts with no unreadable geometry, avoiding the initial proxy-memory failure. Sampled steady spatial queries took approximately 0.06–0.10 ms and sampled Lua usage was 16–26 MB; values depend on scene, UI and machine. A second live build using bounded child traversal and the 48 MB budget completed 27924 parts with zero unreadable geometry; the sampled query took 0.09 ms and Lua usage was about 31 MB. Aim input was disabled during diagnostics. These measurements are not a shader FPS benchmark.

Render regression checks cover one/six pose reads, zero per-frame size reads, persistent visibility without hide/show churn, detailed-to-bounds and corner-to-full-box switches, feature toggles and off-screen cleanup. The live finite smoke test confirmed uncapped callbacks at the app's configured 240 Hz with no script errors, but no character models were available during that sample; it is not a populated-scene performance comparison.
