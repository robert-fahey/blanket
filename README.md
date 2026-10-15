# Blanket

A Persian rug for your Mac desktop. It lies on top of your icons, and you can
grab any part of it and pull. The fabric lifts, folds and slides like a real
rug, uncovering whatever you had been meaning to tidy up. Let go and it settles
where you left it.

It does nothing useful. It is quite good at it.

## Install

Requires macOS 14 or newer and Xcode 15 or newer.

```bash
git clone https://github.com/robert-fahey/blanket.git
cd blanket
./Scripts/bundle.sh
open build/Blanket.app
```

For a development run without the bundle, use `swift run -c release`.

## Use

- Drag anywhere on the rug to pull it. Clicks on bare desktop pass straight
  through to the Finder, so the rug never gets in the way of actual work.
- The rug sits above your desktop icons and below every application window.
- The menu bar item (a small filled rectangle) offers Reset Rug, Hide Rug and
  Quit. There is no Dock icon.

## How it works

- `OverlayWindow` is a borderless, transparent, non-activating panel placed one
  level above the Finder's desktop-icon layer. A 30 Hz cursor poll makes the
  window click-through wherever there is no fabric under the pointer.
- `ClothSimulation` is a position-based-dynamics cloth with structural, shear
  and bend constraints, lying on the z = 0 plane with gravity, floor collision
  and friction. It sleeps when nothing moves, and rendering pauses with it, so
  the idle cost is close to zero.
- `RugView` is a SceneKit view with a transparent background and an
  orthographic camera looking straight down, so one world unit is one screen
  point. The mesh is rebuilt from the simulation every frame. A sheared copy of
  it, flattened onto the desk, serves as the shadow.
- The rug pattern and the weave normal map are generated with Core Graphics at
  launch. There are no image assets, and no two medallions were harmed.

## Development

Set `BLANKET_SNAPSHOT_DIR=/some/dir` before launching to run a scripted pull,
save snapshots of the rug at rest, mid-pull, released and reset, print a short
per-frame profile, and quit. This is how rendering and physics are checked
without screen recording.

Tuning knobs live at the top of `Sources/Blanket/Cloth/ClothSimulation.swift`
(gravity, friction, damping, substeps) and in `Sources/Blanket/RugView.swift`
(lift height, light direction).

## Limitations

- Main display only.
- The underside of the rug shows the same pattern as the top. Real rugs are
  less photogenic from below.
- No self-collision, so a fold can pass through itself. Nobody has complained.

## License

MIT
