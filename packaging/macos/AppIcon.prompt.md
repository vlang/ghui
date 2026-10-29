# App icon generation

Generated with the built-in `image_gen` tool and `transparent_background: true`.
The source asset is `AppIcon.png`. `make app` builds a multi-resolution
`AppIcon.icns` from this PNG with `scripts/build-app-icon.sh` and packages it in
`Github.app/Contents/Resources`.

## Final prompt

```text
Use case: logo-brand
Asset type: macOS application icon for this repository's GitHub issue and pull request browser.
Primary request: Generate a polished app logo featuring exactly one uppercase letter G.
Scene/backdrop: A single charcoal rounded-square app-icon tile, with genuinely transparent pixels outside the tile.
Subject: One large, bold white geometric sans-serif uppercase G, optically centered on the tile. Its open right side and horizontal crossbar must make it immediately recognizable as G.
Style/medium: Minimal, precise, vector-like bitmap logo, with crisp clean edges and a very subtle surface highlight on the charcoal tile.
Composition/framing: Square 1024 by 1024 canvas, front-facing icon without perspective. Rounded-square tile inset about 8 percent from every canvas edge. G occupies about 60 percent of the tile height. Generous balanced spacing and strong readability at 16 pixels.
Color palette: Existing app colors: charcoal #25292e, near-white #f6f8fa.
Text (verbatim): "G"
Constraints: One finished icon only. Transparent outer background. The tile is opaque. No border, no extra symbols, no other letters or words, no watermark, no device, no presentation mockup.
```
