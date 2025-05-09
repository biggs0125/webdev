// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:build/build.dart';

/// Factory for the build script.
Builder copyBuilder(_) => _CopyBuilder();

class _CopyBuilder extends Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    'web/{{}}.dart.js': ['compiled/{{}}.dart.js'],
    'web/static_assets/{{}}.png': ['compiled/static_assets/{{}}.png'],
    'web/static_assets/{{}}.html': ['compiled/static_assets/{{}}.html'],
    'web/static_assets/{{}}.css': ['compiled/static_assets/{{}}.css'],
    'web/manifest.json': ['compiled/manifest.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputAsset = buildStep.inputId;
    final allowedOutputs = buildStep.allowedOutputs;

    if (allowedOutputs.length != 1) {
      return;
    }

    final outputAsset = allowedOutputs.first;
    await _copyBinaryFile(
      buildStep,
      inputAsset: inputAsset,
      outputAsset: outputAsset,
    );
  }

  Future<void> _copyBinaryFile(
    BuildStep buildStep, {
    required AssetId inputAsset,
    required AssetId outputAsset,
  }) {
    return buildStep.writeAsBytes(
      outputAsset,
      buildStep.readAsBytes(inputAsset),
    );
  }
}
