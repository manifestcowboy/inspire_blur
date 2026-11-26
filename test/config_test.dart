import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inspire_blur/src/distribution/distribution.dart';
import 'package:inspire_blur/src/inspire_blur_config.dart';

import 'test_core.dart';

void main() {
  InspireBlurConfig mockValidConfig() => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      );

  test('Constructor accepts valid configs', () {
    final configWithSigma = InspireBlurConfig(
      sigma: 1,
      blurDistribution: DirectionalDistribution(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    );

    final configWithSigmaX = InspireBlurConfig(
      sigmaX: 2,
      blurDistribution: DirectionalDistribution(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    );

    final configWithSigmaY = InspireBlurConfig(
      sigmaY: 3,
      blurDistribution: DirectionalDistribution(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    );

    final configWithSigmaXY = InspireBlurConfig(
      sigmaX: 5,
      sigmaY: 8,
      blurDistribution: DirectionalDistribution(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    );

    expect(configWithSigma.sigma, equals(1));
    expect(configWithSigmaX.sigmaX, equals(2));
    expect(configWithSigmaY.sigmaY, equals(3));
    expect(configWithSigmaXY.sigmaX, equals(5));
    expect(configWithSigmaXY.sigmaY, equals(8));
  });

  test('Allows sigmaX without sigmaY', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaX: 5),
      returnsNormally,
    );
  });

  test('Allows sigmaY without sigmaX', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaY: 5),
      returnsNormally,
    );
  });

  test('Constructor throws when no sigma provided', () {
    expect(
      () => InspireBlurConfig(
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      throwsAssertionError,
    );
  });

  test('Constructor throws when all sigma values provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        sigmaX: 5,
        sigmaY: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      throwsAssertionError,
    );
  });

  test('copyWith throws when all sigma values provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(
        sigmaX: 5,
        sigmaY: 5,
      ),
      throwsAssertionError,
    );
  });

  test('Constructor throws when both sigma and sigmaX provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        sigmaX: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      throwsAssertionError,
    );
  });

  test('copyWith throws when both sigma and sigmaX provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigmaX: 5),
      throwsAssertionError,
    );
  });

  test('Constructor throws when both sigma and sigmaY provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        sigmaY: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      throwsAssertionError,
    );
  });

  test('copyWith throws when both sigma and sigmaY provided at once', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigmaY: 5),
      throwsAssertionError,
    );
  });

  test('Constructor throws when sigma is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigma: -1),
      throwsAssertionError,
    );
  });

  test('copyWith throws when sigma is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigma: 5).copyWith(sigma: -5),
      throwsAssertionError,
    );
  });

  test('Constructor throws when sigmaX is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaX: -1),
      throwsAssertionError,
    );
  });

  test('copyWith throws when sigmaX is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaX: 5).copyWith(sigmaX: -5),
      throwsAssertionError,
    );
  });

  test('Constructor throws when sigmaY is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaY: -1),
      throwsAssertionError,
    );
  });

  test('copyWith throws when sigmaY is negative', () {
    expect(
      () => InspireBlurConfig.topToBottom(sigmaY: 5).copyWith(sigmaY: -5),
      throwsAssertionError,
    );
  });

  test('Horizontal and vertical sigma is derived correctly from one', () {
    final config = InspireBlurConfig.topToBottom(sigma: 5);

    expect(config.effectiveSigmaX, 5);
    expect(config.effectiveSigmaY, 5);
  });

  test('Horizontal and vertical sigma is derived correctly from separate', () {
    final config = InspireBlurConfig.topToBottom(sigmaX: 5, sigmaY: 13);

    expect(config.effectiveSigmaX, 5);
    expect(config.effectiveSigmaY, 13);
  });

  test('One-directional horizontal sigma is applied correctly', () {
    final config = InspireBlurConfig.topToBottom(sigmaX: 8);

    expect(config.effectiveSigmaX, 8);
    expect(config.effectiveSigmaY, null);
  });

  test('One-directional vertical sigma is applied correctly', () {
    final config = InspireBlurConfig.topToBottom(sigmaY: 8);

    expect(config.effectiveSigmaX, null);
    expect(config.effectiveSigmaY, 8);
  });

  test('Only sigma is replaced by copyWith', () {
    final originalConfig = mockValidConfig();
    final newConfig = originalConfig.copyWith(sigma: 34);

    expect(newConfig.sigma, equals(34));
    expect(newConfig.sigmaX, equals(originalConfig.sigmaX));
    expect(newConfig.sigmaY, equals(originalConfig.sigmaY));
    expect(newConfig.blurDistribution, equals(originalConfig.blurDistribution));
  });

  test('No values are replaced by copyWith when nulls are passed', () {
    final config = InspireBlurConfig(
      sigma: 21,
      blurDistribution: DirectionalDistribution(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    );
    final copiedConfig = config.copyWith();

    expect(copiedConfig.sigma, equals(21));
    expect(copiedConfig.blurDistribution, equals(config.blurDistribution));
  });

  test('copyWith throws when too many or no sigma provided', () {
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigmaX: 5),
      throwsAssertionError,
    );
    expect(
      () => InspireBlurConfig(
        sigma: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigmaY: 5),
      throwsAssertionError,
    );
    expect(
      () => InspireBlurConfig(
        sigmaX: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigma: 5),
      throwsAssertionError,
    );
    expect(
      () => InspireBlurConfig(
        sigmaY: 5,
        blurDistribution: DirectionalDistribution(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ).copyWith(sigma: 5),
      throwsAssertionError,
    );
  });

  test('onlyHorizontal overrides sigma correctly', () {
    final config = InspireBlurConfig.topToBottom(sigma: 5);

    final result = config.onlyHorizontal(10);

    expect(result.sigma, null);
    expect(result.sigmaX, 10);
    expect(result.sigmaY, null);
  });

  test('onlyVertical overrides sigma correctly', () {
    final config = InspireBlurConfig.topToBottom(sigma: 5);

    final result = config.onlyVertical(10);

    expect(result.sigma, null);
    expect(result.sigmaX, null);
    expect(result.sigmaY, 10);
  });

  test('Configs with different values are not equal', () {
    /// Different [sigma] value
    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.topToBottom(sigma: 10))));

    /// Different [sigma] and [sigmaX] values
    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.topToBottom(sigmaX: 5))));

    /// Different [sigma] and [sigmaY] values
    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.topToBottom(sigmaY: 5))));
  });

  test('Configs with same values are equal', () {
    /// Same [sigma] value
    expect(InspireBlurConfig.topToBottom(sigma: 5),
        equals(InspireBlurConfig.topToBottom(sigma: 5)));

    /// Same [sigmaX] value
    expect(InspireBlurConfig.topToBottom(sigmaX: 5),
        equals(InspireBlurConfig.topToBottom(sigmaX: 5)));

    /// Same [sigmaY] value
    expect(InspireBlurConfig.topToBottom(sigmaY: 5),
        equals(InspireBlurConfig.topToBottom(sigmaY: 5)));
  });

  test('Configs with same values have same hashCode', () {
    /// Same [sigma] value
    expect(InspireBlurConfig.topToBottom(sigma: 5).hashCode,
        equals(InspireBlurConfig.topToBottom(sigma: 5).hashCode));

    /// Same [sigmaX] value
    expect(InspireBlurConfig.topToBottom(sigmaX: 5).hashCode,
        equals(InspireBlurConfig.topToBottom(sigmaX: 5).hashCode));

    /// Same [sigmaY] value
    expect(InspireBlurConfig.topToBottom(sigmaY: 5).hashCode,
        equals(InspireBlurConfig.topToBottom(sigmaY: 5).hashCode));
  });

  test('Configs with different directions are not equal', () {
    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.bottomToTop(sigma: 5))));

    expect(InspireBlurConfig.leftToRight(sigma: 5),
        isNot(equals(InspireBlurConfig.rightToLeft(sigma: 5))));

    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.leftToRight(sigma: 5))));

    expect(InspireBlurConfig.topToBottom(sigma: 5),
        isNot(equals(InspireBlurConfig.solid(sigma: 5))));
  });

  test('topToBottom produces correct config', () {
    final config = InspireBlurConfig.topToBottom(sigma: 5);

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.begin, Alignment.topCenter);
    expect(distribution.end, Alignment.bottomCenter);
    final samples = [
      for (var i = 0; i <= 10; i++) distribution.progression.samplePoint(i / 10)
    ];
    expect(samples.first, 1.0);
    expect(samples.last, 0.0);
    expectDecreasing(samples);
  });

  test('bottomToTop produces correct config', () {
    final config = InspireBlurConfig.bottomToTop(sigma: 5);

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.begin, Alignment.bottomCenter);
    expect(distribution.end, Alignment.topCenter);
    final samples = [
      for (var i = 0; i <= 10; i++) distribution.progression.samplePoint(i / 10)
    ];
    expect(samples.first, 1.0);
    expect(samples.last, 0.0);
    expectDecreasing(samples);
  });

  test('leftToRight produces correct config', () {
    final config = InspireBlurConfig.leftToRight(sigma: 5);

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.begin, Alignment.centerLeft);
    expect(distribution.end, Alignment.centerRight);
    final samples = [
      for (var i = 0; i <= 10; i++) distribution.progression.samplePoint(i / 10)
    ];
    expect(samples.first, 1.0);
    expect(samples.last, 0.0);
    expectDecreasing(samples);
  });

  test('rightToLeft produces correct config', () {
    final config = InspireBlurConfig.rightToLeft(sigma: 5);

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.begin, Alignment.centerRight);
    expect(distribution.end, Alignment.centerLeft);
    final samples = [
      for (var i = 0; i <= 10; i++) distribution.progression.samplePoint(i / 10)
    ];
    expect(samples.first, 1.0);
    expect(samples.last, 0.0);
    expectDecreasing(samples);
  });

  test('directional produces correct config', () {
    final config = InspireBlurConfig.directional(
      sigma: 5,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.begin, Alignment.topLeft);
    expect(distribution.end, Alignment.bottomRight);
    final samples = [
      for (var i = 0; i <= 10; i++) distribution.progression.samplePoint(i / 10)
    ];
    expect(samples.first, 1.0);
    expect(samples.last, 0.0);
    expectDecreasing(samples);
  });

  test('uniform produces correct config', () {
    final config = InspireBlurConfig.solid(sigma: 5);

    expect(config.sigma, 5);
    expect(config.sigmaX, null);
    expect(config.sigmaY, null);

    expect(config.blurDistribution, isA<UniformDistribution>());
  });

  test('Throws when fadeStart is after fadeEnd', () {
    expect(
      () => InspireBlurConfig.topToBottom(fadeStart: 0.6, fadeEnd: 0.4),
      throwsAssertionError,
    );
    expect(
      () => InspireBlurConfig.directional(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        fadeStart: 0.6,
        fadeEnd: 0.4,
      ),
      throwsAssertionError,
    );
  });

  test('fadeEnd == 0 produces a hard edge at the start', () {
    final config = InspireBlurConfig.topToBottom(
      sigma: 5,
      fadeEnd: 0.0,
    );

    final distribution = config.blurDistribution as DirectionalDistribution;

    expect(distribution.progression.samplePoint(0.5), 0.0);
    expect(distribution.progression.samplePoint(1.0), 0.0);
  });
}
