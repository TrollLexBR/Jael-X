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
