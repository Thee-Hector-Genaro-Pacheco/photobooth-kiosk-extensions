# Halloween AR Asset Specification (Pacific Horizon Labs, Oct 3 2026)

Pure art/production specification. No runtime code was changed to produce
this document. It exists to let an artist (or Hector) produce the 13
outstanding PNGs without needing to read Swift.

Scope: measure the 6 existing, physically-proven AR assets and the exact
placement math that consumes them, then derive a precise spec for each of
the 13 new Halloween assets from that same math — so new art drops in and
looks right on the first try, rather than needing trial-and-error scale
tuning at the event.

---

## 1. How placement actually works (read this before designing anything)

Everything below follows from `EffectPlacementEngine.placement(for:face:geometry:assetPixelSize:)`
and how `EffectCompositor`/`EffectOverlayView` use its result. Three
mechanical facts drive every number in this document:

1. **Canvas aspect ratio *is* the rendered aspect ratio.** The engine only
   ever controls the rendered **width** directly (`scaleReference.length(in:face) * scaleFactor`).
   Rendered height is *derived*: `targetHeight = targetWidth * (assetPixelHeight / assetPixelWidth) * heightMultiplier`.
   There is no independent height control — the PNG's own canvas aspect
   ratio is the only lever for how tall an element renders relative to its
   width. Design each canvas at the aspect ratio you want on screen.

2. **`assetAnchor` is the pin point, not a crop/center convenience.** It's
   a normalized `(x, y)` point *within the asset's own canvas* that gets
   pinned to the computed face-anchor point (after `offsetAlongEyes`/
   `offsetAlongUp` are applied). Everything else in the canvas is
   positioned relative to that pin. E.g. Glasses pins near its optical
   center (0.50, 0.38); Crown pins at its own bottom edge (0.50, 1.00) so
   the crown's base sits at the forehead point and the crown rises above it.

3. **Reactive height *stretches* the whole image, it does not reveal a
   taller canvas.** `UIImage.draw(in:)` maps the entire source image into
   a `targetWidth × targetHeight` rectangle. When `reactiveHeight` raises
   `heightMultiplier` above 1.0, the already-drawn artwork is stretched
   taller (width stays fixed) — never cropped, never re-composited. Any
   reactive asset must be designed to still read correctly stretched
   anywhere across its configured `minScale…maxScale` range, not just at
   its "natural" 1.0 height.

Two more mechanical facts, useful for placement risk assessment:

4. **Z-order = array order**, per face. Later elements in an
   `EffectDefinition.elements` array draw on top of earlier ones. This is
   guaranteed correct *within one face's own stack*; across two different
   faces it follows `faces` array order, not real depth — see §7.

5. **Multi-face support is automatic and generic.** `EffectCompositor`/
   `EffectOverlayView` loop `for tracked in faces { for element in
   effect.elements { ... } }` — this is not per-effect code. Every effect
   in this pack inherits multi-face rendering for free, capped at
   `FaceTrackingProvider.maxTrackedFaces = 4`.

---

## 2. Existing proven assets — measured

Measured directly from the PNG files in `Assets.xcassets` (Pillow: canvas
size, alpha-channel bounding box, non-transparent pixel counts) and
cross-referenced against the exact `EffectElement` values in
`EffectCatalog.swift`. All 6 are `idiom: universal`, `scale: 1x`, single
PNG per imageset (no @2x/@3x) — this is the established convention new
assets should follow too (see §8).

### ar-glasses (`ar-glasses.imageset/glasses.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 1000 × 360 px |
| 2 | Aspect ratio | 2.778 (1000:360) |
| 3 | Transparent canvas | full 1000×360, alpha channel present |
| 4 | Alpha bbox | (30, 50) → (971, 311), i.e. 941×261 px |
| 5 | Canvas occupied (bbox area / canvas area) | 68.2% (actual non-transparent pixel coverage: 55.7%) |
| 6 | Centered? | Yes — bbox center offset from canvas center is (+0.1%, +0.1%), i.e. dead center |
| 7 | Anchor | `.eyesCenter` |
| 8 | scaleReference | `.interEyeDistance` |
| 9 | scaleFactor | 2.05 |
| 10 | offset | none (`offsetAlongEyes`/`offsetAlongUp` = 0) |
| 11 | Reactive scaling | No |

`assetAnchor` = (0.50, 0.38) — pinned slightly above true vertical center,
at roughly the bridge-of-nose/eye-line height within the artwork.

### ar-crown (`ar-crown.imageset/crown.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 800 × 480 px |
| 2 | Aspect ratio | 1.667 (800:480, i.e. 5:3) |
| 3 | Transparent canvas | full 800×480 |
| 4 | Alpha bbox | (86, 52) → (715, 480), i.e. 629×428 px |
| 5 | Canvas occupied | 70.1% bbox area (actual pixel coverage: 40.4% — crown silhouette is "peaky," lots of transparent gaps between points) |
| 6 | Centered? | Horizontally centered (+0.1%); vertically offset **+5.4%** downward — bbox extends all the way to the bottom edge (`lower = 480` = canvas height), confirming the crown's base touches the bottom of the canvas |
| 7 | Anchor | `.foreheadAnchor` |
| 8 | scaleReference | `.interEyeDistance` |
| 9 | scaleFactor | 2.40 |
| 10 | offset | none |
| 11 | Reactive scaling | No |

`assetAnchor` = (0.50, 1.00) — pinned at the **exact bottom edge** of the
canvas, confirming the design intent: the crown's base sits at the
forehead point, and the crown rises upward (away from the face) from
there, with the bottom of the canvas being the base, not the bounding-box
bottom.

### ar-mustache (`ar-mustache.imageset/mustache.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 600 × 200 px |
| 2 | Aspect ratio | 3.000 (600:200, i.e. 3:1) |
| 3 | Transparent canvas | full 600×200 |
| 4 | Alpha bbox | (42, 38) → (559, 136), i.e. 517×98 px |
| 5 | Canvas occupied | 42.2% bbox area (actual pixel coverage: 19.1% — thin, wide curls leave a lot of transparent canvas) |
| 6 | Centered? | Horizontally centered (+0.1%); vertically offset **−6.5%** (bbox sits above vertical center) |
| 7 | Anchor | `.noseAnchor` |
| 8 | scaleReference | `.interEyeDistance` |
| 9 | scaleFactor | 1.35 |
| 10 | offset | `offsetAlongUp: -0.35` (shifts the pin point down from the nose, toward the mouth — negative = away from "up the face") |
| 11 | Reactive scaling | No |

`assetAnchor` = (0.50, 0.15) — pinned near the **top** of the canvas
(where the mustache meets the base of the nose), with the bulk of the
artwork extending downward from that point. The `offsetAlongUp: -0.35`
then pushes that whole pinned point down to the correct spot below the
nostrils.

### ar-dog-ears (`ar-dog-ears.imageset/dog-ears.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 2172 × 724 px |
| 2 | Aspect ratio | 3.000 (2172:724, i.e. 3:1) |
| 3 | Transparent canvas | full 2172×724 |
| 4 | Alpha bbox | (49, 11) → (2166, 710), i.e. 2117×699 px |
| 5 | Canvas occupied | 94.1% bbox area (actual pixel coverage: 44.7%) |
| 6 | Centered? | Effectively centered (+1.0% w, −0.2% h) |
| 7 | Anchor | `.foreheadAnchor` |
| 8 | scaleReference | `.interEyeDistance` |
| 9 | scaleFactor | 2.50 |
| 10 | offset | `offsetAlongUp: 0.15` (shifts pin point up, further from the face, toward the top of the head) |
| 11 | Reactive scaling | No |

`assetAnchor` = (0.50, 0.75) — pinned three-quarters down the canvas
(near where the two ears' bases would meet the top of the head), with the
ears themselves rising into the top ~25% of the canvas above that point,
and open canvas space below for the head/hairline gap.

### ar-dog-muzzle (`ar-dog-muzzle.imageset/dog-muzzle.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 1536 × 1024 px |
| 2 | Aspect ratio | 1.500 (1536:1024, i.e. 3:2) |
| 3 | Transparent canvas | full 1536×1024 |
| 4 | Alpha bbox | (0, 20) → (1500, 1024), i.e. 1500×1004 px — touches the left, right, and bottom canvas edges |
| 5 | Canvas occupied | 95.7% bbox area (actual pixel coverage: 36.4%) |
| 6 | Centered? | Nearly centered (−1.2% w, +1.0% h) |
| 7 | Anchor | `.noseAnchor` |
| 8 | scaleReference | `.interEyeDistance` |
| 9 | scaleFactor | 1.40 |
| 10 | offset | `offsetAlongUp: -0.10` (small downward shift from the nose) |
| 11 | Reactive scaling | No |

`assetAnchor` = (0.50, 0.45) — pinned just above true center, at
approximately the muzzle's nose-bridge point.

**Z-order note:** in `EffectCatalog.playfulPup`, the array order is
`[ears, tongue, muzzle]` — **the muzzle is drawn last, on top of the
tongue.** This only works visually because the muzzle art must have an
open/transparent gap at the mouth position for the tongue to show through
underneath. This is the opposite ordering strategy from what the new
Halloween fangs/ember use (drawn *after*, i.e. *on top of*, their
muzzle/accent) — see §7.

### ar-dog-tongue (`ar-dog-tongue.imageset/dog-tongue.png`)

| # | Field | Value |
|---|---|---|
| 1 | Pixel dimensions | 1199 × 1312 px |
| 2 | Aspect ratio | 0.914 (1199:1312 — taller than wide) |
| 3 | Transparent canvas | full 1199×1312 |
| 4 | Alpha bbox | (0, 21) → (1193, 1312), i.e. 1193×1291 px — touches left, right, and bottom edges |
| 5 | Canvas occupied | 97.9% bbox area (actual pixel coverage: 44.5%) |
| 6 | Centered? | Nearly centered (−0.3% w, +0.8% h) |
| 7 | Anchor | `.mouthAnchor` |
| 8 | scaleReference | `.mouthWidth` |
| 9 | scaleFactor | 1.05 |
| 10 | offset | none |
| 11 | Reactive scaling | **Yes** — `EffectVisibilityRule(mouthOpenEquals: true)` (hidden when mouth closed) + `EffectReactiveHeight(inputMin: 0.18, inputMax: 0.42, minScale: 0.40, maxScale: 1.25)` |

`assetAnchor` = (0.50, 0.05) — pinned near the **top** of the canvas
(the point where the tongue attaches inside the mouth), with the tongue's
body extending down through the rest of the canvas. This is the
"attachment point stays fixed, body grows away from it" pattern — the
correct convention for any element that should look like it's *extending
from* a fixed point as `reactiveHeight` scales it (rather than growing
from its own center). **This is the physically-verified, already-shipped
reference for every new reactive asset in this pack** (werewolf fangs,
vampire fangs use the same (0.50, 0.05) convention below; devil ember
deliberately does not — see §7, item 2).

The min→max scale range here is 0.40→1.25 (a ~3.1× stretch across the
full range) and it already reads correctly on a physical device — this
is the calibration reference for how much vertical stretch tolerance is
acceptable for the new fang/ember assets.

---

## 3. Original-design requirements (recap, binding for all 13 assets)

No protected-IP names, silhouettes, or recognizable designs. Specifically
excluded: Ghostface/Scream, Michael Myers, Tinker Bell/Disney fairies, or
any other recognizable entertainment IP silhouette. Target aesthetic for
the whole pack: **premium Halloween** — polished, slightly cinematic,
high contrast, sophisticated, adult-party-appropriate. Not cartoon
clip-art, not children's-sticker style, not photorealistic gore.
Per-archetype color/material direction is restated exactly per effect in
§4 (unchanged from the phase brief — repeated here so this document is
self-contained for whoever produces the art).

---

## 4. Per-asset specification

Each entry gives: target canvas size/aspect, transparency requirement,
expected alpha bbox / visible-area %, orientation, conceptual anchor
position, safe padding, symmetry, overlap/z-order, the exact
`EffectCatalog.swift` entry that consumes it, and reactivity.

Canvas sizes below are **recommended production sizes**, not required
exact pixel counts — what's load-bearing is the **aspect ratio** and the
**normalized `assetAnchor` position** (§1, fact 1–2). Any resolution at
the same aspect ratio works; higher resolution only affects render
sharpness, never placement.

### Werewolf Rage (`werewolf-rage`) — dark charcoal/brown fur, warm amber highlights, ivory fangs, aggressive but premium

**ar-werewolf-ears**
- Target canvas: 2200×730 px (aspect ≈ 3.0:1) — matches `ar-dog-ears`' proven aspect ratio exactly, since it fills the same structural role (paired ears rising from a wide base, anchored at the forehead)
- Transparent background required
- Expected alpha bbox: ~90–95% of canvas (match `ar-dog-ears`' 94.1%) — ears should nearly fill the wide canvas, minimal dead margin left/right
- Orientation: upright, both ears visible side-by-side, symmetric pair in one image
- Anchor position: pin point at (0.50, 0.75) — three-quarters down the canvas, at the ears' base/hairline, mirroring `ar-dog-ears` exactly
- Safe padding: ~5–8% margin on all sides so nothing touches the canvas edge (avoids hard-clipped edges at max scale)
- Left/right symmetry: **matters** — single wide asset containing both ears (not two separate elements/files), same convention as Crown and Dog Ears; should read as a mirror-symmetric pair
- Overlaps: sits behind Brow and Muzzle (drawn first, array position 1 of 4)
- Z-order: **bottom** of the werewolf stack (drawn first)
- Consuming entry: `EffectCatalog.werewolfRage`, element 1 — anchor `.foreheadAnchor`, scaleReference `.interEyeDistance`, scaleFactor 2.50, offsetAlongUp 0.15
- Reacts to mouth state: No
- Multi-face: automatic, no special handling needed

**ar-werewolf-brow**
- Target canvas: ~900×410 px (aspect ≈ 2.2:1) — wide horizontal band across both brows
- Transparent background required
- Expected alpha bbox: ~60–70% of canvas (leave clear space above/below the brow line itself, similar proportion to Glasses' 68.2%)
- Orientation: upright, spans both eyes as one continuous brow/fur accent (not two separate brows)
- Anchor position: pin point at (0.50, 0.55) — just past vertical center, at the eye-line
- Safe padding: ~10% top/bottom, ~5% left/right
- Left/right symmetry: matters — single symmetric asset, same convention as Glasses
- Overlaps: sits behind Muzzle and Fangs (array position 2 of 4); sits on top of Ears only where they might overlap near the hairline (unlikely given anchor separation)
- Z-order: second from bottom
- Consuming entry: `EffectCatalog.werewolfRage`, element 2 — anchor `.eyesCenter`, scaleReference `.interEyeDistance`, scaleFactor 2.20, no offset
- Reacts to mouth state: No
- Multi-face: automatic

**ar-werewolf-muzzle**
- Target canvas: 1536×1024 px (aspect 1.5:1) — **recommend matching `ar-dog-muzzle`'s exact aspect ratio**, since this element reuses `ar-dog-muzzle`'s exact placement values (anchor, scaleFactor 1.40, offsetAlongUp −0.10) verbatim; a different aspect ratio will change the rendered proportions relative to what those values were tuned for (see §7, item 1 — flagged as a placement risk)
- Transparent background required
- Expected alpha bbox: ~90–95% of canvas, touching left/right/bottom edges (match `ar-dog-muzzle`'s 95.7%)
- Orientation: upright, wolf snout/jaw facing the viewer, nose bridge near vertical center
- Anchor position: pin point at (0.50, 0.45) — just above true center, at the nose bridge
- Safe padding: minimal (~0–2%) at bottom/sides (this asset is meant to extend to the canvas edges, matching the dog-muzzle precedent), ~5% at top
- Left/right symmetry: matters — single symmetric snout
- Overlaps: sits **behind** the reactive Fangs element (array position 3 of 4, fangs drawn after/on top)
- Z-order: third of four (below Fangs only)
- Consuming entry: `EffectCatalog.werewolfRage`, element 3 — anchor `.noseAnchor`, scaleReference `.interEyeDistance`, scaleFactor 1.40, offsetAlongUp −0.10
- Reacts to mouth state: No (this is the baseline "mouth closed: normal werewolf face" element)
- Multi-face: automatic

**ar-werewolf-fangs**
- Target canvas: recommend a taller-than-wide aspect similar to `ar-dog-tongue` (~0.9:1 to 1.0:1) — fangs/snarling mouth reads better tall than wide at this anchor convention
- Transparent background required
- Expected alpha bbox: ~90%+ (match `ar-dog-tongue`'s 97.9% — fangs art should fill nearly the whole canvas, since the canvas itself IS the visible-area budget at max stretch)
- Orientation: upright, fangs/open snarling mouth facing viewer, attachment edge (gumline) at the **top** of the canvas
- Anchor position: pin point at (0.50, 0.05) — near the top edge, exactly matching `ar-dog-tongue`'s proven convention (attachment point fixed, body extends down as it stretches)
- Safe padding: ~5% top margin above the gumline; minimal side/bottom padding (fill to edges like the tongue)
- Left/right symmetry: matters — fangs/snarl should be left-right symmetric or near-symmetric
- Overlaps: drawn **on top of** Muzzle (array position 4 of 4, last/topmost) — no cutout needed in the muzzle art, since fangs simply overlay it (front teeth sit in front of a closed jaw)
- Z-order: **top** of the werewolf stack
- Consuming entry: `EffectCatalog.werewolfRage`, element 4 — anchor `.mouthAnchor`, scaleReference `.mouthWidth`, scaleFactor 1.10, visibility `mouthOpenEquals: true`, reactiveHeight 0.18→0.42 mapped to 0.45×→1.30× (a ~2.9× stretch range — within the tongue's proven 3.1× tolerance)
- Reacts to mouth state: **Yes** — hidden entirely when mouth is closed; appears and vertically stretches taller as the mouth opens
- Multi-face: automatic

### Dark Vampire (`dark-vampire`) — elegant gothic, dark crimson, subtle silver, ivory fangs, not grotesque

**ar-vampire-eyes**
- Target canvas: ~900×400 px (aspect ≈ 2.2:1), similar proportions to Glasses/Werewolf-Brow
- Transparent background required
- Expected alpha bbox: ~50–65% of canvas — "subtle eye accents" per the brief implies a lighter, less canvas-filling treatment than the werewolf brow; leave generous transparent margin
- Orientation: upright, centered on both eyes as one asset
- Anchor position: pin point at (0.50, 0.50) — true center
- Safe padding: ~15–20% margin, generous, matching the "subtle" intent
- Left/right symmetry: matters — single symmetric asset
- Overlaps: none (only element besides Fangs)
- Z-order: bottom (array position 1 of 2, Fangs drawn after/on top)
- Consuming entry: `EffectCatalog.darkVampire`, element 1 — anchor `.eyesCenter`, scaleReference `.interEyeDistance`, scaleFactor 2.00, no offset
- Reacts to mouth state: No
- Multi-face: automatic

**ar-vampire-fangs**
- Target canvas: tall aspect similar to werewolf fangs / dog tongue (~0.9:1–1.0:1)
- Transparent background required
- Expected alpha bbox: ~90%+ (fill-to-edge convention, same as tongue/werewolf-fangs)
- Orientation: upright, elegant pair of fangs (not a full open-mouth snarl — brief calls for "elegant," "not grotesque"), attachment edge at top
- Anchor position: pin point at (0.50, 0.05) — top-anchored, same proven convention as tongue/werewolf-fangs
- Safe padding: ~5% top, minimal elsewhere
- Left/right symmetry: matters — symmetric fang pair
- Overlaps: drawn on top of Eyes (though they don't spatially overlap given different anchors — this is only an array-order note)
- Z-order: top (array position 2 of 2)
- Consuming entry: `EffectCatalog.darkVampire`, element 2 — anchor `.mouthAnchor`, scaleReference `.mouthWidth`, scaleFactor 0.90, visibility `mouthOpenEquals: true`, reactiveHeight 0.18→0.42 mapped to 0.40×→1.20× (~3.0× stretch range)
- Reacts to mouth state: **Yes** — appears/extends on mouth-open, primary expression trigger for this effect per the brief
- Multi-face: automatic

### Enchanted Pixie (`enchanted-pixie`) — luxury fantasy, emerald/teal/gold, luminous, elegant, original fairy archetype (face-focused v1, no wings/body tracking)

**ar-pixie-ears**
- Target canvas: ~2300×700 px (aspect ≈ 3.3:1) — similar structural role to Crown/Werewolf-Ears (wide asset spanning both sides, anchored at forehead)
- Transparent background required
- Expected alpha bbox: ~85–95% of canvas
- Orientation: upright, both elegant pointed ears visible, luminous gold/emerald/cyan accents per the brief's fantasy palette
- Anchor position: pin point at (0.50, 0.85) — lower than Werewolf-Ears'/Dog-Ears' 0.75, since `offsetAlongUp: 0.05` here is smaller than those elements' 0.15, meaning less of the canvas is expected to sit above the pin point relative to canvas height; keep most of the visible ear artwork in the canvas's lower ~30–40%
- Safe padding: ~5–8%
- Left/right symmetry: matters — single symmetric asset
- Overlaps: sits behind Glow and Sparkle (array position 1 of 3)
- Z-order: bottom of three
- Consuming entry: `EffectCatalog.enchantedPixie`, element 1 — anchor `.foreheadAnchor`, scaleReference `.interEyeDistance`, scaleFactor 2.60, offsetAlongUp 0.05
- Reacts to mouth state: No
- Multi-face: automatic

**ar-pixie-glow**
- Target canvas: ~900×450 px (aspect ≈ 2.0:1)
- Transparent background required
- Expected alpha bbox: ~50–60% — "luminous head/face accent" implies a soft glow/halo treatment, best with generous transparent falloff at the edges rather than a hard-edged shape
- Orientation: upright, centered, soft luminous treatment (consider a radial-glow style with soft alpha falloff rather than a hard silhouette)
- Anchor position: pin point at (0.50, 0.50) — true center
- Safe padding: ~15%+ (soft glow assets benefit from extra breathing room so falloff doesn't clip at canvas edge)
- Left/right symmetry: matters (symmetric glow)
- Overlaps: sits behind Sparkle, on top of Ears (array position 2 of 3)
- Z-order: middle of three
- Consuming entry: `EffectCatalog.enchantedPixie`, element 2 — anchor `.eyesCenter`, scaleReference `.interEyeDistance`, scaleFactor 2.10, no offset
- Reacts to mouth state: No
- Multi-face: automatic

**ar-pixie-sparkle**
- Target canvas: roughly square to slightly wide, ~700×600 px (aspect ≈ 1.15:1) — unlike the fang-style reactive elements, this is a burst/decoration, not an "extending" element, so no need for the tall tongue-style aspect
- Transparent background required
- Expected alpha bbox: ~40–55% — a sparkle/glitter burst naturally has scattered small shapes with lots of surrounding transparency, not a dense fill
- Orientation: centered burst pattern, no strong up/down directionality required
- Anchor position: pin point at (0.50, 0.50) — **center-anchored**, deliberately different from the fang/tongue top-anchor convention, because this element has **no `reactiveHeight`** (it only toggles visible/hidden via `EffectVisibilityRule`, it does not stretch) — center anchoring is correct and simpler here; there is no "fixed attachment point growing outward" behavior to preserve
- Safe padding: ~20%+ margin so the scattered sparkle shapes don't touch canvas edges
- Left/right symmetry: doesn't need to matter — an asymmetric/organic sparkle scatter is fine and arguably more natural
- Overlaps: drawn on top of Glow and Ears (array position 3 of 3, topmost)
- Z-order: top of three
- Consuming entry: `EffectCatalog.enchantedPixie`, element 3 — anchor `.mouthAnchor`, scaleReference `.mouthWidth`, scaleFactor 1.60, visibility `mouthOpenEquals: true`, **no reactiveHeight**
- Reacts to mouth state: **Yes**, but only appear/disappear (no size stretch) — appears when mouth opens (smile/gasp), disappears when closed
- Multi-face: automatic
- Capture note: this effect's `capturePreference` is `.either` — as a still, whatever the guest's mouth state is *at the exact capture instant* determines whether the sparkle shows; there's no way to guarantee it appears in a still unless the guest happens to have their mouth open when the shutter fires (this is inherent to `.either` + a visibility-gated element, not something to fix here)

### Phantom Slasher (`phantom-slasher`) — original asymmetric pale horror mask, weathered/cracked, dark cavities, no recognizable movie-mask silhouette

**ar-phantom-mask**
- Target canvas: this is the **highest-risk placement guess in the entire pack** (see §7, item 3) — recommend ~1100×1500 px (aspect ≈ 0.73:1, taller than wide) so that at `scaleFactor: 3.00` from `.interEyeDistance`, the rendered height reaches from roughly the brow line down past the chin. **Prototype this early with a rough placeholder shape before committing final linework** (see §5)
- Transparent background required
- Expected alpha bbox: ~75–85% of canvas — full-face masks (unlike accent elements) should have a dense, mostly-filled silhouette, but keep some margin so the mask doesn't look like it's bleeding off its own canvas independent of face placement
- Orientation: upright, front-facing full mask; **asymmetric by design** per the brief (e.g. one side more damaged/cracked than the other) — asymmetry is a feature here, not a placement concern, since this is a single element with no left/right pairing logic involved
- Anchor position: pin point at (0.50, 0.42) — slightly above vertical center, roughly at eye level within the mask artwork (mirrors Glasses' similar (0.50, 0.38) convention, adjusted slightly lower since this mask needs to extend further down to the chin than glasses do)
- Safe padding: ~8–10% on all sides
- Left/right symmetry: **does not matter** — asymmetry is intentional per the design brief
- Overlaps: none (only element in this effect)
- Z-order: n/a (single element)
- Consuming entry: `EffectCatalog.phantomSlasher`, element 1 — anchor `.eyesCenter`, scaleReference `.interEyeDistance`, scaleFactor 3.00, no offset
- Reacts to mouth state: No — static by design, meant to read well as a still
- Multi-face: automatic

### Devil Mode (`devil-mode`) — dark crimson/black, subtle ember orange, sleek horns, stylized rather than cartoonish

**ar-devil-horns**
- Target canvas: ~950×500 px (aspect ≈ 1.9:1) — sleeker/narrower proportion than Crown's 1.667 or Werewolf-Ears' 3.0, matching the brief's "sleek horns" direction (less wide-spread than fur ears, more vertically pronounced)
- Transparent background required
- Expected alpha bbox: ~75–85% of canvas
- Orientation: upright, pair of sleek horns rising from the canvas, base near the bottom
- Anchor position: pin point at (0.50, 0.80) — between Crown's bottom-edge (1.00) and Werewolf-Ears'/Dog-Ears' 0.75 convention, since `offsetAlongUp: 0.10` here is smaller than Werewolf-Ears'/Dog-Ears' 0.15
- Safe padding: ~5–8%
- Left/right symmetry: matters — single symmetric pair
- Overlaps: sits behind Accent and Ember (array position 1 of 3)
- Z-order: bottom of three
- Consuming entry: `EffectCatalog.devilMode`, element 1 — anchor `.foreheadAnchor`, scaleReference `.interEyeDistance`, scaleFactor 2.30, offsetAlongUp 0.10
- Reacts to mouth state: No
- Multi-face: automatic

**ar-devil-accent**
- Target canvas: ~900×450 px (aspect ≈ 2.0:1)
- Transparent background required
- Expected alpha bbox: ~55–65%
- Orientation: upright, centered brow/eye accent (covers the "facial accent elements" and "optional eye effect" requirements from the brief as one combined asset)
- Anchor position: pin point at (0.50, 0.50) — center
- Safe padding: ~12–15%
- Left/right symmetry: matters
- Overlaps: sits behind Ember, on top of Horns (array position 2 of 3)
- Z-order: middle of three
- Consuming entry: `EffectCatalog.devilMode`, element 2 — anchor `.eyesCenter`, scaleReference `.interEyeDistance`, scaleFactor 2.00, no offset
- Reacts to mouth state: No
- Multi-face: automatic

**ar-devil-ember**
- Target canvas: roughly square, ~700×650 px (aspect ≈ 1.08:1)
- Transparent background required
- Expected alpha bbox: ~50–65%
- Orientation: centered ember/flame-lick burst, no strong directionality required
- Anchor position: pin point at (0.50, 0.50) — **center-anchored, and this is a flagged design choice, not a direct copy of the tongue/fangs convention** (see §7, item 2): because this element *does* have `reactiveHeight` (unlike Pixie Sparkle), center-anchoring means the artwork will grow symmetrically in both directions from center as the mouth opens, rather than extending downward/outward from a fixed attachment edge the way the tongue and fangs do. Recommend evaluating both anchor conventions once art exists — if it should instead "flare up from the mouth" rather than "grow from a fixed center," change `assetAnchor` to (0.50, 0.05) or similar to match the proven tongue/fangs pattern (this would be a placement-value change, not an art change)
- Safe padding: ~15%+
- Left/right symmetry: doesn't need to matter (organic flame shapes read fine asymmetric)
- Overlaps: drawn on top of Accent and Horns (array position 3 of 3, topmost)
- Z-order: top of three
- Consuming entry: `EffectCatalog.devilMode`, element 3 — anchor `.mouthAnchor`, scaleReference `.mouthWidth`, scaleFactor 1.20, visibility `mouthOpenEquals: true`, reactiveHeight 0.18→0.42 mapped to 0.50×→1.35× (~2.7× stretch range, within tolerance)
- Reacts to mouth state: **Yes** — intensifies (scales up) on mouth-open, per the brief's "may intensify an ember/flame accent" request, implemented as a simple scale reaction rather than any new particle system
- Multi-face: automatic

### Playful Pup — unchanged, added to the pack by ID only

No new asset work. `ar-dog-ears`, `ar-dog-tongue`, `ar-dog-muzzle` are
already final, physically-verified production assets. Nothing about this
effect's placement, capture behavior, or artwork changes for pack
inclusion.

---

## 5. Recommended creation order

1. **`ar-phantom-mask`** first — it's the highest-risk placement guess
   (§7, item 3) and the only asset with no directly analogous proven
   precedent in this codebase (nothing existing attempts full-face
   coverage). Rough out a simple shape early and test on-device before
   investing in final linework, so the `scaleFactor`/`assetAnchor`
   guesses in this doc can be corrected cheaply if wrong.
2. **`ar-werewolf-fangs`, `ar-vampire-fangs`** next — these directly
   reuse the proven `ar-dog-tongue` anchor/stretch convention, so they're
   lowest-risk to validate the reactive-scaling pipeline still looks right
   with new art, and they're the primary "wow" moment for their effects.
3. **`ar-devil-ember`** — resolve the anchor-convention question from §7
   item 2 (center vs. top-anchored) before finalizing this one, since it
   affects whether the final art should be designed for "grows from
   center" or "flares from a fixed point."
4. **Static baseline elements** (`ar-werewolf-ears`, `ar-werewolf-brow`,
   `ar-werewolf-muzzle`, `ar-vampire-eyes`, `ar-devil-horns`,
   `ar-devil-accent`) — straightforward, no reactive-scaling risk, can be
   produced in parallel once the "does the silhouette read as intended"
   question is settled for one representative asset per archetype.
5. **`ar-pixie-ears`, `ar-pixie-glow`, `ar-pixie-sparkle`** last —
   Enchanted Pixie is `.either` (lower urgency than the `.loop`-default
   effects for the Loop-centric event experience) and its "luminous
   glow"/"sparkle" treatment likely needs the most iteration to get the
   premium-not-cartoon balance right.

## 6. Shared visual design language

- **Werewolf + Devil**: both use a "wide base element rising from the
  forehead" (ears / horns) at very similar scale factors (2.30–2.50) and
  a reactive mouth element with near-identical stretch ranges (2.7×–2.9×).
  These two can reasonably share a production pipeline/texture treatment
  (e.g. similar fur/leather material rendering, similar rim-lighting
  approach) even though their color palettes differ (charcoal/amber vs.
  crimson/ember).
- **Werewolf + Vampire**: both use the exact top-anchored (0.50, 0.05)
  fang convention directly copied from the proven tongue asset — these
  two fang assets should be produced together as a matched pair of
  "ivory fang" studies differing mainly in shape refinement (Werewolf =
  larger/more aggressive; Vampire = "elegant... not grotesque" per brief)
  and surrounding color treatment.
- **Pixie**: intentionally the outlier — the only effect using a
  luminous/glow treatment rather than solid silhouette work. Don't try to
  reuse the werewolf/vampire/devil production approach here.
- **Phantom**: also an outlier (single full-face element, no reactive
  component) — can be produced independently of the other four.

## 7. Placement risks flagged before artwork exists

1. **`ar-werewolf-muzzle` reuses `ar-dog-muzzle`'s exact placement
   numbers** (anchor, `assetAnchor` (0.50, 0.45), scaleFactor 1.40,
   offsetAlongUp −0.10) **verbatim**. This only produces correct on-screen
   proportions if the new asset is designed at the same 1.5:1 aspect ratio
   and with a similarly-proportioned "footprint" within its own canvas as
   `ar-dog-muzzle` (95.7% bbox fill, touching left/right/bottom edges). A
   werewolf snout drawn with notably different proportions (e.g. longer/
   narrower) will render at the wrong apparent size relative to the face
   until either the art or `EffectCatalog.swift`'s `scaleFactor` is
   adjusted. Not a code bug — a design-time coupling to be aware of.
2. **`ar-devil-ember` is center-anchored `(0.50, 0.50)` despite having
   `reactiveHeight`**, unlike every other reactive element in this pack
   (tongue, werewolf fangs, vampire fangs all use the top-anchored
   `(0.50, 0.05)` convention). Center-anchoring means the ember will grow
   symmetrically in both directions from its center as the mouth opens —
   including growing *upward*, into where the mouth/lips are — rather
   than appearing to emanate outward from the mouth the way the fangs and
   tongue do. This may or may not look correct once real art exists;
   verify visually and be prepared to change `assetAnchor` to `(0.50,
   0.05)` (a placement-value change, not an art change) if it doesn't.
3. **`ar-phantom-mask`'s `scaleFactor: 3.00` and `assetAnchor: (0.50,
   0.42)` are the least-validated numbers in this document.** Every other
   new asset either directly copies a proven element's placement values
   or is a straightforward variant of one (ears/horns, brow/accent,
   fangs/ember). Phantom Slasher is the only effect attempting full
   eyes-to-chin face coverage, and nothing existing in this codebase has
   ever done that — Glasses/Crown/Mustache/Dog-parts are all deliberately
   partial-face accents. Treat this specific number pair as a first
   estimate to be corrected after a real on-device test with placeholder
   art, not a final value.
4. **Cross-face z-order is not guaranteed for close/overlapping faces.**
   `EffectCompositor`/`EffectOverlayView` draw one face's entire element
   stack, then the next face's, in `faces` array order — not by actual
   depth/distance. For two guests standing far apart this is invisible;
   for two guests very close together (e.g. cheek-to-cheek), one
   person's topmost element (fangs/horns/ember) could still render
   *under* another person's bottommost element if array order works out
   that way. This is a pre-existing characteristic of the shared
   compositor (Playful Pup already has it), not something introduced by
   this pack — flagged per the phase brief's explicit request to report
   rather than silently risk corrupting placement.

## 8. Where finished art goes

Each PNG follows the exact existing convention (`Assets.xcassets/<name>.imageset/`,
one `Contents.json` + one PNG, `idiom: universal`, `scale: 1x` — see the
`ar-dog-tongue.imageset/Contents.json` example measured in §2):

| Asset name | Imageset path |
|---|---|
| `ar-werewolf-ears` | `Assets.xcassets/ar-werewolf-ears.imageset/` |
| `ar-werewolf-brow` | `Assets.xcassets/ar-werewolf-brow.imageset/` |
| `ar-werewolf-muzzle` | `Assets.xcassets/ar-werewolf-muzzle.imageset/` |
| `ar-werewolf-fangs` | `Assets.xcassets/ar-werewolf-fangs.imageset/` |
| `ar-vampire-eyes` | `Assets.xcassets/ar-vampire-eyes.imageset/` |
| `ar-vampire-fangs` | `Assets.xcassets/ar-vampire-fangs.imageset/` |
| `ar-pixie-ears` | `Assets.xcassets/ar-pixie-ears.imageset/` |
| `ar-pixie-glow` | `Assets.xcassets/ar-pixie-glow.imageset/` |
| `ar-pixie-sparkle` | `Assets.xcassets/ar-pixie-sparkle.imageset/` |
| `ar-phantom-mask` | `Assets.xcassets/ar-phantom-mask.imageset/` |
| `ar-devil-horns` | `Assets.xcassets/ar-devil-horns.imageset/` |
| `ar-devil-accent` | `Assets.xcassets/ar-devil-accent.imageset/` |
| `ar-devil-ember` | `Assets.xcassets/ar-devil-ember.imageset/` |

Each needs a `Contents.json` shaped exactly like the existing ones, e.g.:

```json
{
  "images" : [
    {
      "filename" : "werewolf-ears.png",
      "idiom" : "universal",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

No code change is required when the real PNGs are dropped in — `UIImage(named:)`
will pick them up automatically the next time the app builds, and the
`EffectCatalog.swift` entries already reference these exact names.
