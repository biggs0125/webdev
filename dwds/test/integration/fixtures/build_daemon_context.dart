// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:build_daemon/client.dart';
import 'package:build_daemon/constants.dart';
import 'package:build_daemon/data/build_status.dart' as daemon;
import 'package:build_daemon/data/build_target.dart';
import 'package:build_daemon/data/server_log.dart';
import 'package:dwds/asset_reader.dart';
import 'package:dwds/data/build_result.dart';
import 'package:dwds/expression_compiler.dart';
import 'package:dwds/src/loaders/build_runner_strategy_provider.dart';
import 'package:dwds/src/loaders/strategy.dart';
import 'package:dwds/src/readers/proxy_server_asset_reader.dart';
import 'package:dwds/src/services/expression_compiler.dart';
import 'package:dwds/src/services/expression_compiler_service.dart';
import 'package:dwds_test_common/fixtures/context.dart';
import 'package:dwds_test_common/fixtures/utilities.dart';
import 'package:logging/logging.dart' as logging;
import 'package:shelf/shelf.dart';
import 'package:shelf_proxy/shelf_proxy.dart';

class BuildDaemonTestContext extends TestContext {
  BuildDaemonClient? _daemonClient;
  ExpressionCompilerService? _ddcService;
  AssetReader? _assetReader;
  Handler? _assetHandler;
  LoadStrategy? _loadStrategy;
  Stream<BuildResult>? _buildResults;

  final _logger = logging.Logger('BuildDaemonContext');

  BuildDaemonTestContext(super.project, super.sdkConfigurationProvider)
    : super.protected();

  @override
  String get appUrlPath => project.filePathToServe;

  @override
  bool get usesBuildDaemon => true;

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
  Stream<BuildResult> get buildResults => _buildResults!;

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
      if (buildSettings.canaryFeatures) ...[
        '--define',
        'build_web_compilers|ddc=canary=true',
        '--define',
        'build_web_compilers|sdk_js=canary=true',
      ],
      if (testSettings.moduleFormat == ModuleFormat.ddc) ...[
        '--define',
        'build_web_compilers|ddc=ddc-library-bundle=true',
        '--define',
        'build_web_compilers|sdk_js=ddc-library-bundle=true',
        '--define',
        'build_web_compilers|entrypoint=ddc-library-bundle=true',
        '--define',
        'build_web_compilers|entrypoint_marker=ddc-library-bundle=true',
      ],
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

    _loadStrategy = switch ((
      testSettings.moduleFormat,
      buildSettings.canaryFeatures,
    )) {
      (ModuleFormat.ddc, true) => BuildRunnerDdcLibraryBundleStrategyProvider(
        testSettings.reloadConfiguration,
        assetReader,
        buildSettings,
        reloadedSourcesUri: reloadedSourcesUri,
      ).strategy,
      (ModuleFormat.ddc, false) => throw Exception(
        'Unsupported DDC configuration: build daemon + canary (false) '
        '+ DDC module format ${testSettings.moduleFormat.name}.',
      ),
      _ => BuildRunnerRequireStrategyProvider(
        testSettings.reloadConfiguration,
        assetReader,
        buildSettings,
      ).strategy,
    };

    _buildResults = daemonClient.buildResults.asyncMap<BuildResult>((results) {
      final result = results.results.firstWhere(
        (result) => result.target == project.directoryToServe,
      );
      switch (result.status) {
        case daemon.BuildStatus.started:
          return BuildResult(status: BuildStatus.started);
        case daemon.BuildStatus.failed:
          return BuildResult(status: BuildStatus.failed);
        case daemon.BuildStatus.succeeded:
          return BuildResult(status: BuildStatus.succeeded);
        default:
          break;
      }
      throw StateError('Unexpected Daemon build result: $result');
    });
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

/// Connects to the `build_runner` daemon.
Future<BuildDaemonClient> connectClient(
  String dartPath,
  String workingDirectory,
  List<String> options,
  void Function(ServerLog) logHandler,
) => BuildDaemonClient.connect(workingDirectory, [
  dartPath,
  'run',
  'build_runner',
  'daemon',
  ...options,
], logHandler: logHandler);

/// Returns the port of the daemon asset server.
int daemonPort(String workingDirectory) {
  final portFile = File(_assetServerPortFilePath(workingDirectory));
  if (!portFile.existsSync()) {
    throw Exception('Unable to read daemon asset port file.');
  }
  return int.parse(portFile.readAsStringSync());
}

String _assetServerPortFilePath(String workingDirectory) =>
    '${daemonWorkspace(workingDirectory)}/.asset_server_port';
