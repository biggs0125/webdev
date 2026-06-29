// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:build_daemon/client.dart';
import 'package:build_daemon/data/build_status.dart' as daemon;
import 'package:build_daemon/data/build_target.dart';
import 'package:dwds/asset_reader.dart';
import 'package:dwds/data/build_result.dart';
import 'package:dwds/expression_compiler.dart';
import 'package:dwds/src/loaders/frontend_server_strategy_provider.dart';
import 'package:dwds/src/loaders/strategy.dart';
import 'package:dwds/src/readers/proxy_server_asset_reader.dart';
import 'package:dwds/src/services/expression_compiler.dart';
import 'package:dwds/src/services/expression_compiler_service.dart';
import 'package:dwds_test_common/fixtures/context.dart';
import 'package:dwds_test_common/fixtures/utilities.dart';
import 'package:file/local.dart';
import 'package:logging/logging.dart' as logging;
import 'package:shelf/shelf.dart';
import 'package:shelf_proxy/shelf_proxy.dart';

import 'build_daemon_context.dart';

class LibraryBundleTestContext extends TestContext {
  BuildDaemonClient? _daemonClient;
  ExpressionCompilerService? _ddcService;
  AssetReader? _assetReader;
  Handler? _assetHandler;
  LoadStrategy? _loadStrategy;
  final Stream<BuildResult> _buildResults = const Stream<BuildResult>.empty();

  late LocalFileSystem frontendServerFileSystem;

  final _logger = logging.Logger('LibraryBundleContext');

  LibraryBundleTestContext(super.project, super.sdkConfigurationProvider)
    : super.protected();

  @override
  String get appUrlPath => project.filePathToServe;

  @override
  bool get usesFrontendServer => true;
  @override
  bool get usesBuildDaemon => true;
  @override
  bool get usesDdcModulesOnly => true;

  BuildDaemonClient get daemonClient => _daemonClient!;

  @override
  AssetReader get assetReader => _assetReader!;

  @override
  Handler get assetHandler => _assetHandler!;

  @override
  LoadStrategy get loadStrategy => _loadStrategy!;

  @override
  ExpressionCompiler? get expressionCompiler => _ddcService;

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

    final options = [
      if (testSettings.enableExpressionEvaluation) ...[
        '--define',
        'build_web_compilers|ddc=generate-full-dill=true',
      ],
      for (final experiment in buildSettings.experiments)
        '--enable-experiment=$experiment',
      '--define',
      'build_web_compilers|ddc=canary=true',
      '--define',
      'build_web_compilers|sdk_js=canary=true',
      '--define',
      'build_web_compilers|sdk_js=web-hot-reload=true',
      '--define',
      'build_web_compilers|entrypoint=web-hot-reload=true',
      '--define',
      'build_web_compilers|entrypoint_marker=web-hot-reload=true',
      '--define',
      'build_web_compilers|entrypoint_marker=web-assets-path='
          '${project.webAssetsPath}',
      '--define',
      'build_web_compilers|ddc=web-hot-reload=true',
      '--define',
      'build_web_compilers|ddc_modules=web-hot-reload=true',
      '--verbose',
    ];

    _daemonClient = await connectClient(
      sdkLayout.dartPath,
      project.absolutePackageDirectory,
      options,
      (log) {
        final record = log.toLogRecord();
        final name = record.loggerName == '' ? '' : '${record.loggerName}: ';
        _logger.log(
          record.level,
          '$name${record.message}',
          record.error,
          record.stackTrace,
        );
      },
    );

    daemonClient.registerBuildTarget(
      DefaultBuildTarget((b) => b..target = project.directoryToServe),
    );
    daemonClient.startBuild();

    await waitForSuccessfulBuild();

    final assetServerPort = daemonPort(project.absolutePackageDirectory);
    _assetHandler = proxyHandler(
      'http://localhost:$assetServerPort/${project.directoryToServe}/',
      client: client,
    );

    if (testSettings.moduleFormat == ModuleFormat.ddc &&
        buildSettings.canaryFeatures) {
      _assetHandler = handleReloadedSources(_assetHandler!);
    }

    _assetReader = ProxyServerAssetReader(
      assetServerPort,
      root: project.directoryToServe,
    );

    if (testSettings.enableExpressionEvaluation) {
      _ddcService = ExpressionCompilerService(
        'localhost',
        port,
        verbose: testSettings.verboseCompiler,
        sdkConfigurationProvider: sdkConfigurationProvider,
      );
    }

    frontendServerFileSystem = const LocalFileSystem();
    final packageUriMapper = await PackageUriMapper.create(
      frontendServerFileSystem,
      project.packageConfigFile,
      useDebuggerModuleNames: testSettings.useDebuggerModuleNames,
    );

    _loadStrategy = switch ((
      testSettings.moduleFormat,
      buildSettings.canaryFeatures,
    )) {
      (ModuleFormat.ddc, true) =>
        FrontendServerDdcLibraryBundleStrategyProvider(
          testSettings.reloadConfiguration,
          assetReader,
          packageUriMapper,
          () async => {},
          buildSettings,
          injectScriptLoad: false,
          reloadedSourcesUri: reloadedSourcesUri,
        ).strategy,
      _ => throw Exception(
        'Unsupported DDC module format when compiling with Frontend '
        'Server + build_runner ${testSettings.moduleFormat.name}.',
      ),
    };
  }

  @override
  Future<void> modeTearDown() async {
    await _daemonClient?.close();
    await _ddcService?.stop();
  }

  @override
  Future<void> waitForSuccessfulBuild({
    Duration? timeout,
    bool propagateToBrowser = false,
  }) async {
    await daemonClient.buildResults
        .firstWhere(
          (daemon.BuildResults results) => results.results.any(
            (daemon.BuildResult result) =>
                result.status == daemon.BuildStatus.succeeded,
          ),
        )
        .timeout(timeout ?? const Duration(seconds: 60));

    if (propagateToBrowser) {
      final delay = Platform.isWindows
          ? const Duration(seconds: 5)
          : const Duration(seconds: 2);
      await Future<void>.delayed(delay);
    }
  }
}
