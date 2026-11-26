/// Inspire Blur provides high-performance progressive and variable blur
/// effects for Flutter.
///
/// The package includes:
/// * Child blur and backdrop blur widgets
/// * Directional and shape-based blur distributions
/// * Tint effects
/// * GPU shader-powered rendering optimized for Impeller
///
/// Designed for building modern, visually rich Flutter interfaces.
library;

export 'src/animation/animated_inspire_backdrop_blur.dart'
    show AnimatedInspireBackdropBlur;
export 'src/animation/animated_inspire_child_blur.dart'
    show AnimatedInspireChildBlur;
export 'src/color_adjustment/blur_color_adjustment.dart'
    show BlurColorAdjustment;
export 'src/distribution/distribution.dart';
// BB27 · vendor divergence 4. See src/child_blur/inspire_child_blur_band_sampler.dart.
export 'src/child_blur/inspire_child_blur_band_sampler.dart'
    show
        InspireBandAnchor,
        InspireBandSpan,
        InspireChildBlurBandSampler,
        InspireBandBackground,
        debugInspireBandSamplerComposites,
        debugInspireBandSamplerDraws,
        debugInspireBandSamplerForcedRefreshes,
        debugInspireBandSamplerGeometry,
        debugInspireBandSamplerPictureReuse,
        debugInspireBandSamplerTextures,
        debugInspireBandSamplerTargetPixels,
        debugInspireBandSamplerPaintAnchor,
        debugInspireBandSamplerPaints,
        debugInspireBandSamplerScenes,
        debugInspireBandSamplerProduceReason,
        debugInspireBandSamplerProductions,
        debugInspireBandSamplerMarks,
        debugInspireBandSamplerReasons,
        debugInspireBandSamplerSceneOrder,
        debugInspireBandSamplerStaleBands,
        debugInspireBandSamplerWindowSkips,
        debugInspireBandTightWindowDisabled,
        debugInspireBandWindowGateDisabled,
        debugInspireBandSamplerWindowUnknown,
        debugInspireExactInteriorOneA,
        debugInspireBandSamplerReducedProductions,
        inspireBandSamplerReach,
        inspireBandSamplerTightWindowHeight,
        inspireBandSamplerWindowHeight,
        kInspireBandWindowMaxSkips;
// BB61 · vendor divergence 4e. The one production budget, and the bounded
// whole-child sampler the FALLBACK composition draws through.
export 'src/child_blur/inspire_bounded_sampler.dart'
    show
        InspireBoundedSampler,
        InspireProductionBudget,
        InspireTextureLedger,
        debugInspireBoundedSamplerComposites,
        debugInspireBoundedSamplerPictureReuse,
        debugInspireBoundedSamplerScenes,
        debugInspireBoundedSamplerStalePictures,
        debugInspireBoundedSamplerTargets,
        debugInspireLiveSamplerImages,
        debugInspireOutstandingTextures,
        kInspireBandSamplerMaxOutstanding,
        kInspireMaxOutstandingTextures;
export 'src/inspire_backdrop_blur.dart' show InspireBackdropBlur;
export 'src/inspire_blur.dart' show Inspire;
export 'src/inspire_blur_config.dart'
    show InspireBlurConfig, InspireKernelSampling;
export 'src/inspire_blur_mode.dart' show InspireBlurMode;
export 'src/inspire_child_blur.dart' show InspireChildBlur;
export 'src/inspire_tint_api.dart' show InspireTintApi;
export 'src/model/blur_edge_fade.dart' show BlurEdgeFade;
export 'src/model/blur_scale.dart' show BlurScale;
export 'src/model/distribution_blend.dart';
export 'src/model/distribution_fit.dart' show DistributionFit;
export 'src/model/progression/progression.dart'
    show Progression, CustomProgression, GradientProgression;
export 'src/opacity/widget_opacity.dart' show WidgetOpacity;
export 'src/transform/blur_transform.dart' show BlurTransform;
