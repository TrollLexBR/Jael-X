# Phantom Forces — Entity ESP update

## Partial visibility & performance

- Added exposed-part targeting with head preference and arm/leg fallback.
- Added partial-peek probes with fresh, point-specific wall checks.
- Reduced disabled, off-screen and information-only ESP work.
- Reused feature handles and cached labels; kept ray work in bounded batches.

Requires Jael X 1.31.5. Visibility uses approximate map/body volumes; results depend on the scene.

## Entity List migration

- Migrated player ESP to Jael X's Entity List with fresh batched poses.
- Added Silhouette chams, configurable boxes, skeletons, labels, health bars and tracers.
- Expanded ESP controls for colors, opacity, borders, thickness and styles.
- Preserved visibility checks and improved character cleanup on respawn.

Requires Jael X 1.31.5. Health is shown only when available; body volumes and skeleton links are approximate.


## 2026-10-09: environment controls and viewmodel safeguard

- Environment tab: Full bright and Custom ambient color, with independent RGB controls. The custom color takes precedence over white ambient when both are enabled. Disabling Full bright restores brightness/shadows while the tint remains enabled; disabling both restores the original lighting.
- Viewmodel controls were prepared for arms, separate sleeves and the active equipped item, including material dropdowns. They are explicitly unavailable: the live renderer refresh detached the PF rig and Reset VM did not recover its visual. No working viewmodel customization is claimed. Native 1.31.26 rejects camera-model appearance writes as a regression safeguard.
- `pf-viewmodel-test.lua` is now a Lighting-only test by default (Full bright + pink tint). Camera model mutations are blocked. F4 restores and unloads. Existing mesh textures are retained; TextureID/SurfaceAppearance removal is unavailable.

### Restricted appearance follow-up

- Re-enabled the capability-checked SkinTone/equipped-item path; excluded sleeves, arm anchors and unidentified hand accessories.
- Removed sleeve controls; preserved old configuration keys without applying them.
- Tested pink hand detail and cyan Neon weapon, followed by restoration, on Jael X 1.31.24. Native 1.31.26 still blocks camera appearance writes.
- Kept all appearance toggles OFF by default and preserved independent full-bright/ambient controls.
