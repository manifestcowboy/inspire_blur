import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:inspire_blur/src/child_blur/inspire_bounded_sampler.dart';
import 'package:inspire_blur/src/color_adjustment/blur_color_adjustment.dart';
import 'package:inspire_blur/src/distribution/distribution.dart';
import 'package:inspire_blur/src/inspire_blur_config.dart';
import 'package:inspire_blur/src/inspire_blur_mode.dart';
import 'package:inspire_blur/src/inspire_blur_wrapper.dart';
import 'package:inspire_blur/src/inspire_child_blur.dart';
import 'package:inspire_blur/src/inspire_shaders.dart';
import 'package:inspire_blur/src/model/aspect_ratio_correction.dart';
import 'package:inspire_blur/src/model/distribution_fit.dart';
import 'package:inspire_blur/src/model/inspire_blur_widget_type.dart';
import 'package:inspire_blur/src/opacity/widget_opacity.dart';
import 'package:inspire_blur/src/transform/blur_transform.dart';
import 'package:inspire_blur/src/utils/extensions/inspire_geometry_extensions.dart';

// ── BB27 · NEW FILE, not in pub 0.4.0. Vendor divergence 4. ──────────────────
//
// THE DEFECT (Reo, on his phone; measured in `_audit/dpr3/NUMBERS.md` §2a):
// `AnimatedSampler` rasterises the WHOLE subtree with `toImageSync` every frame
// and redraws it through the shader. The mask decides how much blur each ROW
// gets; it does NOT decide which rows are RESAMPLED — every row is, always. So
// content far BELOW the blur zone, where the mask is zero and the shader is a
// bit-for-bit pass-through, still comes back through a texture round trip:
// 76,620 px (4.13%) of the leaderboard below the zone differ by >2 from the
// blur-OFF build. That is the shimmer. `_audit/dpr3/NUMBERS.md` §2a also
// records that it is NOT a layout shift and NOT renderer-specific, so there is
// no geometry fix: a pixel stops shimmering only if it never enters an
// offscreen.
//
// BB25 (`_audit/dpr3/bb25/NUMBERS.md`) proved the composition that removes it —
// composite the real child directly below the band, overlay the shader only
// inside the band — and measured the shimmer at literal zero with the band
// byte-identical and no seam. It also measured 8.51 ms raster mean against the
// current ramp's 3.07, and tripped a debug `oldLayer` assert. BB27 is the same
// composition made affordable, and it differs from BB25 in exactly two ways:
//
//   1 · THE TEXTURE SHRINKS. BB25 clipped the CONTENT and still called
//       `toImageSync(w, FULL height)`, so it allocated, cleared and resolved
//       the same ~10 MB full-viewport targets. BB27 snapshots a WINDOW —
//       `band + ceil(3 * sigma) + 2` logical px, ~21% of the height on the
//       shipped ramp — and it collapses the package's two NESTED passes
//       (`inspire_child_blur.dart:103-124`, outer H wrapping inner V) into ONE
//       render object and ONE layer, which takes the per-frame `toImageSync`
//       count from BB25's three back to today's two. MEASURED in isolation
//       first (BB27 Gate 0, `_audit/dpr3/bb27/NUMBERS.md` §1): shrinking the
//       target alone moves BB25's 8.74 ms raster mean to 3.70 against a 2.73
//       control on the same rig. The texture WAS the cost.
//
//   2 · THE SNAPSHOT SCENE IS BUILT FIRST, THE REAL SCENE SECOND. `addToScene`
//       pushes with `oldLayer: _engineLayer`, so walking the child twice makes
//       the SECOND walk hand the FIRST walk's engine layers back as `oldLayer`,
//       flagging them; they live in whichever scene was built first. BB25 built
//       the real scene first, so the flagged layers sat in the REAL scene and
//       any ancestor `addRetained` — `RenderRepaintBoundary.toImage` — walked
//       into them and asserted, which is what six of `manifest_ui`'s ramp tests
//       caught. Built snapshot-first the flagged set is discarded with the
//       snapshot scene and the real scene carries the fresh one. MEASURED
//       (BB27 Gate 1): the same six tests go red -> green on that reordering
//       alone, in DEBUG, with the path ON.
//
// THE MASK IS BIT-IDENTICAL AND `inspire_blur_child.frag` IS NOT TOUCHED. The
// shader reads
//   uv_blur = (xy + u_delta_left_top) / (u_size + u_delta_left_top + u_delta_right_bottom)
// (`shaders/inspire_blur_child.frag:191`). With `u_size.y = windowH` and float 8
// (`u_delta_right_bottom.y`) set to `childH - windowH`, that is `xy.y / childH`
// — exactly today's lookup, same texel, same 8-bit Skia dithering. And
// `texel = 1 / u_size` (`:194`) keeps the kernel step at one LOGICAL px per tap
// in the smaller texture, so the kernel is unchanged too.
//
// GUARDS, because "the shader is a pass-through outside the band" is only true
// under conditions this widget can check. Any guard unmet falls back to the
// upstream `InspireChildBlur` composition, byte for byte:
//   · the band must be KNOWN — derived from the gradient map itself, the last
//     row whose red channel exceeds `_kMaskZeroFloor`, read once per image;
//   · the distribution transform must be identity, or `uv_blur` no longer maps
//     mask rows to child rows and "below the last non-zero row" means nothing;
//   · `colorAdjustment` must be inactive, or the shader is NOT a pass-through
//     outside the band (it applies `nonBlurAdjustmentStrength` there);
//   · both sigmas must be positive — this file implements the two-pass H+V
//     shape the ramp uses and nothing else.
//
// ── BB37 · THE BAND HAS TWO ANCHORS NOW, AND THE MASK PICKS WHICH ────────────
//
// Reo, 2026-08-31, on making this the shipped blur: "if you are using old
// inspire blur for dock, update it accordingly." `MnShaderFade`'s frosted
// footer runs the SAME `Inspire.childBlur` over the SAME scroll body with a
// mask that ramps from the BOTTOM, so it carries the identical shimmer defect
// over the ~85% of the child its band does not reach.
//
// THE DIRECTION IS NOT A PARAMETER. It is read off the gradient map, the same
// readback that already finds the band, by recording the FIRST non-zero row as
// well as the last:
//
//   first == 0, last < h-1   -> the band is anchored to the TOP    (the ramp)
//   last == h-1, first > 0   -> the band is anchored to the BOTTOM (the footer)
//   anything else            -> both edges blur, or neither: no window to
//                               shrink to, so fall back to upstream.
//
// A caller cannot get the anchor wrong because a caller does not state it, and
// a mask whose non-zero region touches BOTH edges (`MnShaderFadeEdge.both`)
// self-selects the upstream composition, which is the honest answer for it.
//
// EVERYTHING ELSE IS MIRRORED, NOT REWRITTEN. The window is the band plus the
// vertical kernel's reach on its INNER side (the outer side is the child's own
// edge, so there is nothing to reach into); the snapshot is translated so the
// texture's row 0 is the window's first row; the mask denominator is restored
// with `u_delta_left_top.y = windowTop` alongside the existing
// `u_delta_right_bottom.y = childHeight - windowTop - windowH`, which for a top
// band is `windowTop = 0` and therefore byte-identical to BB27; and the BB30
// partition is the same one coordinate through the same `pushClipRect` call,
// with the two half-open intervals swapped. `p19c_band_seam_test.dart` runs its
// two-sided predicate over BOTH anchors.
//
// See `project/vendor/README.md` divergence 4 and `_audit/dpr3/bb27/`.

/// Which edge of the child the band is anchored to. Derived from the gradient
/// map, never passed in — see the BB37 note above.
enum InspireBandAnchor { top, bottom }

/// How many times the band-sampler path has PAINTED. Read over the VM service
/// to prove the A/B switched something. Non-zero is the proof; the count itself
/// is one per frame per ramp and means nothing.
int debugInspireBandSamplerDraws = 0;

/// BB59 · `toImageSync` TARGETS ALLOCATED. This one's magnitude IS the point.
///
/// Every `addToScene` that produces a band picture allocates two of them
/// (`_snapshotWindow` + `_rasterise`), sized `dpr*width x dpr*windowH x 4` —
/// megabytes each on a phone. `dispose()` frees the DART HANDLE; the GPU
/// texture dies when the RASTER thread is done with it, so a producer that
/// outruns the raster thread turns a per-frame transient into unbounded
/// resident memory. The count per frame is therefore the thing that has to be
/// bounded, and `oomhunt_band_texture_budget_test.dart` bounds it.
int debugInspireBandSamplerTextures = 0;

/// CR-237 · DEVICE PIXELS of every `toImageSync` target counted by
/// [debugInspireBandSamplerTextures] (x4 for bytes). The count says how many
/// targets; this says how big they were.
int debugInspireBandSamplerTargetPixels = 0;

/// BB63 · `paint()` calls on the band sampler's RENDER OBJECT, across all of
/// them. The render object is a repaint boundary, so this counts the frames on
/// which the sampler's own subtree was re-painted — as opposed to
/// [debugInspireBandSamplerScenes], the frames on which its LAYER was walked.
///
/// The pair is the instrument that measured BB63's finding on macOS
/// (`test/probe/dust_probe.dart`, 3000 frames of sustained animation): per
/// frame, `scenes` = 3, productions = 2, `paints` = 1. Production is therefore
/// NOT gated on the sampled content having changed — it runs twice a frame
/// under any animation at all, including one whose only repaint is isolated in
/// a `RepaintBoundary` that lies outside both band windows.
int debugInspireBandSamplerPaints = 0;

/// BB63 · `addToScene` entries on the band sampler's LAYER, across all of them.
/// See [debugInspireBandSamplerPaints].
int debugInspireBandSamplerScenes = 0;

/// BB64 · band pictures actually RASTERISED (two `toImageSync` targets each).
/// The number the fix has to move; `debugInspireBandSamplerTextures` is this
/// times two.
int debugInspireBandSamplerProductions = 0;

/// BB64 · EXPLICIT `markNeedsAddToScene` calls on a band sampler layer — its
/// own property setters, plus any ancestor sampler's `_forceReAdd` walking over
/// it. It does NOT count the framework's own retention propagation
/// (`updateSubtreeNeedsAddToScene` writes the private flag directly), so the
/// pair `marks` vs `scenes` says which of the two dirtied us.
int debugInspireBandSamplerMarks = 0;

/// Band pictures served from [_InspireBandSamplerLayer]'s per-frame cache
/// instead of re-rasterised. Non-zero on any nested composition.
int debugInspireBandSamplerPictureReuse = 0;

/// BB65 · band pictures ADDED TO A SCENE — the last statement of the band
/// branch of `addToScene`, whether the picture was produced, reused, re-served
/// stale or skipped by the window-signature gate.
///
/// It is the layer-presence signal, and it is the one a "bounded by not
/// drawing" regression breaks: every `addToScene` that takes the band branch
/// must end with a band composited, so `composites == scenes` is the invariant
/// the backstop tests assert. A walk that does NOT re-add the layer at all
/// (Flutter's retained rendering, BB64) composites nothing here and needs
/// nothing: the retained engine layer still carries the band from the scene
/// that produced it — which is a scene this counter already covered.
int debugInspireBandSamplerComposites = 0;

// ── BB65 · THE WINDOW-SIGNATURE GATE, WITH A FORCED-REFRESH SAFETY VALVE ──
//
// WHAT BB64 LEFT OPEN, MEASURED. BB64 made a QUIET frame free: nothing dirty,
// nothing produced. It did nothing for a frame that is dirty SOMEWHERE ELSE,
// and that is the dust exit's exact shape — a 1250 ms mote animation inside a
// `RepaintBoundary` that lies BELOW both band windows. Flutter's dirty bit has
// no region: any repaint under this layer makes the layer dirty, `addToScene`
// runs, and it rasterises two window-sized targets for content the repaint
// never touched. MEASURED (`test/probe/dust_probe.dart`, MN_PROBE_ISOLATED=1,
// 600 frames, macOS debug, shipped composition): prod=1194, i.e. 2.0 per frame
// — the same rate as a full-slab repaint. Sentry MANIFEST-42 is a watchdog RAM
// kill during that window.
//
// THE GATE. Before producing, hash everything inside the band's WINDOW: the
// identity of every `PictureLayer.picture` whose transformed `canvasBounds`
// overlaps the window, plus the pixel-deciding props of the containers on the
// way down (offset / transform / opacity / clip). Same hash as the picture we
// already hold, same geometry => the band's pixels cannot have changed, so
// re-serve it. Everything the walk does not RECOGNISE — any layer type not in
// the list — makes the signature unknown and forces a production, so a new
// layer type in the tree costs performance and never correctness.
//
// AND THE VALVE, WHICH IS WHY THIS IS SAFE TO SHIP. `PictureLayer.canvasBounds`
// is the recorder's cull rect: an ESTIMATE, allowed to be larger than the ink
// and — the case that matters — not guaranteed tight. A bound that LIED small
// would let content inside the window change with the signature unmoved, and
// the band would freeze. So the gate may skip at most
// [kInspireBandWindowMaxSkips] CONSECUTIVE productions: every 4th dirty frame
// produces no matter what the signature says. Worst case under a lying bound is
// therefore a band at most 3 frames stale — 25 ms at 120 Hz, 50 ms at 60 —
// which is invisible; steady state during dust drops production 4x.
//
// Guarded by `test/oomhunt_band_window_gate_test.dart` (red-armed: raise the
// valve or delete the gate and the counts move).

/// Consecutive productions the signature gate may skip before one is FORCED.
/// 3 = produce on at least every 4th dirty frame.
const int kInspireBandWindowMaxSkips = 3;

/// Test-only: switch the gate OFF, so every dirty frame produces exactly as it
/// did before BB65. It exists so one process can render the same frames both
/// ways and compare the PIXELS —
/// `test/oomhunt_band_window_gate_test.dart` phase 4.
@visibleForTesting
bool debugInspireBandWindowGateDisabled = false;

/// MANIFEST C1 · float 26 of the fast program, which must be 1.0. The
/// identity checks set it ONE ULP above 1.0 (1.0000001192092896) to prove they
/// can see a defect that small: with it moved, the fast program's interior
/// weights are off by one ulp and its output must differ from the default
/// program's. It is a plain global, not test-only, so an on-device identity
/// check (the measurement line's profile-build self-test) can run that
/// sabotage arm. Nothing in the app sets it.
double debugInspireExactInteriorOneA = 1.0;

/// MANIFEST R · band pictures produced through the reduced-resolution split
/// (`reducedScale`). A harness checks it advanced, so a reduced arm that fell
/// back to today's passes cannot pass for one that ran. Counted in every build
/// mode; nothing reads it in the app.
int debugInspireBandSamplerReducedProductions = 0;

/// BB65 · productions skipped because nothing inside the band window changed.
int debugInspireBandSamplerWindowSkips = 0;

/// BB65 · productions the valve FORCED although the signature was unchanged —
/// the freeze-proofing, counted so a test can prove it fires.
int debugInspireBandSamplerForcedRefreshes = 0;

/// BB65 · which anchor's render object painted last. Pairs with
/// [debugInspireBandSamplerPaints]: a layer whose subtree is re-PAINTED every
/// frame re-records its pictures, so its window signature moves even when the
/// pixels do not.
String debugInspireBandSamplerPaintAnchor = '';

/// BB65 · why the LAST production happened, as `<anchor>:<reason>`:
/// `geometry` (size/dpr/band/painter changed — never gateable), `unknownSig`
/// (the walk met a layer type it does not recognise), `changed` (the window's
/// content really moved), `forced` (the valve fired on an unchanged window) or
/// `gateOff` (the walk was not consulted at all — [debugInspireBandWindowGateDisabled]).
/// The diagnostic for "why is this layer still producing every frame".
String debugInspireBandSamplerProduceReason = '';

/// BB65 · the last layer runtimeType the signature walk did not recognise, or
/// empty. A non-empty value means the gate is disengaged on this tree (it
/// produces every frame, as before) and names what to teach the walk.
String debugInspireBandSamplerWindowUnknown = '';

// ── BB60 · THE BOUNDED-QUEUE BACKSTOP ───────────────────────────────────
//
// 4c bounded production PER FRAME. It did not bound production BETWEEN frames,
// and on a cold start that gap is still lethal: the Metal pipeline cache is
// empty, the raster thread is at its slowest, and `toImageSync` is "created
// and returned synchronously, but rasterized asynchronously"
// (`dart:ui.Picture.toImageSync`) — the work is posted to the raster thread out
// of band, so nothing about the frame pipeline throttles it. Reo's iPhone 17
// Pro, plain release: every WARM launch now survives the playlist drag/swipe;
// the FIRST launch after install still took a SIGKILL on the first swipe.
//
// THE COMPLETION SIGNAL, AND THE TWO CANDIDATES THAT ARE WRONG.
//
//   · `ui.Image.dispose()` is not it. It releases the DART handle; the GPU
//     texture dies on the raster thread whenever it gets there. This layer
//     disposes both handles inside `addToScene`, so counting live handles
//     counts 2, always, however far behind raster is.
//
//   · `FrameTiming` is not it either, and this one looks right until you read
//     the contract: it IS a raster-completion report, but it is BATCHED — "the
//     timing of any frame will be sent within about 1 second (100ms if in the
//     profile/debug mode)" (`dart:ui.TimingsCallback`). At 120 Hz that is up to
//     ~120 frames of silence on a device that is keeping up perfectly, so any
//     bound small enough to be useful fires constantly on a healthy one. BUILT
//     AND MEASURED on the way here rather than reasoned about: against a
//     3-production bound it latched on inside ten healthy frames on this repo's
//     own rig. A backstop that engages while the consumer is fine is a
//     rendering defect, not a fix.
//
// SO THE DRAIN IS FLUTTER'S OWN BACKPRESSURE: THE FRAME STAMP ADVANCING. The
// engine's frame pipeline is two deep and the animator does not begin a frame
// while it is full, so a NEW frame stamp is proof the raster thread consumed
// one — with zero reporting latency, in release, in tests, on every platform.
// Productions are therefore counted PER FRAME STAMP, and the ones that can run
// away are the ones carrying no stamp at all: an `addToScene` driven out of
// band by an ancestor `RenderRepaintBoundary.toImage` (a post-frame callback,
// or a drag proxy capturing the subtree) is not throttled by the pipeline, and
// 4c deliberately never reuses on a null stamp because those callers need real
// pixels. That path had no ceiling. It has one now.
//
// WHAT THE BOUND COSTS WHEN IT ENGAGES: one band as old as the last production
// on this geometry, instead of an allocator kill. Nothing drawing at frame rate
// can reach it — a frame resets the count — so whatever does reach it is not
// landing on its own frame either.

// BB61 · THE BOUND ITSELF NOW LIVES IN `inspire_bounded_sampler.dart`, with the
// drain that enforces it ([InspireProductionBudget]), because the FALLBACK
// composition needs the same one and a second copy of a memory bound is a
// second thing to get out of step. `kInspireBandSamplerMaxOutstanding` keeps its
// name and its value — 3 productions per layer per stamp, at most six
// window-sized render targets outstanding here, against `2 x N` before.

/// Bands served STALE by the backstop (production ran past the bound against
/// one frame stamp). Zero on every normally-draining frame.
int debugInspireBandSamplerStaleBands = 0;

/// Every distinct outcome the band sampler has reached, comma-joined and
/// accumulated for the life of the process — an `ok` entry means the path ran.
///
/// A SET, not last-writer-wins, because more than one child blur can be mounted
/// at a time and a single global would report whichever built last.
///
/// DEBUG ONLY, and CAPPED. `_note` runs from `build`, so in a release build it
/// would re-join a growing set on every frame for a string nothing can read.
String debugInspireBandSamplerReasons = '';
final Set<String> _reasons = <String>{};

/// Enough to hold every guard plus a handful of distinct masks. Past it the
/// accumulate-and-join is O(n^2) in a per-frame path for no extra information —
/// the interesting entries are the first ones.
const int _kMaxReasons = 24;

void _note(String reason) {
  if (!kDebugMode) return;
  if (_reasons.length >= _kMaxReasons || !_reasons.add(reason)) return;
  debugInspireBandSamplerReasons = _reasons.join(',');
}

/// DEBUG-ONLY tripwire for GATE 1's ordering (see divergence 2 in the header):
/// `'snapshot,real'` after any frame the band path painted.
///
/// It exists because the six `oldLayer` ramp tests do NOT catch a reversal —
/// they were red on BB25's *structure* and stay green with these two walks
/// swapped. `p19b_mask_swap_no_flash_test.dart` asserts this string instead,
/// and reversing the two blocks in `addToScene` turns it red.
String debugInspireBandSamplerSceneOrder = '';

/// BB30 · DEBUG-ONLY geometry of the last band painted: the numbers a seam
/// investigation needs and cannot read any other way (`size`, `offset`, `band`,
/// `windowH`, `dpr`). Written on every `addToScene` that paints a band.
String debugInspireBandSamplerGeometry = '';

void _markScene(String name) {
  if (!kDebugMode) return;
  debugInspireBandSamplerSceneOrder =
      debugInspireBandSamplerSceneOrder.isEmpty
          ? name
          : '$debugInspireBandSamplerSceneOrder,$name';
}

/// The band this mask asks for: how deep it is as a fraction of the child's
/// height, and which edge it hangs off. Resolved once per mask image,
/// asynchronously.
@immutable
class InspireBandSpan {
  const InspireBandSpan(this.extent, this.anchor, {this.rowRed});

  /// Fraction of the child's height the band covers, measured from [anchor].
  final double extent;

  final InspireBandAnchor anchor;

  /// HEADER-BLUR-CUT · the mask's red value per ROW (the max over its
  /// columns), so the layer can size the snapshot window to the kernel the
  /// shader actually runs at the band's foot instead of the kernel at full
  /// sigma. Null = unknown, and the window keeps the full-sigma reach.
  final Uint8List? rowRed;

  @override
  String toString() =>
      'InspireBandSpan(${extent.toStringAsFixed(4)}, ${anchor.name})';
}

final Expando<InspireBandSpan> _bandSpan =
    Expando<InspireBandSpan>('inspireBandSpan');

/// Everyone waiting on ONE in-flight readback of the same mask.
///
/// Not a `bool` flag: a second sampler mounted on the same mask while the first
/// one's `toByteData` is in the air would take the early return, be handed no
/// `onResolved`, and sit on the fallback until something unrelated rebuilt it.
/// Cleared in a `finally`, so a readback that returns null is RETRIED on the
/// next frame instead of pinning a bogus extent for the life of the image.
final Expando<List<VoidCallback>> _bandWaiters =
    Expando<List<VoidCallback>>('inspireBandWaiters');

/// The mask's red channel never actually reaches 0 at its tail: it is 8-bit and
/// Skia DITHERS gradients, so the measured foot of `MnScrollRamp`'s 4x2048 ramp
/// reads `rMid=0` but `rLast=1` — one stray least-significant bit, 1400 rows
/// past where the curve hit zero. Scanning for `!= 0` therefore finds the very
/// last row and the band swallows the whole child.
///
/// So the floor is a NUMERICAL identity threshold, not a fudge: at red 2 the
/// shader's sigma is `2/255 * 14.667 = 0.115` LOGICAL px, and its first
/// off-centre tap carries weight `exp(-1 / (2 * 0.115^2)) = e^-37.8 ~ 4e-17`.
/// The centre tap is the entire kernel to sixteen decimal places, which is what
/// "the shader is a pass-through here" has to mean. At red 8 it would not be
/// (weight 0.09, a real if small blur), so this stays small.
const int _kMaskZeroFloor = 2;

/// Extra logical px of child the snapshot window carries PAST the band, so the
/// vertical kernel has real pixels to average at the band's foot instead of
/// transparent black. `3 * sigma` is the shader's own radius
/// (`inspire_blur_child.frag:224`); the +2 covers the two `_snap` roundings.
double inspireBandSamplerReach(double logicalSigmaVertical) =>
    (3.0 * logicalSigmaVertical).ceilToDouble() + 2.0;

/// The snapshot window's height in LOGICAL px: the band plus the vertical
/// kernel's reach, snapped to a whole device-pixel row and clamped to the
/// child.
///
/// Exported and unit-tested (`p19a_band_window_test.dart`) rather than inlined
/// in the layer, because it is the number the mask denominator is paired with:
/// the shader gets `u_size.y = windowH` and `u_delta_right_bottom.y =
/// childHeight - windowH`, and those two must be edited together or the fade
/// quietly re-maps. Shrink this and the test says so.
double inspireBandSamplerWindowHeight({
  required double band,
  required double logicalSigmaVertical,
  required double childHeight,
  required double devicePixelRatio,
}) {
  final double raw = band + inspireBandSamplerReach(logicalSigmaVertical);
  final double snapped =
      (raw * devicePixelRatio).roundToDouble() / devicePixelRatio;
  return snapped.clamp(0.0, childHeight);
}

// ── HEADER-BLUR-CUT · THE WINDOW IS THE KERNEL THE SHADER RUNS, NOT THE ONE ──
// ── IT WOULD RUN AT FULL SIGMA ───────────────────────────────────────────────
//
// [inspireBandSamplerWindowHeight] reaches `ceil(3 * sigma) + 2` past the band:
// the kernel at FULL sigma. The shader's radius is per FRAGMENT,
// `ceil(3 * sigma * blurFactor)` (`shaders/inspire_blur_child.frag:224`), and
// at the band's foot `blurFactor` is the mask's zero floor, so the rows that
// sit next to the band's edge reach ~1 px, not 44. The rows that do reach 44
// are at the TOP of the band, where 44 px of reach lands inside the band.
// MEASURED on the shipped header (zone 184, 393x852 at 3x): band 505 device
// rows, window 643 — 138 rows (0.16 MP a production) the vertical pass never
// read. `perf_header_blur_window_test.dart`.
//
// So the window ends at the furthest row ANY drawn fragment's kernel reads,
// taken from the mask itself, conservatively: each mask row is widened by one
// row each side (a bilinear lookup can blend a neighbour), its radius is
// rounded up, and the same `+ 2` snap slack as the full-sigma reach is kept.
// Never larger than the full-sigma window. Every texel the kernel reads is
// still in the texture, so the taps, their weights and their in-bounds masks
// are the ones the full window gave.

/// Test-only: size the window from the full-sigma reach again, so one process
/// can render the same frame both ways and compare the pixels.
@visibleForTesting
bool debugInspireBandTightWindowDisabled = false;

/// The snapshot window's height in LOGICAL px, sized to the kernels the shader
/// actually runs on the drawn rows: the furthest row read from the band's
/// anchor edge by any fragment in `[0, drawExtent)` (also measured from that
/// edge), plus the `+ 2` snap slack, snapped UP to a device row, and never
/// more than [inspireBandSamplerWindowHeight]'s full-sigma window.
///
/// [rowRed] is the mask's red per row, ordered from the top of the child;
/// [anchor] says which end the band hangs off.
double inspireBandSamplerTightWindowHeight({
  required Uint8List rowRed,
  required InspireBandAnchor anchor,
  required double band,
  required double drawExtent,
  required double logicalSigmaVertical,
  required double childHeight,
  required double devicePixelRatio,
}) {
  final double full = inspireBandSamplerWindowHeight(
    band: band,
    logicalSigmaVertical: logicalSigmaVertical,
    childHeight: childHeight,
    devicePixelRatio: devicePixelRatio,
  );
  final int rows = rowRed.length;
  if (rows == 0 || childHeight <= 0.0 || devicePixelRatio <= 0.0) return full;
  final double rowH = childHeight / rows;
  double reach = drawExtent;
  for (int k = 0; k < rows; k++) {
    // Distance from the anchor edge of mask row k, widened a row each side.
    final double lo = (k - 1) * rowH;
    if (lo >= drawExtent) break;
    final int red =
        rowRed[anchor == InspireBandAnchor.top ? k : rows - 1 - k];
    final double hi = math.min((k + 2) * rowH, drawExtent);
    final double radius =
        (3.0 * logicalSigmaVertical * red / 255.0).ceilToDouble();
    if (hi + radius > reach) reach = hi + radius;
  }
  final double tight =
      ((reach + 2.0) * devicePixelRatio).ceilToDouble() / devicePixelRatio;
  return math.min(tight, full).clamp(0.0, childHeight);
}

Future<void> _resolveBandSpan(ui.Image mask, VoidCallback onResolved) async {
  final List<VoidCallback>? inFlight = _bandWaiters[mask];
  if (inFlight != null) {
    inFlight.add(onResolved);
    return;
  }
  final List<VoidCallback> waiters = <VoidCallback>[onResolved];
  _bandWaiters[mask] = waiters;

  ByteData? data;
  try {
    data = await mask.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    _bandWaiters[mask] = null;
  }
  if (data == null) {
    // No extent recorded, so the next frame asks again. Pinning 1.0 here
    // (which reads as "the band is the whole child") retired the band path
    // permanently on one transient readback failure.
    _note('mask readback returned null');
    for (final VoidCallback cb in waiters) {
      cb();
    }
    return;
  }
  final Uint8List bytes = data.buffer.asUint8List();
  final int w = mask.width;
  final int h = mask.height;

  // BB37 · BOTH ends, because the pair is what names the anchor. A row counts
  // as blurring if ANY column in it does: the guarantee this widget trades on
  // is "outside the band the shader is a pass-through", and a conservative
  // superset of the blurring rows is the only reading of a mask that could
  // vary horizontally which keeps that true.
  int firstNonZeroRow = -1;
  int lastNonZeroRow = -1;
  final Uint8List rowRed = Uint8List(h);
  for (int y = 0; y < h; y++) {
    final int rowStart = y * w * 4;
    int maxRed = 0;
    for (int x = 0; x < w; x++) {
      final int red = bytes[rowStart + x * 4];
      if (red > maxRed) maxRed = red;
    }
    rowRed[y] = maxRed;
    if (maxRed > _kMaskZeroFloor) {
      if (firstNonZeroRow < 0) firstNonZeroRow = y;
      lastNonZeroRow = y;
    }
  }

  // Anchored to the edge it actually touches. Touching BOTH (or neither) is
  // not a band — there is no contiguous region of the child to composite
  // untouched — so no span is recorded and the widget falls back.
  if (firstNonZeroRow == 0 && lastNonZeroRow >= 0 && lastNonZeroRow < h - 1) {
    _bandSpan[mask] = InspireBandSpan(
        (lastNonZeroRow + 1) / h, InspireBandAnchor.top,
        rowRed: rowRed);
  } else if (lastNonZeroRow == h - 1 && firstNonZeroRow > 0) {
    _bandSpan[mask] = InspireBandSpan(
        (h - firstNonZeroRow) / h, InspireBandAnchor.bottom,
        rowRed: rowRed);
  } else {
    _bandSpan[mask] =
        const InspireBandSpan(0.0, InspireBandAnchor.top); // rejected below
  }
  _note('mask ${w}x$h first=$firstNonZeroRow last=$lastNonZeroRow '
      'r0=${bytes[0]} rMid=${bytes[(h ~/ 2) * w * 4]} '
      'rLast=${bytes[(h - 1) * w * 4]}');
  for (final VoidCallback cb in waiters) {
    cb();
  }
}

/// BB27 · one collapsed band sampler: both blur passes in ONE render object and
/// ONE layer, the snapshot clipped to the band plus the kernel's reach, and the
/// child composited into the real scene directly everywhere below the band.
///
/// Drop-in for `InspireChildBlur` at the ramp's call site, and it falls back to
/// exactly that widget whenever a guard is unmet.
class InspireChildBlurBandSampler extends StatefulWidget {
  final InspireBlurConfig config;
  final Clip clipBehavior;
  final bool useRepaintBoundary;
  final Object? layoutInvalidationKey;
  final Widget child;

  /// MANIFEST (divergence 6) · how many logical px the REAL child is also
  /// painted INTO the band, under the band picture, so a `BackdropFilter` that
  /// straddles the seam reads real pixels above it instead of unpainted ones
  /// (the dark step under the dashboard and profile headers). 0, the default,
  /// is the BB30 partition exactly: the child is clipped to below the band.
  ///
  /// ONLY SAFE WHEN THE CHILD IS OPAQUE where the underlap lands: the band
  /// picture is drawn over it, and over a translucent child the strip would be
  /// painted twice (BB30, LESSONS #84). The caller owns that guarantee.
  final double realUnderlap;

  /// MANIFEST C1 · draw both passes with `inspire_blur_child_fast.frag`, the
  /// copy of the child shader whose interior fragments skip the bounds masks
  /// and clamps (see that file's header). The same pixels at less ALU: byte
  /// identical on Skia and Impeller-Vulkan offline, and 0 differing bits in
  /// 115 scenes on the iPhone's own GPU (Metal, fast-math; 2026-11-22). The
  /// package default stays false (pub's behaviour); manifest_ui turns it on.
  /// While the fast program is still loading, or if it fails to load, the
  /// default one draws.
  final bool exactInteriorFastPath;

  /// MANIFEST R · the REDUCED-RESOLUTION band, a visible-change candidate,
  /// offered only as a developer Tune option so Reo can feel and see it on
  /// his phone; nothing ships with it on. `null`, the default, is today's
  /// band byte for byte.
  ///
  /// When set, the band's STRONG rows (vertical sigma at or above
  /// [reducedMinSigma] logical px) run both passes at [reducedScale] px per
  /// logical px instead of the device ratio, and are drawn back up with a
  /// bilinear filter. The WEAK rows next to the seam, where the blur is light
  /// and the content still sharp, run at full resolution exactly as today.
  /// `dpr / reducedScale` must be a whole number (1.0 or 1.5 at dpr 3).
  final double? reducedScale;

  /// See [reducedScale]. Logical px of vertical sigma; 0 reduces every row.
  final double reducedMinSigma;

  const InspireChildBlurBandSampler({
    super.key,
    required this.config,
    required this.child,
    this.clipBehavior = Clip.antiAlias,
    this.useRepaintBoundary = true,
    this.layoutInvalidationKey,
    this.realUnderlap = 0.0,
    this.exactInteriorFastPath = false,
    this.reducedScale,
    this.reducedMinSigma = 0.0,
  });

  @override
  State<InspireChildBlurBandSampler> createState() =>
      _InspireChildBlurBandSamplerState();
}

class _InspireChildBlurBandSamplerState
    extends State<InspireChildBlurBandSampler> {
  ui.FragmentShader? _shaderVertical;
  ui.FragmentShader? _shaderHorizontal;

  // MANIFEST C1 · the fast program's pair, loaded the first time the flag is
  // on and kept for the State's life (a runtime A/B flips it back and forth).
  ui.FragmentShader? _fastVertical;
  ui.FragmentShader? _fastHorizontal;
  bool _fastRequested = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    InspireShaders.childBlur.then((program) {
      final ui.FragmentShader? v = program?.fragmentShader();
      final ui.FragmentShader? h = program?.fragmentShader();
      if (mounted) {
        setState(() {
          _shaderVertical = v;
          _shaderHorizontal = h;
        });
      } else {
        _shaderVertical = v;
        _shaderHorizontal = h;
      }
    });
    if (widget.exactInteriorFastPath) _requestFast();
  }

  @override
  void didUpdateWidget(InspireChildBlurBandSampler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exactInteriorFastPath) _requestFast();
  }

  void _requestFast() {
    if (_fastRequested) return;
    _fastRequested = true;
    InspireShaders.childBlurExactInterior.then((program) {
      final ui.FragmentShader? v = program?.fragmentShader();
      final ui.FragmentShader? h = program?.fragmentShader();
      if (_disposed) {
        v?.dispose();
        h?.dispose();
        return;
      }
      setState(() {
        _fastVertical = v;
        _fastHorizontal = h;
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _shaderVertical?.dispose();
    _shaderHorizontal?.dispose();
    _fastVertical?.dispose();
    _fastHorizontal?.dispose();
    super.dispose();
  }

  /// The upstream composition, byte for byte. Every guard failure lands here.
  Widget _fallback() => InspireChildBlur(
        config: widget.config,
        mode: InspireBlurMode.animatedSampler,
        clipBehavior: widget.clipBehavior,
        useRepaintBoundary: widget.useRepaintBoundary,
        layoutInvalidationKey: widget.layoutInvalidationKey,
        child: widget.child,
      );

  /// `uv_blur` is `xy / u_size` put through `transformUv`. Only an identity
  /// transform keeps mask row N over child row N, which is what makes
  /// "everything below the last non-zero mask row is untouched" true.
  bool get _transformIsIdentity {
    final BlurTransform t = widget.config.transform;
    return t.scale.scaleX == 1.0 &&
        t.scale.scaleY == 1.0 &&
        t.offset == Offset.zero &&
        t.rotation == 0.0 &&
        t.inversionFactor == 0.0;
  }

  /// The last span this sampler actually painted a band with.
  ///
  /// See the `span == null` branch in `build`: a mask that has only just
  /// arrived has no span yet, and the honest thing to do for those few frames
  /// is keep painting the band we were painting, not stop painting one.
  InspireBandSpan? _lastGoodSpan;

  @override
  Widget build(BuildContext context) {
    // ── ONE WIDGET TYPE AT THIS SLOT, ALWAYS ────────────────────────────────
    //
    // Every guard lives INSIDE the wrapper's builder, which is exactly where
    // upstream `InspireChildBlur` puts its own (`inspire_child_blur.dart:86` —
    // the wrapper is mounted first and unconditionally, and the sigma cases are
    // decided under it).
    //
    // Guarding ABOVE it changes the runtimeType at the ramp's slot as sigma
    // leaves zero — `InspireChildBlur` at rest, `InspireBlurWrapper` while
    // scrolling — and Flutter replaces the Element on a runtimeType change.
    // That discards `_InspireBlurWrapperState` and the distribution image it
    // holds, and rebuilds the map ON THE GESTURE FRAME: `MnScrollRamp`'s Fix B
    // stall reintroduced ("unresponsive on the first touch"), plus one bare,
    // fully unblurred frame at full sigma. Measured in
    // `p19b_mask_swap_no_flash_test.dart`.
    return InspireBlurWrapper(
      config: widget.config,
      widgetType: InspireBlurWidgetType.child,
      layoutInvalidationKey: widget.layoutInvalidationKey,
      builder: (BuildContext context, InspireBlurWrapperData data) {
        // MANIFEST C1 · the fast pair once it has loaded, else the default.
        final bool fast = widget.exactInteriorFastPath &&
            _fastVertical != null &&
            _fastHorizontal != null;
        final ui.FragmentShader? shaderV =
            fast ? _fastVertical : _shaderVertical;
        final ui.FragmentShader? shaderH =
            fast ? _fastHorizontal : _shaderHorizontal;
        final double? sigmaH = widget.config.effectiveSigmaX;
        final double? sigmaV = widget.config.effectiveSigmaY;

        // INERT. Upstream returns the bare child for this case too
        // (`inspire_child_blur.dart:162`), and it is the case `MnScrollRamp`
        // sits in at rest — so answer it here rather than by mounting an
        // `InspireChildBlur`, whose own wrapper would be a second State to
        // remount on every scroll start.
        final bool noBlur = (sigmaH ?? 0.0) <= 0.0 && (sigmaV ?? 0.0) <= 0.0;
        if (noBlur && !widget.config.colorAdjustment.isActive) {
          // MANIFEST CR-191 #2 (vendor patch) · KEEP THE SHAPE AT SIGMA 0.
          // This used to return the bare `widget.child`, a different widget
          // type at this slot from the band path below. Every sigma 0 <-> >0
          // crossing (the first pixel of a scroll off the top, the return to
          // it, the dock's frost reaching / leaving 0) therefore reparented
          // the caller's GlobalKey'd body, and every element in it with an
          // inherited dependency rebuilt: 60 of 60 rows, on two gesture
          // frames (`test/perf/perf_audit_probe_test.dart` P7). Now the SAME
          // ClipRect > [RepaintBoundary] > sampler, with the clip off and the
          // sampler in pass-through: it paints the child straight through and
          // produces nothing, so the pixels are the bare child's.
          return ClipRect(
            clipBehavior: Clip.none,
            child: _maybeRepaintBoundary(
              child: _InspireBandSampler(
                passthrough: true,
                painter: _kPassthroughPainter,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                bandExtent: 1.0,
                bandAnchor: InspireBandAnchor.top,
                logicalSigmaVertical: 0.0,
                child: widget.child,
              ),
            ),
          );
        }

        // The remaining guards are properties of the CALL SITE, not of the
        // frame, so the nested wrapper they mount settles once and does not
        // flip: a single-axis blur, a colour adjustment or a non-identity
        // transform is a different effect than this file implements, and the
        // shader load resolves once per process.
        if (shaderV == null || shaderH == null) return _fallback();
        if (sigmaH == null || sigmaV == null || sigmaH <= 0.0 || sigmaV <= 0.0) {
          _note('not a two-pass blur');
          return _fallback();
        }
        if (!_transformIsIdentity) {
          _note('transform not identity');
          return _fallback();
        }
        if (widget.config.colorAdjustment.isActive) {
          _note('colorAdjustment active');
          return _fallback();
        }
        // 0.6.0 · the band draws the widget fully opaque and with no aspect
        // ratio correction (the fast program has neither), so anything else
        // goes through the regular child blur.
        if (widget.config.widgetOpacity is! SolidWidgetOpacity) {
          _note('widgetOpacity not solid');
          return _fallback();
        }
        if (widget.config.blurDistribution
            case FittableDistribution(distributionFit: DistributionFit.inside)) {
          _note('distributionFit inside');
          return _fallback();
        }

        final ui.Image? gradientMap = data.blurDistributionImage?.image;
        final ui.Image? opacityMap = data.opacityDistributionImage?.image;

        // Gradient map is not ready yet — skip a frame with no blur, exactly as
        // `InspireChildBlur` does. Only reachable before the FIRST map exists:
        // the wrapper keeps serving the previous image while it regenerates.
        if (gradientMap == null) return widget.child;

        InspireBandSpan? span = _bandSpan[gradientMap];
        if (span == null) {
          _resolveBandSpan(gradientMap, () {
            if (mounted) setState(() {});
          });
          // KEEP PAINTING. A new mask arrives whenever the zone, the viewport
          // or the chrome changes — a sheet entrance, an `MnBlurScrollHeader`
          // measurement landing, the keyboard, a rotation — any of which can
          // happen mid-scroll at full sigma, and its extent lands one async
          // `toByteData` later. Falling back here mounts a FRESH
          // `InspireChildBlur` whose own wrapper has no distribution image
          // yet, and that paints the BARE child: a full-screen unblurred
          // flash. The previous mask's extent is at worst a few points of band
          // out of date for those frames; a missing blur is not out of date,
          // it is wrong.
          span = _lastGoodSpan;
          if (span == null) {
            _note('extent unresolved');
            return _fallback();
          }
          _note('extent unresolved, holding the previous band');
        }
        if (span.extent <= 0.0 || span.extent >= 1.0) {
          _note('extent out of range (${span.extent.toStringAsFixed(4)})');
          // Not stale-able: this mask genuinely wants the upstream
          // composition, so do not hold a band over it.
          _lastGoodSpan = null;
          return _fallback();
        }
        _lastGoodSpan = span;
        _note('ok ${span.anchor.name} extent=${span.extent.toStringAsFixed(4)}');

        final double dpr = MediaQuery.devicePixelRatioOf(context);

        // The shader is handed LOGICAL sigma (see the divide) and its
        // `texelStep` is `1 / u_size`, i.e. also logical, so the kernel reach is
        // `ceil(3 * sigma)` LOGICAL px.
        final double logicalSigmaV = sigmaV / dpr;
        final double logicalSigmaH = sigmaH / dpr;
        final Offset normalizedOrigin =
            widget.config.transform.origin.toNormalizedOffset();

        void configure(
          ui.FragmentShader shader, {
          required ui.Image source,
          required Size windowSize,
          required double windowTop,
          required double childHeight,
          required double logicalSigma,
          required Axis direction,
          required BlurColorAdjustment colorAdjustment,
        }) {
          shader
            ..setImageSampler(0, source)
            ..setImageSampler(1, gradientMap)
            ..setFloat(0, windowSize.width)
            // BB27 · the texture is the WINDOW, so `uv` and `texel` are the
            // window's. See the header.
            ..setFloat(1, windowSize.height)
            // To ensure 1:1 effective blur strength with ImageFilter.shader
            // when using same sigma values — divide sigma by dpr.
            ..setFloat(2, logicalSigma)
            ..setFloat(3, direction == Axis.horizontal ? 1.0 : 0.0)
            ..setFloat(4, direction == Axis.vertical ? 1.0 : 0.0)
            ..setFloat(5, 0.0)
            // BB37 · float 6 is `u_delta_left_top.y` — how far down the child
            // the window STARTS. Zero for a top band (BB27's case, byte for
            // byte); `childHeight - windowH` for a bottom one.
            ..setFloat(6, windowTop)
            ..setFloat(7, 0.0)
            // BB27 · float 8 is `u_delta_right_bottom.y`, upstream always 0.
            // These two numbers are what keep the mask lookup identical while
            // the texture shrinks: the shader computes
            //   uv_blur.y = (xy.y + deltaTop.y) / (u_size.y + deltaTop.y + deltaBottom.y)
            // (`shaders/inspire_blur_child.frag:191`), and with deltaTop.y =
            // windowTop and deltaBottom.y = childHeight - windowTop - windowH
            // the denominator is `childHeight` and the numerator is the row's
            // position in the CHILD — the full-size lookup, at any anchor.
            ..setFloat(8, childHeight - windowTop - windowSize.height)
            ..setFloat(9, widget.config.transform.scale.scaleX)
            ..setFloat(10, widget.config.transform.scale.scaleY)
            ..setFloat(11, widget.config.transform.offset.dx)
            ..setFloat(12, widget.config.transform.offset.dy)
            ..setFloat(13, widget.config.transform.rotation)
            ..setFloat(14, normalizedOrigin.dx)
            ..setFloat(15, normalizedOrigin.dy)
            ..setFloat(16, widget.config.transform.inversionFactor)
            ..setFloat(17, colorAdjustment.shaderBrightness)
            ..setFloat(18, colorAdjustment.shaderContrast)
            ..setFloat(19, colorAdjustment.shaderExposure)
            ..setFloat(20, colorAdjustment.shaderSaturation)
            ..setFloat(21, colorAdjustment.shaderVibrance)
            ..setFloat(22, colorAdjustment.blurAdjustmentStrength)
            ..setFloat(23, colorAdjustment.nonBlurAdjustmentStrength);
          if (fast) {
            // MANIFEST C1 · the fast program keeps the 0.4.0 layout: B5
            // kernel sampling at 24-25 (the texel is LOGICAL here, so a
            // device px is 1/dpr; `unit` (0.0) is pub's loop), then its two
            // opaque ones.
            shader
              ..setFloat(24, widget.config.sampling.shaderMode)
              ..setFloat(25, 1.0 / dpr)
              ..setFloat(26, debugInspireExactInteriorOneA)
              ..setFloat(27, 1.0);
          } else {
            // The default program (0.5.0 layout): solid widget opacity, no
            // aspect ratio correction, then B5 kernel sampling at 27-28.
            shader
              ..setImageSampler(2, opacityMap ?? gradientMap)
              ..setFloat(24, const WidgetOpacity.solid().shaderOpacityType)
              ..setFloat(25, const WidgetOpacity.solid().shaderOpacityValue)
              ..setFloat(26, const AspectRatioCorrection(null).shaderAspectRatio)
              ..setFloat(27, widget.config.sampling.shaderMode)
              ..setFloat(28, 1.0 / dpr);
          }
        }

        // MANIFEST B5 · `minSigma` runs the kernel at >= 9 device px on every
        // blurred row, including the band's foot, where the tight window
        // (HEADER-BLUR-CUT 4j) budgets the ~1 px the pub kernel reads. So that
        // option takes the full-sigma window at the floored sigma instead:
        // every tap it reads is still in the snapshot. Other options reach no
        // further than pub's `ceil(3 * sigma)` and keep the tight window.
        final bool floorsSigma =
            widget.config.sampling == InspireKernelSampling.minSigma;
        final double windowSigmaV = floorsSigma
            ? math.max(logicalSigmaV,
                InspireKernelSampling.minSigmaDevicePx / dpr)
            : logicalSigmaV;

        return ClipRect(
          clipBehavior: widget.clipBehavior,
          child: _maybeRepaintBoundary(
            child: _InspireBandSampler(
              devicePixelRatio: dpr,
              bandExtent: span.extent,
              bandAnchor: span.anchor,
              bandProfile: floorsSigma ? null : span.rowRed,
              logicalSigmaVertical: windowSigmaV,
              realUnderlap: widget.realUnderlap,
              painter: _InspireBandPainter(
                // MANIFEST R · off for minSigma, whose window is sized to a
                // floored sigma the split below does not model.
                reducedScale: floorsSigma ? null : widget.reducedScale,
                // Only meaningful with a scale: with R off it is a constant,
                // so moving the global alone forces no production.
                reducedMinSigma: floorsSigma || widget.reducedScale == null
                    ? 0.0
                    : widget.reducedMinSigma,
                pixelKey: (
                  shaderV,
                  shaderH,
                  gradientMap,
                  sigmaH,
                  sigmaV,
                  widget.config.transform,
                  widget.config.colorAdjustment,
                  widget.config.sampling,
                ),
                verticalPass: (ui.Image source, Size windowSize,
                    double windowTop, double childHeight, Canvas canvas,
                    Rect drawRect) {
                  configure(
                    shaderV,
                    source: source,
                    windowSize: windowSize,
                    windowTop: windowTop,
                    childHeight: childHeight,
                    logicalSigma: logicalSigmaV,
                    direction: Axis.vertical,
                    // Colour adjustment runs on the FINAL pass only, so the
                    // two-pass blur never applies it twice — upstream's rule
                    // (`inspire_child_blur.dart:188-192`).
                    colorAdjustment:
                        widget.config.colorAdjustment.disabled(),
                  );
                  canvas.drawRect(
                    drawRect,
                    Paint()
                      ..shader = shaderV
                      ..isAntiAlias = false,
                  );
                },
                horizontalPass: (ui.Image source, Size windowSize,
                    double windowTop, double childHeight, Canvas canvas,
                    Rect drawRect) {
                  if (kDebugMode) debugInspireBandSamplerDraws++;
                  configure(
                    shaderH,
                    source: source,
                    windowSize: windowSize,
                    windowTop: windowTop,
                    childHeight: childHeight,
                    logicalSigma: logicalSigmaH,
                    direction: Axis.horizontal,
                    colorAdjustment: widget.config.colorAdjustment,
                  );
                  canvas.drawRect(
                    drawRect,
                    Paint()
                      ..shader = shaderH
                      // BB30 · THIS RECT NO LONGER TOUCHES THE SEAM. It is
                      // drawn two device rows PAST `band` and the clip in
                      // `addToScene` step 5 cuts it back, so the boundary is
                      // decided by one `pushClipRect` and this edge is not a
                      // second opinion about it. (It used to be: the rect's
                      // bottom and the child clip's top were both `band`, two
                      // different primitives on one coordinate, which is the
                      // BB30 defect.)
                      //
                      // The flag stays because it is free and the rect's edges
                      // that DO survive — left and right — should not feather
                      // against the outer `ClipRect`. MEASURED (BB27 review,
                      // D4): building both passes with a plain upstream
                      // `Paint()` instead is BYTE-IDENTICAL over the whole
                      // sheet frame, 0 px differing by even 1 LSB across
                      // y[60,852), so nothing here rests on it.
                      ..isAntiAlias = false,
                  );
                },
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }

  Widget _maybeRepaintBoundary({required Widget child}) =>
      widget.useRepaintBoundary ? RepaintBoundary(child: child) : child;
}

/// One blur pass. `windowSize` is the SNAPSHOT's logical size (width x
/// windowH); `windowTop` is how far down the child that window starts (0 for a
/// top-anchored band); `childHeight` is the full child height the mask is still
/// addressed against; `drawRect` is the region this pass actually paints, in
/// WINDOW-local coordinates.
typedef _InspireBandPass = void Function(
  ui.Image source,
  Size windowSize,
  double windowTop,
  double childHeight,
  Canvas canvas,
  Rect drawRect,
);

/// BB62 (audit) · EQUAL BY PIXELS, NOT BY CLOSURE IDENTITY. A fresh
/// `_InspireBandPainter` is built on every `build` — and the shipped scroll
/// surfaces (`MnBlurScrollHeader`, `MnSheet`) `setState` per
/// `ScrollUpdateNotification`, so under a fling that is a fresh closure pair
/// EVERY FRAME. The layer's cross-frame stale/re-serve decision compares its
/// `_BandPictureKey`, which includes this painter: compared by identity the
/// key was new every frame, `sameGeometry` was false, and the BB60 bound and
/// BB62 cap never engaged on the one workload they exist for.
///
/// So equality is over [pixelKey] — the values the two closures actually hand
/// the shader (the shader objects, the gradient map, both sigmas, transform,
/// colour adjustment). Two painters with equal pixel keys draw the same
/// pixels from the same source, whatever frame their closures were built in.
@immutable
class _InspireBandPainter {
  const _InspireBandPainter({
    required this.pixelKey,
    required this.verticalPass,
    required this.horizontalPass,
    this.reducedScale,
    this.reducedMinSigma = 0.0,
  });

  /// MANIFEST R · see [InspireChildBlurBandSampler.reducedScale]. Part of the
  /// pixel key: a reduced band is different pixels.
  final double? reducedScale;
  final double reducedMinSigma;

  /// Everything the passes feed the shader that is not already in the layer's
  /// own key (size/dpr/band/window/anchor). Built at the one construction
  /// site as a record, so `==` is structural: `ui.FragmentShader` and
  /// `ui.Image` members compare by identity (stable for the life of the
  /// element; a NEW gradient map is rightly a new key), the rest by value.
  final Object pixelKey;

  final _InspireBandPass verticalPass;
  final _InspireBandPass horizontalPass;

  @override
  bool operator ==(Object other) =>
      other is _InspireBandPainter &&
      other.pixelKey == pixelKey &&
      other.reducedScale == reducedScale &&
      other.reducedMinSigma == reducedMinSigma;

  @override
  int get hashCode => Object.hash(pixelKey, reducedScale, reducedMinSigma);
}

/// MANIFEST CR-191 #2 · the painter a pass-through sampler carries. Never
/// called: a pass-through layer adds its children and nothing else.
void _noBandPass(ui.Image source, Size windowSize, double windowTop,
    double childHeight, Canvas canvas, Rect drawRect) {}

const _InspireBandPainter _kPassthroughPainter = _InspireBandPainter(
  pixelKey: 'passthrough',
  verticalPass: _noBandPass,
  horizontalPass: _noBandPass,
);

class _InspireBandSampler extends SingleChildRenderObjectWidget {
  const _InspireBandSampler({
    this.passthrough = false,
    required this.painter,
    required this.devicePixelRatio,
    required this.bandExtent,
    required this.bandAnchor,
    this.bandProfile,
    required this.logicalSigmaVertical,
    this.realUnderlap = 0.0,
    required Widget child,
  }) : super(child: child);

  /// See [InspireChildBlurBandSampler.realUnderlap].
  final double realUnderlap;

  /// The mask's red per row; sizes the window. See
  /// [inspireBandSamplerTightWindowHeight].
  final Uint8List? bandProfile;

  final _InspireBandPainter painter;
  final double devicePixelRatio;

  /// Fraction of the child's height the band covers, from [bandAnchor].
  final double bandExtent;

  /// Which edge of the child the band hangs off. BB37.
  final InspireBandAnchor bandAnchor;

  /// The VERTICAL pass's sigma in logical px — the window's depth past the
  /// band is derived from it, not passed in, so one formula owns it.
  final double logicalSigmaVertical;

  /// MANIFEST CR-191 #2 · sigma 0: paint the child straight through, produce
  /// nothing. Keeps this render object (and the caller's subtree) mounted.
  final bool passthrough;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderInspireBandSampler(
      passthrough: passthrough,
      painter: painter,
      devicePixelRatio: devicePixelRatio,
      bandExtent: bandExtent,
      bandAnchor: bandAnchor,
      bandProfile: bandProfile,
      logicalSigmaVertical: logicalSigmaVertical,
      realUnderlap: realUnderlap,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderInspireBandSampler)
      ..passthrough = passthrough
      ..painter = painter
      ..devicePixelRatio = devicePixelRatio
      ..bandExtent = bandExtent
      ..bandAnchor = bandAnchor
      ..bandProfile = bandProfile
      ..logicalSigmaVertical = logicalSigmaVertical
      ..realUnderlap = realUnderlap;
  }
}

class _RenderInspireBandSampler extends RenderProxyBox {
  _RenderInspireBandSampler({
    required bool passthrough,
    required _InspireBandPainter painter,
    required double devicePixelRatio,
    required double bandExtent,
    required InspireBandAnchor bandAnchor,
    Uint8List? bandProfile,
    required double logicalSigmaVertical,
    double realUnderlap = 0.0,
  })  : _passthrough = passthrough,
        _realUnderlap = realUnderlap,
        _bandProfile = bandProfile,
        _painter = painter,
        _devicePixelRatio = devicePixelRatio,
        _bandExtent = bandExtent,
        _bandAnchor = bandAnchor,
        _logicalSigmaVertical = logicalSigmaVertical;

  _InspireBandPainter _painter;
  set painter(_InspireBandPainter value) {
    if (identical(value, _painter)) return;
    _painter = value;
    markNeedsCompositedLayerUpdate();
  }

  bool _passthrough;
  set passthrough(bool value) {
    if (value == _passthrough) return;
    _passthrough = value;
    markNeedsCompositedLayerUpdate();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsCompositedLayerUpdate();
  }

  double _bandExtent;
  set bandExtent(double value) {
    if (value == _bandExtent) return;
    _bandExtent = value;
    markNeedsCompositedLayerUpdate();
  }

  InspireBandAnchor _bandAnchor;
  set bandAnchor(InspireBandAnchor value) {
    if (value == _bandAnchor) return;
    _bandAnchor = value;
    markNeedsCompositedLayerUpdate();
  }

  double _logicalSigmaVertical;
  set logicalSigmaVertical(double value) {
    if (value == _logicalSigmaVertical) return;
    _logicalSigmaVertical = value;
    markNeedsCompositedLayerUpdate();
  }

  Uint8List? _bandProfile;
  set bandProfile(Uint8List? value) {
    if (identical(value, _bandProfile)) return;
    _bandProfile = value;
    markNeedsCompositedLayerUpdate();
  }

  double _realUnderlap;
  set realUnderlap(double value) {
    if (value == _realUnderlap) return;
    _realUnderlap = value;
    markNeedsCompositedLayerUpdate();
  }

  @override
  OffsetLayer updateCompositedLayer({
    required covariant _InspireBandSamplerLayer? oldLayer,
  }) {
    final _InspireBandSamplerLayer layer =
        oldLayer ?? _InspireBandSamplerLayer(_painter);
    layer
      ..passthrough = _passthrough
      ..painter = _painter
      ..size = size
      ..devicePixelRatio = _devicePixelRatio
      ..bandExtent = _bandExtent
      ..bandAnchor = _bandAnchor
      ..bandProfile = _bandProfile
      ..logicalSigmaVertical = _logicalSigmaVertical
      ..realUnderlap = _realUnderlap;
    return layer;
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    if (kDebugMode && !_passthrough) {
      debugInspireBandSamplerPaints++;
      debugInspireBandSamplerPaintAnchor = _bandAnchor.name;
    }
    assert(offset == Offset.zero);
    return super.paint(context, offset);
  }
}

/// BB59 · everything that decides the band picture's pixels EXCEPT the child's
/// content, which cannot change inside one frame. Compared with the frame
/// stamp, never on its own.
///
/// BB62 (audit) · the painter element compares by its PIXEL-DECIDING VALUES
/// (`_InspireBandPainter.pixelKey`), never by closure identity — the shipped
/// headers rebuild the painter every scroll frame, and an identity compare
/// made every frame a "new geometry", disabling the stale/re-serve path at
/// cap. Guarded by `oomhunt_rebuild_flood_cap_test.dart`.
typedef _BandPictureKey = (
  Size,
  double,
  double,
  double,
  double,
  InspireBandAnchor,
  _InspireBandPainter,
);

/// BB65 · hashes the CONTENT INSIDE THE BAND WINDOW, or reports that it met
/// something it cannot reason about.
///
/// Deliberately EXACT-TYPE matching (`runtimeType ==`), not `is`: an unknown
/// subclass of a known container (this package's own two sampler layers are
/// both `OffsetLayer` subclasses) paints things its base class does not, and
/// hashing it as its base class is exactly the freeze this walk must not
/// cause. Unknown => produce.
class _BandWindowSignature {
  _BandWindowSignature(this._window, this._anchor);

  /// CR-237 #4 · the anchor of the band being decided: an
  /// [InspireBandBackground] exempt from THIS anchor is not hashed.
  final InspireBandAnchor _anchor;

  /// In the layer's own coordinates — the same rect `_snapshotWindow` clips to.
  ///
  /// CR-237 #2 · not final: under an [ImageFilterLayer] it widens to
  /// [Rect.largest] for that subtree (see [_layer]).
  Rect _window;

  int _hash = 17;
  bool _unknown = false;

  /// Null when the subtree contains anything the walk does not recognise.
  int? run(Layer? first) {
    _children(first, Matrix4.identity());
    return _unknown ? null : _hash;
  }

  void _mix(Object? value) {
    _hash = 0x3fffffff & (_hash * 31 + (value?.hashCode ?? 0));
  }

  void _reject(Layer layer) {
    _unknown = true;
    if (kDebugMode) {
      debugInspireBandSamplerWindowUnknown = layer.runtimeType.toString();
    }
  }

  /// Whether anything in this sibling chain reached the window.
  bool _children(Layer? layer, Matrix4 transform) {
    bool touched = false;
    while (layer != null && !_unknown) {
      if (_layer(layer, transform)) touched = true;
      layer = layer.nextSibling;
    }
    return touched;
  }

  /// Whether [layer] (or anything under it) reached the window. A layer that
  /// did not is not hashed at all — that is the whole point: the dust below the
  /// band repaints into pictures this walk never looks at.
  bool _layer(Layer layer, Matrix4 transform) {
    if (layer is PictureLayer) {
      final Rect bounds =
          MatrixUtils.transformRect(transform, layer.canvasBounds);
      if (!bounds.overlaps(_window)) return false;
      _mix(identityHashCode(layer.picture));
      _mix(bounds);
      return true;
    }
    if (layer is _InspireBandSamplerLayer) {
      // A NESTED SAMPLER: its pixels are its own child's content plus the
      // values that decide its band, which is exactly its picture key.
      if (!_children(layer.firstChild, _translate(transform, layer.offset))) {
        return false;
      }
      _mix(layer.offset);
      _mix(layer.size);
      _mix(layer.devicePixelRatio);
      _mix(layer.bandExtent);
      _mix(layer.bandAnchor);
      _mix(layer.logicalSigmaVertical);
      _mix(layer.painter);
      return true;
    }
    final Type type = layer.runtimeType;
    if (type == _InspireBandBackgroundLayer) {
      final _InspireBandBackgroundLayer l = layer as _InspireBandBackgroundLayer;
      if (l.exemptFrom == _anchor) {
        // CR-237 #4 · a background this band was MEASURED not to need: its
        // offset is hashed (a moved background is a changed window), its
        // content is not. See [InspireBandBackground].
        _mix(l.offset);
        return true;
      }
      // Any other band sees an ordinary OffsetLayer.
      if (!_children(l.firstChild, _translate(transform, l.offset))) {
        return false;
      }
      _mix(l.offset);
      return true;
    }
    if (type == OffsetLayer) {
      final OffsetLayer l = layer as OffsetLayer;
      if (!_children(l.firstChild, _translate(transform, l.offset))) {
        return false;
      }
      _mix(l.offset);
      return true;
    }
    if (type == TransformLayer) {
      final TransformLayer l = layer as TransformLayer;
      // `TransformLayer.addToScene`: translate(offset) * transform.
      final Matrix4 next = _translate(transform, l.offset)
        ..multiply(l.transform ?? Matrix4.identity());
      if (!_children(l.firstChild, next)) return false;
      _mix(l.offset);
      // BB65 (audit, D7) · hash the storage directly. `storage.join(',')`
      // allocated a 16-value string per TransformLayer per walk, in release,
      // on a path that runs every frame.
      final Matrix4? m = l.transform;
      _mix(m == null ? null : Object.hashAll(m.storage));
      return true;
    }
    if (type == OpacityLayer) {
      final OpacityLayer l = layer as OpacityLayer;
      if (!_children(l.firstChild, _translate(transform, l.offset))) {
        return false;
      }
      _mix(l.offset);
      _mix(l.alpha);
      return true;
    }
    if (type == ClipRectLayer) {
      final ClipRectLayer l = layer as ClipRectLayer;
      return _clipped(l, transform, l.clipRect, l.clipBehavior);
    }
    if (type == ClipRRectLayer) {
      final ClipRRectLayer l = layer as ClipRRectLayer;
      return _clipped(l, transform, l.clipRRect?.outerRect, l.clipBehavior);
    }
    if (type == ClipPathLayer) {
      final ClipPathLayer l = layer as ClipPathLayer;
      return _clipped(l, transform, l.clipPath?.getBounds(), l.clipBehavior);
    }
    // ── CR-237 #2 · THE FILTER LAYERS. Every glass card, tile and dock puts a
    // `BackdropFilterLayer` in the window, and an unknown layer disengages the
    // gate for the whole tree, so any animation anywhere under a band used to
    // cost a production per frame. Each filter is hashed by VALUE, and only
    // filter types whose `==`/`hashCode` cover every pixel-deciding input are
    // accepted ([_hashableFilter]); a shader filter (mutable uniforms behind
    // one identity) or a compose (opaque halves) is still unknown => produce.
    if (type == BackdropFilterLayer) {
      final BackdropFilterLayer l = layer as BackdropFilterLayer;
      if (!_hashableFilter(l.filter)) {
        _reject(layer);
        return true;
      }
      // Always TOUCHED: the filter rewrites the backdrop over its whole
      // enclosing clip, whether or not its own children reach the window
      // (a clip that misses the window has already culled it above). Its
      // input is everything painted before it inside the snapshot, which is
      // exactly the earlier siblings this walk already hashed.
      _children(l.firstChild, transform);
      _mix(l.filter);
      _mix(l.blendMode);
      _mix(l.backdropKey);
      return true;
    }
    if (type == ImageFilterLayer) {
      final ImageFilterLayer l = layer as ImageFilterLayer;
      if (!_hashableFilter(l.imageFilter)) {
        _reject(layer);
        return true;
      }
      // A blur/matrix filter moves pixels: a child painted OUTSIDE the window
      // can land inside it. So its whole subtree is hashed, window or not.
      final Rect window = _window;
      _window = Rect.largest;
      final bool touched =
          _children(l.firstChild, _translate(transform, l.offset));
      _window = window;
      if (!touched) return false;
      _mix(l.offset);
      _mix(l.imageFilter);
      return true;
    }
    if (type == ColorFilterLayer) {
      final ColorFilterLayer l = layer as ColorFilterLayer;
      if (l.colorFilter == null) {
        _reject(layer);
        return true;
      }
      // Per-pixel, so the children's own window test stands — but a filter
      // that tints transparent black paints its whole clip, so the layer
      // itself is always TOUCHED.
      _children(l.firstChild, transform);
      _mix(l.colorFilter);
      return true;
    }
    _reject(layer);
    return true;
  }

  /// CR-237 #2 · the filter types whose `==`/`hashCode` are over every value
  /// that decides their pixels (`dart:ui` painting.dart: blur = sigmas, bounds,
  /// tile mode; matrix = data, quality; dilate/erode = radii; [ColorFilter] =
  /// mode/matrix/colour). Compared by RUNTIME TYPE OF A KNOWN INSTANCE, never
  /// by name, so an obfuscated build matches the same way.
  static final Set<Type> _kHashableFilterTypes = <Type>{
    ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1).runtimeType,
    ui.ImageFilter.matrix(Matrix4.identity().storage).runtimeType,
    ui.ImageFilter.dilate(radiusX: 1, radiusY: 1).runtimeType,
    ui.ImageFilter.erode(radiusX: 1, radiusY: 1).runtimeType,
    const ColorFilter.mode(Color(0x00000000), BlendMode.dst).runtimeType,
  };

  static bool _hashableFilter(ui.ImageFilter? filter) =>
      filter != null && _kHashableFilterTypes.contains(filter.runtimeType);

  /// A clip whose own rect misses the window hides everything under it, so the
  /// walk stops there — that is the cheap half. The other half is that a clip
  /// which DOES reach the window contributes its own geometry, because moving
  /// the clip changes the pixels without changing any picture.
  bool _clipped(
    ContainerLayer layer,
    Matrix4 transform,
    Rect? clip,
    Clip? behaviour,
  ) {
    if (clip == null) {
      _reject(layer);
      return true;
    }
    if (!MatrixUtils.transformRect(transform, clip).overlaps(_window)) {
      return false;
    }
    if (!_children(layer.firstChild, transform)) return false;
    _mix(clip);
    _mix(behaviour);
    return true;
  }

  static Matrix4 _translate(Matrix4 transform, Offset offset) =>
      transform.clone()..translate(offset.dx, offset.dy);
}

class _InspireBandSamplerLayer extends OffsetLayer {
  _InspireBandSamplerLayer(this._painter);

  ui.Picture? _lastPicture;

  /// BB60 · productions counted against the frame stamp they were made under.
  /// BB61 · and the counting is [InspireProductionBudget], shared with the
  /// fallback composition's layer so there is ONE bound in this package.
  final InspireProductionBudget _budget = InspireProductionBudget();

  /// BB59 · the frame [_lastPicture] was rasterised in, and the geometry it was
  /// rasterised for. Null stamp = built outside a frame = never reusable.
  Duration? _pictureFrame;
  _BandPictureKey? _pictureKey;

  /// BB65 · the window signature [_lastPicture] was rasterised for, and how
  /// many productions the gate has skipped since. The counter is the valve:
  /// see [kInspireBandWindowMaxSkips].
  int? _pictureSignature;
  int _skippedSinceProduction = 0;

  /// The current frame's identity, or null when we are not inside one.
  ///
  /// Compositing runs under `persistentCallbacks` (`drawFrame` ->
  /// `compositeFrame`), which is the ONLY phase where `currentFrameTimeStamp`
  /// is both set and meaningful — and where the render tree is frozen, which is
  /// what makes "same frame => same pixels" true. Every other caller
  /// (`RenderRepaintBoundary.toImage` from a post-frame callback or from idle)
  /// gets null and rasterises for itself.
  Duration? _frameStamp() => InspireProductionBudget.frameStamp();

  Size get size => _size;
  Size _size = Size.zero;
  set size(Size value) {
    if (value == _size) return;
    _size = value;
    markNeedsAddToScene();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio = 1.0;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsAddToScene();
  }

  double get bandExtent => _bandExtent;
  double _bandExtent = 1.0;
  set bandExtent(double value) {
    if (value == _bandExtent) return;
    _bandExtent = value;
    markNeedsAddToScene();
  }

  InspireBandAnchor get bandAnchor => _bandAnchor;
  InspireBandAnchor _bandAnchor = InspireBandAnchor.top;
  set bandAnchor(InspireBandAnchor value) {
    if (value == _bandAnchor) return;
    _bandAnchor = value;
    markNeedsAddToScene();
  }

  double get logicalSigmaVertical => _logicalSigmaVertical;
  double _logicalSigmaVertical = 0.0;
  set logicalSigmaVertical(double value) {
    if (value == _logicalSigmaVertical) return;
    _logicalSigmaVertical = value;
    markNeedsAddToScene();
  }

  /// HEADER-BLUR-CUT · the mask's red per row, or null. Not hashed into the
  /// picture key itself: it only decides `windowH`, which is.
  Uint8List? get bandProfile => _bandProfile;
  Uint8List? _bandProfile;
  set bandProfile(Uint8List? value) {
    if (identical(value, _bandProfile)) return;
    _bandProfile = value;
    markNeedsAddToScene();
  }

  /// See [InspireChildBlurBandSampler.realUnderlap]. Touches only the REAL
  /// walk, never the band picture, so it is not part of the picture key.
  double get realUnderlap => _realUnderlap;
  double _realUnderlap = 0.0;
  set realUnderlap(double value) {
    if (value == _realUnderlap) return;
    _realUnderlap = value;
    markNeedsAddToScene();
  }

  _InspireBandPainter get painter => _painter;
  _InspireBandPainter _painter;
  set painter(_InspireBandPainter value) {
    if (identical(value, _painter)) return;
    _painter = value;
    markNeedsAddToScene();
  }

  /// MANIFEST CR-191 #2 · sigma 0: [addToScene] adds the children exactly as
  /// a plain [OffsetLayer] would, and the held band picture is released (it
  /// used to die with the unmounted sampler).
  bool get passthrough => _passthrough;
  bool _passthrough = false;
  set passthrough(bool value) {
    if (value == _passthrough) return;
    _passthrough = value;
    if (value) {
      _lastPicture?.dispose();
      _lastPicture = null;
      _pictureFrame = null;
      _pictureKey = null;
      _pictureSignature = null;
      _skippedSinceProduction = 0;
    }
    markNeedsAddToScene();
  }

  @override
  void markNeedsAddToScene() {
    if (kDebugMode) debugInspireBandSamplerMarks++;
    super.markNeedsAddToScene();
  }

  /// Whole device pixels, so the clip below the band and the rect over it land
  /// on the SAME row boundary and neither gets partial coverage.
  double _snap(double logical) =>
      (logical * devicePixelRatio).roundToDouble() / devicePixelRatio;

  /// The SNAPSHOT — the child, clipped to the window, into a window-sized
  /// target. `windowH` is the whole BB27 texture saving: BB25 passed
  /// `size.height` here and paid for a full-viewport texture it had already
  /// stopped painting into.
  ///
  /// BB37 · `windowTop` slides that window down the child for a bottom-anchored
  /// band. It is 0 for a top-anchored one, where the two `pushTransform`
  /// arguments collapse to BB27's single scale and the bytes are unchanged.
  ui.Image _snapshotWindow(double windowTop, double windowH) {
    final ui.SceneBuilder builder = ui.SceneBuilder();
    // Scale to device px AND slide the window's first row up to texture row 0,
    // in one transform: the child still paints at its own coordinates, and the
    // texture holds `[windowTop, windowTop + windowH)` of it.
    builder.pushTransform(
      (Matrix4.diagonal3Values(devicePixelRatio, devicePixelRatio, 1)
            ..translate(0.0, -windowTop))
          .storage,
    );
    builder.pushClipRect(
      Rect.fromLTWH(0, windowTop, size.width, windowH),
      clipBehavior: Clip.hardEdge,
    );
    addChildrenToScene(builder);
    builder.pop();
    builder.pop();
    final ui.Scene scene = builder.build();
    final int w = (devicePixelRatio * size.width).ceil();
    final int h = (devicePixelRatio * windowH).ceil();
    if (kDebugMode) {
      debugInspireBandSamplerTextures++;
      debugInspireBandSamplerTargetPixels += w * h;
    }
    final ui.Image image = scene.toImageSync(w, h);
    // AFTER `toImageSync`, so the echo `produced` may post is queued on the
    // raster runner BEHIND this production and its completion covers it —
    // posted before, the echo could retire a cohort whose last production
    // had not been consumed yet (off by one target per echo round).
    InspireTextureLedger.produced();
    if (kDebugMode) debugInspireLiveSamplerImages++;
    scene.dispose();
    return image;
  }

  /// Rasterise one recorded pass into a window-sized image. The picture is
  /// added under the SAME `pushTransform(dpr)` the upstream composition puts
  /// its intermediate pass under, so `FlutterFragCoord` stays logical and the
  /// intermediate is the same bytes it is today.
  ///
  /// CR-237 #1 · ONLY THE BAND'S ROWS. The vertical pass draws `bandRect` and
  /// nothing else, and the horizontal pass reads only those rows, so the rest
  /// of a window-sized intermediate was allocated, cleared and never read.
  /// The target now starts at window row [cropTop] and is [cropH] tall (both
  /// on the device grid): ~12% fewer render-target pixels per production.
  /// MEASURED byte-identical under Impeller (`cr237_ramp_pixel_identity_test`).
  ui.Image _rasterise(ui.Picture picture, double cropTop, double cropH) {
    final ui.SceneBuilder builder = ui.SceneBuilder();
    builder.pushTransform(
      (Matrix4.diagonal3Values(devicePixelRatio, devicePixelRatio, 1)
            ..translate(0.0, -cropTop))
          .storage,
    );
    builder.addPicture(Offset.zero, picture);
    builder.pop();
    final ui.Scene scene = builder.build();
    final int w = (devicePixelRatio * size.width).ceil();
    final int h = (devicePixelRatio * cropH).ceil();
    if (kDebugMode) {
      debugInspireBandSamplerTextures++;
      debugInspireBandSamplerTargetPixels += w * h;
    }
    final ui.Image image = scene.toImageSync(w, h);
    // AFTER `toImageSync` — same ordering rule as `_snapshotWindow`.
    InspireTextureLedger.produced();
    if (kDebugMode) debugInspireLiveSamplerImages++;
    scene.dispose();
    return image;
  }

  /// MANIFEST R · [_rasterise] at any scale: `scale` px per logical px
  /// instead of the device ratio. Same transform shape, same ledger.
  ui.Image _rasteriseAt(
      ui.Picture picture, double cropTop, double cropH, double scale) {
    final ui.SceneBuilder builder = ui.SceneBuilder();
    builder.pushTransform(
      (Matrix4.diagonal3Values(scale, scale, 1)
            ..translateByDouble(0.0, -cropTop, 0.0, 1.0))
          .storage,
    );
    builder.addPicture(Offset.zero, picture);
    builder.pop();
    final ui.Scene scene = builder.build();
    final int w = _wholePx(scale * size.width);
    final int h = _wholePx(scale * cropH);
    if (kDebugMode) {
      debugInspireBandSamplerTextures++;
      debugInspireBandSamplerTargetPixels += w * h;
    }
    final ui.Image image = scene.toImageSync(w, h);
    InspireTextureLedger.produced();
    if (kDebugMode) debugInspireLiveSamplerImages++;
    scene.dispose();
    return image;
  }

  /// MANIFEST R · a target extent in whole px. Every extent `_produceReduced`
  /// asks for is a whole number of reduced rows or columns, but the product
  /// arrives as a double a hair above it (1.5 x 0.6666… x n), and `ceil` of
  /// that is one row too many: a transparent row the bilinear upsample would
  /// blend into the band's last device row (review finding, 2026-11-21).
  static int _wholePx(double v) {
    final double r = v.roundToDouble();
    return (v - r).abs() < 1e-6 ? r.toInt() : v.ceil();
  }

  /// MANIFEST R · the band picture with its STRONG rows at reduced resolution.
  ///
  /// Splits the band's rows at the first row (counted from the band's strong
  /// edge) whose vertical sigma drops below [minSigma], read off the mask's
  /// per-row red the same way the tight window reads it. The split lands on a
  /// row boundary of both the device grid and the reduced grid.
  ///
  ///   · STRONG rows: vertical pass into a target at [scale], horizontal pass
  ///     into another at [scale], drawn back up over exactly those rows with a
  ///     bilinear filter. 1/(dpr/scale)^2 of today's fragments per pass.
  ///   · WEAK rows: today's passes, restricted to those rows. Each fragment is
  ///     computed exactly as today, so these rows are today's bytes.
  ///
  /// The two regions meet at one coordinate, and two hard-edged clips at that
  /// coordinate decide which row belongs to which (see the BB30 note inside).
  ///
  /// Returns null (and touches nothing) when there is no profile to split on,
  /// the scale does not divide the device ratio, the width is not a whole
  /// number of reduced columns, or no row is strong enough; the caller then
  /// runs today's passes.
  ui.Picture? _produceReduced({
    required ui.Image source,
    required Size windowSize,
    required double windowTop,
    required Rect bandRect,
    required bool bottom,
    required double scale,
    required double minSigma,
  }) {
    final double dpr = devicePixelRatio;
    if (scale <= 0.0 || scale > dpr) return null;
    final double ratio = dpr / scale;
    if ((ratio - ratio.roundToDouble()).abs() > 1e-9) return null;
    final double grid = 1.0 / scale; // a reduced row, in logical px
    // A whole number of reduced columns, or the last column would be part
    // painted and the horizontal pass would read a half-empty edge.
    final double cols = scale * size.width;
    if ((cols - cols.roundToDouble()).abs() > 1e-6) return null;
    final Uint8List? profile = _bandProfile;
    final double sigmaV = logicalSigmaVertical;
    if (sigmaV <= 0.0) return null;

    // The strong edge's extent: how many logical px, from the band's strong
    // edge, have sigma >= minSigma at every mask row they touch.
    double strong;
    if (minSigma <= 0.0) {
      strong = bandRect.height;
    } else {
      if (profile == null || profile.isEmpty) return null;
      final int rows = profile.length;
      final double rowH = size.height / rows;
      int redAt(int k) {
        final int i = k.clamp(0, rows - 1);
        return profile[bottom ? rows - 1 - i : i];
      }
      // Child px from the strong edge (top of a top band, bottom of a bottom
      // one); the band's strong edge IS the child's edge at both anchors.
      strong = 0.0;
      for (int k = 0; k < rows; k++) {
        // The mask is filtered, so a fragment in row k can read k-1..k+1.
        final int red =
            math.min(redAt(k - 1), math.min(redAt(k), redAt(k + 1)));
        if (sigmaV * red / 255.0 < minSigma) break;
        strong = (k + 1) * rowH;
      }
      // Only rows inside the band are reduced; the rest is the weak region.
      strong = math.min(strong, bandRect.height);
    }
    // Down onto the reduced grid (which is also on the device grid).
    strong = (strong / grid).floorToDouble() * grid;
    if (strong <= 0.0) return null;

    // Window-local rows. A top band's strong edge is window row 0; a bottom
    // band's is the window's bottom. `sRect` and `wRect` PARTITION the band at
    // one coordinate, `split`.
    final double split =
        bottom ? windowSize.height - strong : strong;
    final Rect sRect = bottom
        ? Rect.fromLTRB(0, split, size.width, windowSize.height)
        : Rect.fromLTRB(0, 0, size.width, split);
    final Rect wRect = bottom
        ? Rect.fromLTRB(0, bandRect.top, size.width, split)
        : Rect.fromLTRB(0, split, size.width, bandRect.bottom);

    // ── THE SPLIT IS DECIDED BY TWO CLIPS, NOT BY TWO DRAW EDGES (BB30) ──
    //
    // Each region is DRAWN one reduced row past `split` and then CLIPPED back
    // to its own side by a hard-edged `clipRect` at `split`: one coordinate
    // through one call, twice, as a pair of complementary half-open intervals.
    // Abutting the two draws instead (an image rect over one side, a shader
    // rect over the other) dropped a whole device row at a sub-pixel offset
    // in `r_band_split_seam_test.dart`, exactly the BB30 failure: two
    // different primitives break a pixel-centre tie differently.
    final Rect sDraw = bottom
        ? Rect.fromLTRB(0, split - grid, size.width, windowSize.height)
        : Rect.fromLTRB(0, 0, size.width, split + grid);
    final double sDrawH = sDraw.height;

    // Every image below is released on every path, a throwing pass included,
    // as today's passes do. `source` stays the caller's: it is disposed there.
    ui.Image? vs;
    ui.Image? hs;
    ui.Image? vw;
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    try {
      // ── STRONG · vertical pass at `scale` ──
      final ui.PictureRecorder vsRec = ui.PictureRecorder();
      painter.verticalPass(source, windowSize, windowTop, size.height,
          Canvas(vsRec), sDraw);
      final ui.Picture vsPic = vsRec.endRecording();
      vs = _rasteriseAt(vsPic, sDraw.top, sDrawH, scale);
      vsPic.dispose();
      final double sw = vs.width / scale;
      final double sh = vs.height / scale;

      // ── STRONG · horizontal pass at `scale`, reading `vs` as its window ──
      final ui.PictureRecorder hsRec = ui.PictureRecorder();
      final Canvas hsCanvas = Canvas(hsRec)..translate(0, sDraw.top);
      painter.horizontalPass(vs, Size(sw, sh), windowTop + sDraw.top,
          size.height, hsCanvas, Rect.fromLTWH(0, 0, sw, sh));
      final ui.Picture hsPic = hsRec.endRecording();
      hs = _rasteriseAt(hsPic, sDraw.top, sh, scale);
      hsPic.dispose();

      // ── THE PICTURE ──
      canvas.save();
      canvas.clipRect(sRect, doAntiAlias: false);
      canvas.drawImageRect(
        hs,
        Rect.fromLTWH(0, 0, hs.width.toDouble(), hs.height.toDouble()),
        Rect.fromLTWH(0, sDraw.top, sw, sh),
        Paint()
          ..filterQuality = FilterQuality.low
          ..isAntiAlias = false,
      );
      canvas.restore();

      // ── WEAK · today's passes over the weak rows (plus the overdraw) ──
      if (wRect.height > 0.0) {
        final Rect wDraw = bottom
            ? Rect.fromLTRB(0, wRect.top, size.width, split + grid)
            : Rect.fromLTRB(0, split - grid, size.width, wRect.bottom);
        final ui.PictureRecorder vwRec = ui.PictureRecorder();
        painter.verticalPass(source, windowSize, windowTop, size.height,
            Canvas(vwRec), wDraw);
        final ui.Picture vwPic = vwRec.endRecording();
        final double cropTop = wDraw.top;
        final double cropH = (wDraw.height * dpr).ceilToDouble() / dpr;
        vw = _rasterise(vwPic, cropTop, cropH);
        vwPic.dispose();
        canvas.save();
        canvas.clipRect(wRect, doAntiAlias: false);
        canvas.translate(0, cropTop);
        painter.horizontalPass(vw, Size(size.width, cropH),
            windowTop + cropTop, size.height, canvas,
            wDraw.shift(Offset(0, -cropTop)));
        canvas.restore();
      }
    } finally {
      for (final ui.Image? image in <ui.Image?>[vs, hs, vw]) {
        if (image == null) continue;
        image.dispose();
        if (kDebugMode) debugInspireLiveSamplerImages--;
      }
    }
    return rec.endRecording();
  }

  @override
  void dispose() {
    _lastPicture?.dispose();
    super.dispose();
  }

  /// The child subtree is walked TWICE per frame — once into the snapshot scene
  /// and once into the real scene — and Flutter's retained rendering would hand
  /// the second walk an engine layer belonging to the first walk's builder.
  /// Marking the subtree dirty between the walks makes both of them real.
  void _forceReAdd(Layer? layer) {
    while (layer != null) {
      // ignore: invalid_use_of_protected_member
      if (!layer.alwaysNeedsAddToScene) layer.markNeedsAddToScene();
      if (layer is ContainerLayer) _forceReAdd(layer.firstChild);
      layer = layer.nextSibling;
    }
  }

  /// BB65 (audit, D3) · THE STANDARD `OffsetLayer` PATTERN, AND WHY IT MATTERS
  /// HERE. `pushOffset` returns the engine layer it pushed, and `Layer`'s
  /// retained path (`addRetained`) is only available to a layer that KEPT it:
  /// discarding the return left `engineLayer` permanently null, so this layer
  /// itself could never be retained and BB64's saving came entirely from a
  /// retainable ANCESTOR happening to sit above it. Keeping it makes retention
  /// a property of THIS layer.
  ///
  /// Sound despite the double walk: `_snapshotWindow` builds its own
  /// `SceneBuilder` and only ever adds the CHILDREN to it, so the engine layer
  /// stored here always belongs to the real scene's builder — never the
  /// snapshot's, which is disposed with its scene.
  void _pushOffsetRetained(ui.SceneBuilder builder) {
    engineLayer = builder.pushOffset(
      offset.dx,
      offset.dy,
      oldLayer: engineLayer as ui.OffsetEngineLayer?,
    );
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (size.isEmpty) {
      // Nothing was pushed, so whatever engine layer we still hold describes a
      // scene that no longer matches us — drop it rather than let a later
      // `addRetained` re-add a stale band.
      engineLayer = null;
      return;
    }
    if (_passthrough) {
      // MANIFEST CR-191 #2 · no band: the plain OffsetLayer composite.
      super.addToScene(builder);
      return;
    }
    if (kDebugMode) debugInspireBandSamplerScenes++;

    _forceReAdd(firstChild);

    // ONE DEVICE ROW IS THE FLOOR. `bandExtent` is only ever positive here —
    // the widget falls back to the upstream composition for `<= 0` — so a
    // snapped band of zero means the mask's non-zero region is thinner than
    // half a device pixel. Without the floor the branch below composited the
    // child with NO blur at all, and a layer cannot fall back to a widget, so
    // that downgrade was silent and unguardable. A one-row band is what "the
    // blur zone is sub-pixel" honestly renders as, and it keeps every guard
    // decision in the widget where a real fallback is possible.
    final double band = math.max(
      1.0 / devicePixelRatio,
      _snap((bandExtent * size.height).clamp(0.0, size.height)),
    ).clamp(0.0, size.height);
    // HEADER-BLUR-CUT · sized to the kernels the drawn rows run, which is
    // what `bandRect` below draws: the band plus two device rows.
    final Uint8List? profile = _bandProfile;
    final double windowH = profile == null || debugInspireBandTightWindowDisabled
        ? inspireBandSamplerWindowHeight(
            band: band,
            logicalSigmaVertical: logicalSigmaVertical,
            childHeight: size.height,
            devicePixelRatio: devicePixelRatio,
          )
        : inspireBandSamplerTightWindowHeight(
            rowRed: profile,
            anchor: bandAnchor,
            band: band,
            drawExtent: math.min(band + 2.0 / devicePixelRatio, size.height),
            logicalSigmaVertical: logicalSigmaVertical,
            childHeight: size.height,
            devicePixelRatio: devicePixelRatio,
          );
    // BB37 · the window hugs the band's anchor edge and reaches INWARD. For a
    // top band that is `windowTop = 0` and every number below is BB27's.
    //
    // AND IT STAYS ON THE DEVICE GRID **WHEN THE CALLER SNAPPED ITS BOX**,
    // which the snapshot's translate wants as much as Fix C wants it. `windowH`
    // is always `_snap`ped here, so `windowTop = size.height - windowH` is a
    // grid value exactly when `size.height` is one — and it is on every path
    // that matters: `manifest_scroll_ramp.dart`'s Fix C box, and
    // `manifest_shader_fade.dart`'s, which calls the same
    // `mnSnapUpToDevicePx` helper.
    //
    // ONE CALLER BRANCH DOES NOT SNAP: `manifest_shader_fade.dart:468`, the
    // unbounded-constraints guard, returns `blur(body)` with no `SizedBox`
    // around it at all. A top-anchored band is unaffected (`windowTop` is 0 by
    // construction), but a BOTTOM-anchored one would then translate its
    // snapshot by a fractional device row, and the texture would be sampled
    // half a texel off its own grid — the Fix C defect, one axis, on the band
    // only. It costs nothing today because that branch is a guard and not a
    // path: a fade wrapping a scrollable is bounded in practice, and the
    // comment there says so. Snap `windowTop` here rather than trusting the
    // caller if that ever stops being true.
    final bool bottom = bandAnchor == InspireBandAnchor.bottom;
    final double windowTop = bottom ? size.height - windowH : 0.0;
    // THE ONE COORDINATE (BB30). The child row the band ends at (top anchor) or
    // starts at (bottom anchor) — used by both `pushClipRect` calls below and
    // by nothing else.
    final double seam = bottom ? size.height - band : band;

    // Unreachable for any live `bandExtent` given the floor above (`size` is
    // already known non-empty), and kept only so a degenerate `devicePixelRatio`
    // cannot reach the arithmetic below. The child is composited unchanged,
    // which is the correct output for a zero-height band.
    if (band <= 0.0 || windowH <= 0.0) {
      _pushOffsetRetained(builder);
      addChildrenToScene(builder);
      builder.pop();
      return;
    }

    if (kDebugMode) {
      debugInspireBandSamplerSceneOrder = '';
      debugInspireBandSamplerGeometry =
          'size=${size.width}x${size.height} offset=$offset dpr=$devicePixelRatio '
          'extent=$bandExtent anchor=${bandAnchor.name} band=$band '
          'seam=$seam windowTop=$windowTop windowH=$windowH '
          'band*dpr=${band * devicePixelRatio} '
          'win*dpr=${windowH * devicePixelRatio} '
          'winCeil=${(devicePixelRatio * windowH).ceil()} '
          'sigmaV=$logicalSigmaVertical';
    }
    final Size windowSize = Size(size.width, windowH);
    // BB30 · DRAWN PAST THE SEAM ON PURPOSE. The clip at `band` (step 5) is the
    // only thing that decides the boundary; this rect's own bottom edge is kept
    // two device rows below it so it can never be a second, disagreeing opinion
    // about the same row. Those rows are clipped away, so they cost two rows of
    // shading and change nothing — and `windowH` is `band + ceil(3*sigma) + 2`,
    // so they are still inside the snapshot the V pass reads.
    //
    // BB37 · WINDOW-LOCAL, and mirrored for a bottom band: the band sits at the
    // window's FAR end there, so the rect runs from two device rows above the
    // seam to the window's bottom. `windowH - band` is where the band starts
    // inside the window at either anchor (top: `band` from row 0 — the reach is
    // below it; bottom: the reach is above it).
    final Rect bandRect = bottom
        ? Rect.fromLTRB(
            0,
            math.max(windowH - band - 2.0 / devicePixelRatio, 0.0),
            size.width,
            windowH,
          )
        : Rect.fromLTRB(
            0,
            0,
            size.width,
            math.min(band + 2.0 / devicePixelRatio, windowH),
          );

    // ── BB59 · TWO `toImageSync` TARGETS PER LAYER PER FRAME. NOT SIX. ──────
    //
    // THE DEFECT (BB59, `oomhunt_band_texture_budget_test.dart`): steps 1-3
    // allocate two window-sized `toImageSync` targets, and `addToScene` was
    // running them EVERY TIME AN ANCESTOR WALKED THIS LAYER — which under the
    // shipped composition is three times a frame, not once. `MnBlurScrollHeader`
    // mounts `MnShaderFade` (frosted, bottom band) AROUND `MnScrollRamp` (top
    // band), so the outer sampler walks the inner one twice: once into its own
    // `_snapshotWindow` scene and once into the real scene. MEASURED on a
    // 402x874 dpr-3 rig with the child repainting per frame:
    //
    //   ramp alone            2 textures/frame     1 band draw
    //   fade wrapping ramp    6 textures/frame     3 band draws   <- shipped
    //
    // At this geometry each target is `1206 x 467 x 4` = 2.25 MB, so the
    // shipped composition asked the engine for 13.5 MB of fresh render targets
    // per frame — 1.6 GB/s at 120 Hz. `dispose()` below returns the DART
    // handles immediately, but the GPU texture is released on the RASTER
    // thread; the moment raster falls behind the UI thread (which is exactly
    // what a reorder drag does — the overlay proxy adds three clipped
    // `MaskFilter.blur` draws a frame on top of this) the per-frame transient
    // becomes unbounded resident memory.
    //
    // WHAT IS MEASURED AND WHAT IS NOT. The 6 -> 4 texture count, the target
    // dimensions and the megabytes are measured here, on this rig, by
    // `oomhunt_band_texture_budget_test.dart`. That this is what killed BB59's
    // phone (a reorder drag on the playlist, signal 9, no .ips, no Dart output)
    // is INFERENCE from that arithmetic — the corpse has not been read. It is
    // a defect on its own terms either way: a producer whose cost scales with
    // how many ancestors walk it is not bounded, and this composition nests.
    //
    // THE FIX IS NOT A SMALLER TEXTURE, IT IS A BOUND. The extra walks produce
    // BIT-IDENTICAL pixels: within one frame the render tree is frozen, so the
    // second and third walks re-rasterise a picture this layer already has.
    // Keep it and hand it back. The bound is then two targets per layer per
    // frame NO MATTER how deeply samplers nest or how many times an ancestor
    // walks us — which is the property the regression test asserts, because
    // "how far behind is raster" is not observable from Dart and a producer
    // that is bounded per frame cannot outrun a consumer that drains per frame.
    //
    // THE FRAME STAMP IS THE KEY, and it is NULL outside a frame on purpose:
    // `RenderRepaintBoundary.toImage` drives `addToScene` from
    // `postFrameCallbacks` or from idle, where "same frame" has no meaning, so
    // those callers always produce. Never reuse on a null stamp — `null ==
    // null` would make every out-of-frame walk a cache hit and freeze the band
    // at the first picture it ever made.
    final Duration? frame = _frameStamp();
    final _BandPictureKey key = (
      size,
      devicePixelRatio,
      band,
      windowTop,
      windowH,
      bandAnchor,
      painter,
    );
    final ui.Picture? cached = _lastPicture;
    final ui.Picture picture;

    // ── BB60 · AND BOUNDED BETWEEN FRAMES, NOT ONLY WITHIN ONE. ────────────
    //
    // Drain first: a frame stamp this layer has not counted against yet means
    // the pipeline moved, so everything produced against the previous one is
    // through. A RUN OF NULL STAMPS IS ONE STAMP for this purpose, which is
    // exactly the out-of-band burst the bound exists for.
    // BB62 · and bounded ACROSS frames too: past the global outstanding-
    // texture ceiling the same stale path engages, because a dropped band
    // refresh is invisible and an allocator kill is not.
    final bool overBudget =
        _budget.backlogged(frame) || InspireTextureLedger.atCap;
    final bool sameGeometry = cached != null && key == _pictureKey;
    final bool sameFrame =
        sameGeometry && frame != null && frame == _pictureFrame;
    // GEOMETRY IS NOT STALE-ABLE. A picture made for a different band, window
    // or dpr is not one frame out of date, it is the wrong picture in the
    // wrong place — so a geometry change always produces, bound or no bound.
    // Geometry changes on layout, not on content, so the pathological producer
    // (a drag repainting the same box every frame) is still fully bounded.
    final bool backlogged = sameGeometry && overBudget;

    // ── BB65 · AND NOT AT ALL WHEN THE WINDOW'S CONTENT DID NOT CHANGE. ────
    //
    // See the header note by [kInspireBandWindowMaxSkips]. The signature is
    // only consulted on an otherwise-normal frame: `sameFrame` (the second
    // walk of the double walk) and `backlogged` (the allocator backstop) both
    // decide first and neither counts against the valve, because neither is a
    // production this gate skipped.
    //
    // BB65 (audit, D6) · "decide first" now means the WALK does not run either.
    // It used to run unconditionally and have its answer thrown away on those
    // two branches — and under the shipped nesting an ancestor walks this layer
    // three times a frame, two of which are `sameFrame`, so the subtree was
    // hashed three times to be used once.
    final bool gateApplies = sameGeometry &&
        !sameFrame &&
        !backlogged &&
        !debugInspireBandWindowGateDisabled;
    final int? signature = gateApplies
        ? _BandWindowSignature(
            Rect.fromLTWH(0, windowTop, size.width, windowH),
            bandAnchor,
          ).run(firstChild)
        : null;
    final bool windowUnchanged =
        gateApplies && signature != null && signature == _pictureSignature;
    final bool forcedRefresh =
        windowUnchanged && _skippedSinceProduction >= kInspireBandWindowMaxSkips;
    final bool skipProduction = windowUnchanged && !forcedRefresh;

    if (sameFrame || backlogged || skipProduction) {
      // Same frame, same geometry, same painter — same pixels, by definition.
      // Or: this layer has produced [kInspireBandSamplerMaxOutstanding] times
      // without the pipeline moving, and one stale band beats an allocator
      // kill.
      picture = cached!;
      if (skipProduction && !sameFrame && !backlogged) {
        _skippedSinceProduction++;
        // The picture is now VALIDATED FOR THIS FRAME: within one frame the
        // render tree is frozen, so the second walk of the double walk takes
        // the `sameFrame` branch above instead of re-walking the signature —
        // and, more importantly, spends no second skip out of the valve's
        // allowance on the same frame.
        if (frame != null) _pictureFrame = frame;
      }
      if (kDebugMode) {
        if (sameFrame) {
          debugInspireBandSamplerPictureReuse++;
        } else if (backlogged) {
          debugInspireBandSamplerStaleBands++;
        } else {
          debugInspireBandSamplerWindowSkips++;
        }
      }
    } else {
      // 1 · THE SNAPSHOT SCENE, FIRST. See the header: the engine layers this
      //     walk flags are discarded with this scene, so the real scene below
      //     carries an unflagged set and an ancestor's `addRetained` is safe.
      _markScene('snapshot');
      final ui.Image source = _snapshotWindow(windowTop, windowH);

      // MANIFEST R · the reduced-resolution band, when asked for and when the
      // band has strong rows to reduce. Otherwise today's two passes, below.
      ui.Picture? reduced;
      if (painter.reducedScale != null) {
        try {
          reduced = _produceReduced(
            source: source,
            windowSize: windowSize,
            windowTop: windowTop,
            bandRect: bandRect,
            bottom: bottom,
            scale: painter.reducedScale!,
            minSigma: painter.reducedMinSigma,
          );
        } catch (_) {
          source.dispose();
          if (kDebugMode) debugInspireLiveSamplerImages--;
          rethrow;
        }
      }
      if (reduced != null) {
        source.dispose();
        if (kDebugMode) debugInspireLiveSamplerImages--;
        // Counted in every build mode, so a profile-build harness can prove
        // the reduced path ran.
        debugInspireBandSamplerReducedProductions++;
        picture = reduced;
      } else {
      // 2 · VERTICAL pass over the band, into a window-sized intermediate. Only
      //     the band's rows are ever read by the horizontal pass, so only the
      //     band's rows are drawn.
      final ui.PictureRecorder vRecorder = ui.PictureRecorder();
      final Canvas vCanvas = Canvas(vRecorder);
      try {
        painter.verticalPass(
            source, windowSize, windowTop, size.height, vCanvas, bandRect);
      } finally {
        source.dispose();
        if (kDebugMode) debugInspireLiveSamplerImages--;
      }
      final ui.Picture vPicture = vRecorder.endRecording();
      // CR-237 #1 · the intermediate holds `bandRect`'s rows only. The H pass
      // then sees a window that STARTS at `cropTop`: its own size, its own
      // `windowTop`, the canvas moved down by the crop and the rect moved up
      // by it — so the mask lookup (`windowTop` + `childHeight`) and the
      // drawn rows are the same rows as before.
      final double cropTop = bandRect.top;
      final double cropH =
          (bandRect.height * devicePixelRatio).ceilToDouble() / devicePixelRatio;
      final ui.Image intermediate = _rasterise(vPicture, cropTop, cropH);
      vPicture.dispose();

      // 3 · HORIZONTAL pass over the band only, into the picture that goes to
      //     the real scene.
      final ui.PictureRecorder hRecorder = ui.PictureRecorder();
      final Canvas hCanvas = Canvas(hRecorder);
      try {
        hCanvas.translate(0, cropTop);
        painter.horizontalPass(
            intermediate,
            Size(size.width, cropH),
            windowTop + cropTop,
            size.height,
            hCanvas,
            bandRect.shift(Offset(0, -cropTop)));
      } finally {
        intermediate.dispose();
        if (kDebugMode) debugInspireLiveSamplerImages--;
      }
      picture = hRecorder.endRecording();
      }
      _lastPicture?.dispose();
      _lastPicture = picture;
      _pictureFrame = frame;
      _pictureKey = key;
      _pictureSignature = signature;
      _skippedSinceProduction = 0;
      _budget.produced();
      if (kDebugMode) {
        debugInspireBandSamplerProductions++;
        if (forcedRefresh) debugInspireBandSamplerForcedRefreshes++;
        debugInspireBandSamplerProduceReason = '${bandAnchor.name}:'
            '${!sameGeometry ? 'geometry' : !gateApplies ? 'gateOff' : signature == null ? 'unknownSig' : forcedRefresh ? 'forced' : 'changed'}';
      }
    }

    // 4 · THE REAL CHILD, straight into the scene, clipped to BELOW the band.
    //     No texture, no resample — this half is what kills the shimmer.
    _markScene('real');
    // ── BB30 · ONE COORDINATE, ONE PRIMITIVE TYPE, TWO COMPLEMENTARY CLIPS ──
    //
    // THE DEFECT (Reo, iPhone 17 Pro, 402x874 — `_audit/dpr3/bb30/`): a dark
    // device row across the full width at the band's foot. The band's edge was
    // rasterised TWICE by two DIFFERENT primitives — a `hardEdge` clip whose
    // top was `band`, and the non-antialiased `drawRect` of the band picture
    // whose bottom was `band`. `_snap` puts `band` on the device grid of THIS
    // LAYER, but the layer's position in the scene carries whatever
    // sub-device-pixel offset its ancestors have (a sheet's top inset, an
    // entrance animation, a fractional safe area). When that offset landed the
    // shared edge on a pixel CENTRE the two coverage tests broke the tie in
    // opposite directions and neither painted the row.
    //
    // THE FIRST FIX WAS WRONG AND IS WHY THIS COMMENT IS LONG. Overlapping the
    // child's clip one row INTO the band closed the hole — and made that row
    // painted TWICE. Over an opaque child `src-over` against itself is a no-op,
    // so every rig here missed it; over a TRANSLUCENT child (which is what the
    // leaderboard sheet actually is — `MnAlpha.surfaceSoft` over glass) it
    // composites to `2a - a^2`: alpha 10% read 26 -> 49, alpha 50% read
    // 128 -> 192, at EVERY offset, and it is visible in this round's own
    // simulator capture at row 551. A row must be painted EXACTLY ONCE; an
    // overlap can never be that, because no second painter can contribute
    // "nothing" on exactly the rows the first one covers.
    //
    // Nor can the shader be asked to withdraw there. `MIN_SIGMA` is 1e-2 and
    // the mask's zero floor is red 2, i.e. sigma `2/255 * 14.667 = 0.115` —
    // ABOVE the threshold — so the pass-through branch begins only BELOW
    // `band`, where the picture paints nothing anyway. An "emit transparent at
    // or under the zero floor" uniform would be a no-op against this defect.
    //
    // SO THE SEAM IS PARTITIONED, NOT OVERLAPPED, AND BOTH SIDES GO THROUGH THE
    // SAME CALL WITH THE SAME NUMBER: `pushClipRect(..., Clip.hardEdge)` at
    // `band`, once as a top edge and once as a bottom edge. Identical
    // coordinate through identical code means whatever rounding the rasteriser
    // applies lands on the SAME device row for both, and a half-open interval
    // pair `[band, h)` / `[0, band)` around one rounded value is complementary
    // by construction — no tie to break, no row shared. The band picture's own
    // rect is deliberately drawn PAST the seam (`bandRect` below) so its edge
    // is not at the boundary at all and cannot disagree with anything.
    //
    // MEASURED both ways (`_audit/dpr3/bb30/NUMBERS.md`): heights 780..900 step
    // 4 x four sub-pixel offsets x three child alphas, two-sided predicate —
    // zero rows lost AND zero rows doubled.
    //
    // BB37 · THE PARTITION IS ANCHOR-SYMMETRIC. `seam` is the one coordinate;
    // the child takes the half-open interval on its side of it and the band
    // takes the other, through the SAME `pushClipRect` call either way. A top
    // band splits `[0, seam)` band / `[seam, h)` child; a bottom band splits
    // `[0, seam)` child / `[seam, h)` band. Complementary by construction at
    // both anchors, for the same reason: one rounded value, two half-open
    // intervals, no tie to break.
    _pushOffsetRetained(builder);
    // MANIFEST (divergence 6) · the real child may reach `realUnderlap` px INTO
    // the band, UNDER the band picture (step 5 paints over it). Nothing of it
    // shows through an opaque picture, and a `BackdropFilter` straddling the
    // seam now reads the scene it would read with no band at all. Zero keeps the
    // clip a half-open interval complementary to the band's, byte for byte.
    final double underlap = realUnderlap <= 0.0
        ? 0.0
        : math.min(realUnderlap, bottom ? size.height - seam : seam);
    final Rect childClip = underlap == 0.0
        ? (bottom
            ? Rect.fromLTRB(0, 0, size.width, seam)
            : Rect.fromLTRB(0, seam, size.width, size.height))
        : (bottom
            ? Rect.fromLTRB(0, 0, size.width, seam + underlap)
            : Rect.fromLTRB(0, seam - underlap, size.width, size.height));
    final Rect bandClip = bottom
        ? Rect.fromLTRB(0, seam, size.width, size.height)
        : Rect.fromLTRB(0, 0, size.width, seam);
    final bool clipsChild = band < size.height;
    if (clipsChild) {
      // BB65 (audit, D8) · THE SECOND `_forceReAdd` BELONGS TO THE SECOND WALK,
      // NOT TO THE FRAME. It used to sit above this `if`, and on the one path
      // where there IS no second walk — `band >= size.height`, i.e. the band
      // covers the whole child, reachable at `extent` just under 1.0 because
      // `_snap` rounds up onto the device grid — it dirtied the subtree and
      // then nothing re-added it. A frame that ends with this layer's subtree
      // dirty is exactly the BB64 loop: the framework ORs that flag upward, we
      // are dirty again next frame, and the layer rasterises two window-sized
      // targets forever. Scoping the force to the walk it protects removes the
      // path. (The invariant it protects is unchanged: the snapshot walk above
      // is preceded by the force at the top of `addToScene`, and the real walk
      // below by this one.)
      _forceReAdd(firstChild);
      builder.pushClipRect(childClip, clipBehavior: Clip.hardEdge);
      addChildrenToScene(builder);
      builder.pop();
    }

    // 5 · THE BAND on top, clipped by the SAME `seam` through the SAME call.
    //     The picture is window-local, so it lands at the window's origin.
    builder.pushClipRect(bandClip, clipBehavior: Clip.hardEdge);
    builder.addPicture(Offset(0, windowTop), picture);
    if (kDebugMode) debugInspireBandSamplerComposites++;
    builder.pop();
    builder.pop();

    // ── BB64 · THE FRAME ENDS WITH THE SUBTREE CLEAN, AND THAT IS THE FIX ────
    //
    // There used to be a THIRD `_forceReAdd(firstChild)` here, "so no
    // descendant carries a stale `_engineLayer` into the next frame's retained
    // path". It was the reason this layer produced a band on EVERY frame of
    // the process's life.
    //
    // `markNeedsAddToScene` only sets the child's own flag; the framework
    // propagates it UPWARD on the next frame, in `ContainerLayer
    // .updateSubtreeNeedsAddToScene`, which ORs every child's flag into its
    // parent's. So a subtree left dirty at the end of frame N makes THIS layer
    // dirty at the start of frame N+1 — no matter what the child actually did —
    // and a dirty layer never takes `addRetained`: its `addToScene` runs, and
    // this one rasterises two window-sized render targets when it does. The
    // loop is self-sustaining and does not need any repaint to feed it.
    //
    // MEASURED (`test/probe/dust_probe.dart`, MN_PROBE_IDLE=1 — the ticker
    // keeps vsync coming and NOTHING in the tree repaints, 600 frames, macOS
    // debug, shipped `MnShaderFade`-around-`MnScrollRamp` composition):
    //
    //   with the trailing force    prod=1194  bandTex=2388  scenes=1791
    //   without it                 prod=2     bandTex=4     scenes=3
    //
    // i.e. exactly 2 productions per frame against 2 for the whole run.
    //
    // AND IT WAS REDUNDANT, which is why removing it is not a trade. The
    // invariant it protects — both walks of the double walk must be REAL, never
    // `addRetained`, because a retained engine layer cannot be added to two
    // scenes — is established by the two `_forceReAdd` calls that remain: the
    // one at the top of `addToScene`, before the snapshot walk, and the one
    // before the real walk. Whatever state the subtree is in when a frame
    // reaches us, the first thing we do is dirty it. Ending the frame dirty
    // added nothing except the next frame's production.
  }
}

/// CR-237 #4 · MARKS A BACKGROUND ONE BAND ANCHOR MAY STOP RE-BLURRING FOR.
///
/// An animated background (a sky shader) repaints every frame, and the BB65
/// window signature therefore sees a changed window every frame, so a band over
/// it re-snapshots and re-blurs forever on a screen nobody is touching. When
/// the band's OUTPUT has been measured not to depend on that motion (the
/// background's moving part never reaches the band, or is covered there), the
/// background can be wrapped in this widget: a band anchored at [exemptFrom]
/// then hashes only this subtree's OFFSET, never its content. Everything else
/// in its window is still hashed exactly as before, so a scroll, a dock show or
/// hide (painter/geometry), or any content change under the band still produces
/// on that frame, and the BB65 valve still forces a production every
/// `kInspireBandWindowMaxSkips + 1` frames.
///
/// It is a repaint boundary, so the subtree gets its own layer; every OTHER
/// band (and any band without this widget in its window) sees it as a plain
/// [OffsetLayer]. THIS IS A LOOK DECISION THE CALLER OWNS: if the background's
/// motion does reach the band, the band shows it up to that many frames late.
class InspireBandBackground extends SingleChildRenderObjectWidget {
  const InspireBandBackground({
    super.key,
    required this.exemptFrom,
    required Widget super.child,
  });

  /// The band anchor that does not re-blur for this subtree's content.
  final InspireBandAnchor exemptFrom;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderInspireBandBackground(exemptFrom);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderInspireBandBackground).exemptFrom = exemptFrom;
  }
}

class _RenderInspireBandBackground extends RenderProxyBox {
  _RenderInspireBandBackground(this._exemptFrom);

  InspireBandAnchor _exemptFrom;
  set exemptFrom(InspireBandAnchor value) {
    if (value == _exemptFrom) return;
    _exemptFrom = value;
    markNeedsCompositedLayerUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  OffsetLayer updateCompositedLayer({
    required covariant _InspireBandBackgroundLayer? oldLayer,
  }) =>
      (oldLayer ?? _InspireBandBackgroundLayer())..exemptFrom = _exemptFrom;
}

class _InspireBandBackgroundLayer extends OffsetLayer {
  InspireBandAnchor? _exemptFrom;
  InspireBandAnchor? get exemptFrom => _exemptFrom;
  set exemptFrom(InspireBandAnchor? value) {
    if (value == _exemptFrom) return;
    _exemptFrom = value;
    markNeedsAddToScene();
  }
}
