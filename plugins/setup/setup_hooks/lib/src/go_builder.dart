import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build.dart';
import 'build_cache.dart';
import 'error.dart';
import 'fingerprint.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('go_builder');

class GoBuilder {
  GoBuilder({
    required this.rootDir,
    required this.config,
    required this.cache,
    required this.notice,
    this.harnessInputs = const [],
    this.androidToolchain,
  });

  final String rootDir;
  final BuildConfig config;
  final BuildCache cache;
  final BuildNotice notice;
  final List<String> harnessInputs;
  final AndroidToolchain? androidToolchain;

  String get _corePath => p.join(rootDir, config.coreDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  String _resolveCc(Target target) {
    final toolchain = androidToolchain;
    if (toolchain == null) {
      throw BuildException('Android target $target needs an NDK toolchain');
    }
    final cc = toolchain.clangFor(target);
    if (!File(cc).existsSync()) {
      throw BuildException(
        'NDK compiler not found: $cc (API ${toolchain.apiLevel} from the '
        'app minSdk; the NDK Flutter selected may be too old)',
      );
    }
    return cc;
  }

  Future<BuildExecution> build(Target target) async {
    final outDir = target.isLib
        ? p.join(_outputPath, target.platformDir, target.abi!)
        : p.join(_outputPath, target.platformDir);
    ensureDir(outDir);

    final fileName = target.isLib
        ? '${config.libName}.so'
        : '${config.coreName}${target.executableExtension}';
    final outFile = p.join(outDir, fileName);

    return cache.run(
      key: '${target.platformDir}-${target.goarch}-core',
      fingerprint: () => _calculateFingerprint(target),
      primaryOutput: outFile,
      notice: notice,
      build: () async {
        final env = _buildEnvironment(target);
        _log.info(
          'Building Go core: $target '
          '${target.isLib ? "(CGO, c-shared)" : "(standalone)"}',
        );

        // A failed build must not destroy the previous artifacts.
        final stagingDir = Directory(
          p.join(outDir, '.staging-${target.goarch}-$pid'),
        );
        final staged = p.join(stagingDir.path, fileName);
        try {
          await runCommandStream(
            'go',
            _buildArguments(target, outFile: staged),
            workingDirectory: _corePath,
            environment: env,
          );

          final outputs = <String>[outFile];
          if (target.isLib) {
            outputs.addAll(
              _installAndroidOutput(
                abi: target.abi!,
                platformDir: p.join(_outputPath, target.platformDir),
                stagingDir: stagingDir.path,
                libName: fileName,
                outFile: outFile,
              ),
            );
          } else {
            replaceFile(staged, outFile);
          }

          _log.info('Built: $outFile');
          return outputs;
        } finally {
          if (stagingDir.existsSync()) {
            stagingDir.deleteSync(recursive: true);
          }
        }
      },
    );
  }

  Map<String, String> _buildEnvironment(Target target) {
    final env = <String, String>{'GOOS': target.goos, 'GOARCH': target.goarch};
    if (target.isLib) {
      env
        ..['CGO_ENABLED'] = '1'
        ..['CC'] = _resolveCc(target)
        ..['CFLAGS'] = '-O3 -Werror';
    } else {
      env['CGO_ENABLED'] = '0';
    }
    return env;
  }

  /// The revision and the build time stamped into the core.
  ///
  /// The app shows them next to the version so a device running a different
  /// build is visible from its own about page: nodes on mismatched cores fail
  /// each other's handshakes and report nothing that points at why.
  static String _readRevision(String corePath) {
    try {
      final r = runCommand('git', [
        'rev-parse',
        '--short=12',
        'HEAD',
      ], workingDirectory: corePath);
      if (r.exitCode != 0) return '';
      final rev = (r.stdout as String).trim();
      if (rev.isEmpty) return '';
      final s = runCommand('git', [
        'status',
        '--porcelain',
      ], workingDirectory: corePath);
      final dirty = s.exitCode == 0 && (s.stdout as String).trim().isNotEmpty;
      return '$rev${dirty ? '-dirty' : ''}';
    } catch (_) {
      return '';
    }
  }

  List<String> _buildArguments(Target target, {String? outFile}) => [
    'build',
    '-ldflags=${config.goLdflags}${_versionLdflags()}',
    '-tags=${config.tags}',
    if (target.isLib) '-buildmode=c-shared',
    if (outFile != null) ...['-o', outFile],
  ];

  /// The arguments as they enter the cache fingerprint: identical to the real
  /// ones except that the build time is left out.
  ///
  /// The build time is stamped into every core, so including it would make the
  /// fingerprint differ from run to run and rebuild an unchanged core - the
  /// cache would never hit. The revision is in here, so a core whose checkout
  /// moved does rebuild.
  List<String> _fingerprintArguments(Target target) => [
    'build',
    '-ldflags=${config.goLdflags}${_stampLdflag()}',
    '-tags=${config.tags}',
    if (target.isLib) '-buildmode=c-shared',
  ];

  String _stampLdflag() {
    final stamp = _readRevision(_corePath);
    return stamp.isEmpty
        ? ''
        : " -X 'github.com/metacubex/mihomo/constant.Revision=$stamp'";
  }

  /// Stamp the revision and the build time into the core.
  ///
  /// The revision is read from the core checkout rather than passed in, so a
  /// local build carries the same information as a released one and neither
  /// depends on the caller remembering. Only the revision goes into the cache
  /// fingerprint; the build time is not a cache input, because the wall clock
  /// moves between builds and would rebuild a core that has not changed.
  String _versionLdflags() {
    final stamp = _readRevision(_corePath);
    final builtAt = DateTime.now().toUtc().toIso8601String();
    return [
      if (stamp.isNotEmpty)
        " -X 'github.com/metacubex/mihomo/constant.Revision=$stamp'",
      " -X 'github.com/metacubex/mihomo/constant.BuildTime=$builtAt'",
    ].join();
  }

  Future<Fingerprint> _calculateFingerprint(Target target) async {
    final env = _buildEnvironment(target);
    final builder = FingerprintBuilder(rootDir: rootDir)
      ..addValue('cache_schema', BuildCache.schemaVersion)
      ..addValue('kind', 'go-core')
      ..addValue('target', {
        'goos': target.goos,
        'goarch': target.goarch,
        'abi': target.abi,
      })
      ..addValue('config', config.toFingerprintMap())
      ..addValue('environment', env)
      ..addValue('core_revision', _readRevision(_corePath))
      ..addValue('arguments', _fingerprintArguments(target));

    final goEnvResult = runCommand(
      'go',
      [
        'env',
        '-json',
        'GOVERSION',
        'GOTOOLCHAIN',
        'GOFLAGS',
        'GOEXPERIMENT',
        'GOAMD64',
        'GOARM',
        'GO386',
        'GOMIPS',
        'GOMIPS64',
        'CGO_CFLAGS',
        'CGO_CPPFLAGS',
        'CGO_CXXFLAGS',
        'CGO_LDFLAGS',
        'GOWORK',
        'GOENV',
      ],
      workingDirectory: _corePath,
      environment: env,
    );
    final goEnv = jsonDecode((goEnvResult.stdout as String).trim());
    builder.addValue('go_env', goEnv);

    final inputs = _resolveGoInputs(env);
    final goWork = (goEnv as Map<String, dynamic>)['GOWORK'];
    if (goWork is String && goWork.isNotEmpty && goWork != 'off') {
      inputs.add(goWork);
      final goWorkSum = p.join(p.dirname(goWork), 'go.work.sum');
      if (File(goWorkSum).existsSync()) inputs.add(goWorkSum);
    }
    inputs.addAll(harnessInputs);

    if (target.isLib) {
      final compilerVersion = runCommand(env['CC']!, ['--version']);
      builder.addValue(
        'android_compiler',
        '${(compilerVersion.stdout as String).trim()}\n'
            '${(compilerVersion.stderr as String).trim()}',
      );
    }

    builder.addFiles(inputs);
    return builder.finishWithInputs();
  }

  Set<String> _resolveGoInputs(Map<String, String> environment) {
    const template =
        r'''{{range .GoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .MFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .HFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .FFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigCXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SysoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .EmbedFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{with .Module}}{{if .GoMod}}{{.GoMod}}{{"\n"}}{{end}}{{end}}''';
    final result = runCommand(
      'go',
      ['list', '-deps', '-tags=${config.tags}', '-f', template, '.'],
      workingDirectory: _corePath,
      environment: environment,
    );
    final corePath = p.normalize(p.absolute(_corePath));
    final inputs = <String>{};
    for (final line in (result.stdout as String).split('\n')) {
      final value = line.trim();
      if (value.isEmpty) continue;
      final filePath = p.normalize(
        p.absolute(p.isAbsolute(value) ? value : p.join(_corePath, value)),
      );
      if (!p.isWithin(corePath, filePath) && !p.equals(corePath, filePath)) {
        continue;
      }
      if (!File(filePath).existsSync()) continue;
      inputs.add(filePath);
      if (p.basename(filePath) == 'go.mod') {
        final goSum = p.join(p.dirname(filePath), 'go.sum');
        if (File(goSum).existsSync()) inputs.add(goSum);
      }
    }

    for (final name in const ['go.mod', 'go.sum']) {
      final filePath = p.join(_corePath, name);
      if (File(filePath).existsSync()) inputs.add(filePath);
    }
    return inputs;
  }

  List<String> _installAndroidOutput({
    required String abi,
    required String platformDir,
    required String stagingDir,
    required String libName,
    required String outFile,
  }) {
    final includesPath = p.join(platformDir, 'includes', abi);
    final androidCoreMainPath = p.join(
      rootDir,
      'android',
      'core',
      'src',
      'main',
    );
    final jniLibsPath = p.join(androidCoreMainPath, 'jniLibs', abi);
    final cppIncludesPath = p.join(androidCoreMainPath, 'cpp', 'includes', abi);
    final outputs = <String>[];

    ensureDir(includesPath);
    _clearDirectory(includesPath);
    ensureDir(cppIncludesPath);
    _clearDirectory(cppIncludesPath);

    replaceFile(p.join(stagingDir, libName), outFile);
    copyFile(outFile, p.join(jniLibsPath, libName));
    outputs.add(p.join(jniLibsPath, libName));

    final generatedHeaders = Directory(stagingDir).listSync();
    final staticHeaders = Directory(_corePath).listSync();
    for (final file in [...generatedHeaders, ...staticHeaders]) {
      if (!file.path.endsWith('.h')) continue;
      final headerName = p.basename(file.path);
      final includePath = p.join(includesPath, headerName);
      final cppIncludePath = p.join(cppIncludesPath, headerName);
      copyFile(file.path, includePath);
      copyFile(file.path, cppIncludePath);
      outputs
        ..add(includePath)
        ..add(cppIncludePath);
    }
    return outputs;
  }

  void _clearDirectory(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync()) {
      if (entity is File || entity is Link) {
        entity.deleteSync();
      } else if (entity is Directory) {
        entity.deleteSync(recursive: true);
      }
    }
  }
}
