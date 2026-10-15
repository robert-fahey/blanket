# Blanket

A Persian rug for your Mac desktop. It lies on top of your icons, and you can
grab any part of it and pull. The fabric lifts, folds and slides like a real
rug, uncovering whatever you had been meaning to tidy up. Let go and it settles
where you left it, and it is still there after you quit and come back.

It does nothing useful. It is quite good at it.

## Install

Requires macOS 14 or newer and Xcode 15 or newer.

```bash
git clone https://github.com/robert-fahey/blanket.git
cd blanket
./Scripts/bundle.sh
open build/Blanket.app
```

For a development run without the bundle, use `swift run -c release`. Launch at
Login needs the bundle, so copy `build/Blanket.app` somewhere permanent such as
`/Applications` if you want that.

## Use

- **Drag** anywhere on the rug to pull it. A slow drag slides it along the desk,
  a quick one lifts and folds it.
- **Option-drag** grabs a whole handful of fabric instead of a single point.
- Clicks on bare desktop pass straight through to the Finder, so the rug never
  gets in the way of actual work. It sits above your desktop icons and below
  every application window, on every display.
- The menu bar item (a small filled rectangle) offers:
  - Reset Rug, also Control-Option-Command-R from anywhere
  - Hide Rug / Show Rug
  - Rug: four built-in designs (Tabriz, Heriz, Kashan, Nain), or any image of
    your own via Use Image
  - Size: Small, Medium, Large
  - Launch at Login
  - Quit

Your choices, the rug's shape and whether it is hidden are remembered between
launches.

## How it works

- `OverlayWindow` is a borderless, transparent, non-activating panel placed one
  level above the Finder's desktop-icon layer. A 30 Hz cursor poll makes the
  window click-through wherever there is no fabric under the pointer.
- `ClothSimulation` is a position-based-dynamics cloth with structural, shear,
  bend and long-range constraints, lying on the z = 0 plane with gravity, floor
  collision and friction. Constraints resist stretching fully and compression
  weakly, so the rug buckles instead of fighting itself. An approximate
  self-collision keeps folded layers stacked. The cloth sleeps when nothing
  moves, and rendering pauses with it, so the idle cost is close to zero.
- `RugView` is a SceneKit view with a transparent background and a mild
  perspective camera looking straight down, placed so the desk plane maps 1:1
  to screen points. The mesh, its pale underside, the bound edge, the fringe and
  a sheared floor shadow are rebuilt from the simulation every frame.
- The rug patterns and the weave normal map are generated with Core Graphics at
  launch. There are no image assets, and no medallions were harmed.

## Development

Set `BLANKET_SNAPSHOT_DIR=/some/dir` before launching to run a scripted pull
(single and wide grabs), save snapshots of the rug at each stage, print stretch
and timing figures, and quit. With `BLANKET_SNAPSHOT_MODE=rest` it only captures
whatever state was restored. `BLANKET_STYLE=nain` and `BLANKET_IMAGE=/path` force
a design or image for that run. This is how rendering and physics are checked
without screen recording.

Tuning knobs live at the top of `Sources/Blanket/Cloth/ClothSimulation.swift`
(gravity, friction, damping, substeps, stacking, sleep) and in
`Sources/Blanket/RugView.swift` (lift height, light direction, camera).

## Limitations

- No true self-collision, only vertical stacking of overlapping layers. A fold
  can still slide through another one sideways. Nobody has complained.
- The underside of a custom image is the same image, faded. Real rugs are less
  photogenic from below too.

## License

MIT
