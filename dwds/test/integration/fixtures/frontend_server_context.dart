// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:dwds/asset_reader.dart';
import 'package:dwds/data/build_result.dart';
import 'package:dwds/expression_compiler.dart';
import 'package:dwds/src/loaders/frontend_server_strategy_provider.dart';
import 'package:dwds/src/loaders/strategy.dart';
import 'package:dwds/src/utilities/server.dart';
import 'package:dwds_test_common/utilities.dart';
import 'package:file/local.dart';
import 'package:logging/logging.dart' as logging;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../frontend_server_common/resident_runner.dart';
import 'context.dart';
import 'utilities.dart';

class FrontendServerTestContext extends TestContext {
  ResidentWebRunner? _webRunner;
  AssetReader? _assetReader;
  Handler? _assetHandler;
  LoadStrategy? _loadStrategy;
  ExpressionCompiler? _expressionCompiler;
  final Stream<BuildResult> _buildResults = const Stream<BuildResult>.empty();

  late LocalFileSystem frontendServerFileSystem;
  late String _hostname;
  late String _filePathToServe;

  final _logger = logging.Logger('FrontendServerContext');

  FrontendServerTestContext(super.project, super.sdkConfigurationProvider)
    : super.protected();

  @override
  String get appUrlPath =>
      webCompatiblePath([project.directoryToServe, project.filePathToServe]);

  @override
  String get basePath => webRunner.devFS!.assetServer.basePath;

  @override
  bool get usesFrontendServer => true;

  ResidentWebRunner get webRunner => _webRunner!;

  @override
  AssetReader get assetReader => _assetReader!;

  @override
  Handler get assetHandler => _assetHandler!;

  @override
  LoadStrategy get loadStrategy => _loadStrategy!;

  @override
  ExpressionCompiler? get expressionCompiler => _expressionCompiler;

  @override
  Stream<BuildResult> get buildResults => _buildResults;

  @override
  Future<void> modeSetUp(
    TestSettings testSettings,
    TestDebugSettings debugSettings,
    TestAppMetadata appMetadata,
    Uri reloadedSourcesUri,
  ) async {
    final sdkLayout = sdkConfigurationProvider.sdkLayout;
    final buildSettings = TestBuildSettings(
      appEntrypoint: project.dartEntryFilePackageUri,
      canaryFeatures: testSettings.canaryFeatures,
      isFlutterApp: testSettings.isFlutterApp,
      experiments: testSettings.experiments,
    );

    _filePathToServe = webCompatiblePath([
      project.directoryToServe,
      project.filePathToServe,
    ]);

    _logger.info('Serving: $_filePathToServe');

    final entry = p.toUri(
      p.join(project.webAssetsPath, project.dartEntryFileName),
    );
    frontendServerFileSystem = const LocalFileSystem();
    final packageUriMapper = await PackageUriMapper.create(
      frontendServerFileSystem,
      project.packageConfigFile,
      useDebuggerModuleNames: testSettings.useDebuggerModuleNames,
    );

    final compilerOptions = TestCompilerOptions(
      experiments: buildSettings.experiments,
      canaryFeatures: buildSettings.canaryFeatures,
      moduleFormat: testSettings.moduleFormat,
    );

    _webRunner = ResidentWebRunner(
      mainUri: entry,
      urlTunneler: debugSettings.urlEncoder,
      projectDirectory: Directory(project.absolutePackageDirectory).uri,
      packageConfigFile: project.packageConfigFile,
      packageUriMapper: packageUriMapper,
      fileSystemRoots: [Directory(project.absolutePackageDirectory).uri],
      fileSystemScheme: 'org-dartlang-app',
      outputPath: outputDir.path,
      compilerOptions: compilerOptions,
      sdkLayout: sdkLayout,
      verbose: testSettings.verboseCompiler,
    );

    final assetServerPort = await findUnusedPort();
    _hostname = appMetadata.hostname;
    await webRunner.run(
      frontendServerFileSystem,
      hostname: _hostname,
      port: assetServerPort,
      index: _filePathToServe,
    );

    if (testSettings.enableExpressionEvaluation) {
      _expressionCompiler = webRunner.expressionCompiler;
    }

    _assetReader = webRunner.devFS!.assetServer;
    _assetHandler = webRunner.devFS!.assetServer.handleRequest;

    _loadStrategy = switch (testSettings.moduleFormat) {
      ModuleFormat.amd => FrontendServerRequireStrategyProvider(
        testSettings.reloadConfiguration,
        assetReader,
        packageUriMapper,
        () async => {},
        buildSettings,
      ).strategy,
      ModuleFormat.ddc =>
        buildSettings.canaryFeatures
            ? FrontendServerDdcLibraryBundleStrategyProvider(
                testSettings.reloadConfiguration,
                assetReader,
                packageUriMapper,
                () async => {},
                buildSettings,
                reloadedSourcesUri: reloadedSourcesUri,
              ).strategy
            : FrontendServerDdcStrategyProvider(
                testSettings.reloadConfiguration,
                assetReader,
                packageUriMapper,
                () async => {},
                buildSettings,
              ).strategy,
      _ => throw Exception(
        'Unsupported DDC module format ${testSettings.moduleFormat.name}.',
      ),
    };
  }

  @override
  Future<void> modeTearDown() async {
    await _webRunner?.stop();
  }

  @override
  Future<void> recompile({required bool fullRestart}) async {
    await webRunner.rerun(
      fullRestart: fullRestart,
      fileServerUri: Uri.parse('http://${testServer.host}:${testServer.port}'),
    );
  }
}
