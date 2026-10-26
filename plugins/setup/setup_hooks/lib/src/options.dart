import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

final _log = Logger('options');

class BuildConfig {
  const BuildConfig({
    required this.tags,
    required this.goLdflags,
    required this.coreDir,
    required this.coreName,
    required this.libName,
    required this.outputDir,
    required this.helperDir,
    required this.helperName,
  });

  final String tags;
  final String goLdflags;
  final String coreDir;
  final String coreName;
  final String libName;
  final String outputDir;
  final String helperDir;
  final String helperName;

  static const _defaults = BuildConfig(
    tags: 'with_gvisor',
    goLdflags: '-w -s',
    coreDir: 'core',
    coreName: 'FlClashCore',
    libName: 'libclash',
    outputDir: 'libclash',
    helperDir: 'services/helper',
    helperName: 'FlClashHelperService',
  );

  /// The hub this build belongs to, from the environment.
  ///
  /// A core that names a hub takes its configuration from it without being
  /// told, which is what lets the program around it stay stock. The address is
  /// a property of the build, not of the machine and not of a setting, so it
  /// enters here: CI sets HUB_URL, a local build that leaves it unset produces
  /// a plain core with no mesh in it.
  static const hubUrlVariable = 'HUB_URL';

  static String _withHub(String ldflags) {
    final hub = (Platform.environment[hubUrlVariable] ?? '').trim();
    if (hub.isEmpty) {
      return ldflags;
    }
    return '$ldflags -X '
        "'github.com/metacubex/mihomo/constant.HubURL=$hub'";
  }

  static BuildConfig load({required String rootDir}) {
    final file = File(p.join(rootDir, 'build_config.yaml'));
    if (!file.existsSync()) {
      _log.fine('No build_config.yaml found, using defaults');
      return _withDefaults(_defaults);
    }
    final yaml = loadYaml(file.readAsStringSync()) as YamlMap?;
    if (yaml == null) return _withDefaults(_defaults);
    return BuildConfig(
      tags: yaml['tags'] as String? ?? _defaults.tags,
      goLdflags: _withHub(yaml['go_ldflags'] as String? ?? _defaults.goLdflags),
      coreDir: yaml['core_dir'] as String? ?? _defaults.coreDir,
      coreName: yaml['core_name'] as String? ?? _defaults.coreName,
      libName: yaml['lib_name'] as String? ?? _defaults.libName,
      outputDir: yaml['output_dir'] as String? ?? _defaults.outputDir,
      helperDir: yaml['helper_dir'] as String? ?? _defaults.helperDir,
      helperName: yaml['helper_name'] as String? ?? _defaults.helperName,
    );
  }

  static BuildConfig _withDefaults(BuildConfig base) => BuildConfig(
        tags: base.tags,
        goLdflags: _withHub(base.goLdflags),
        coreDir: base.coreDir,
        coreName: base.coreName,
        libName: base.libName,
        outputDir: base.outputDir,
        helperDir: base.helperDir,
        helperName: base.helperName,
      );

  Map<String, String> toFingerprintMap() => {
    'tags': tags,
    'go_ldflags': goLdflags,
    'core_dir': coreDir,
    'core_name': coreName,
    'lib_name': libName,
    'output_dir': outputDir,
    'helper_dir': helperDir,
    'helper_name': helperName,
  };
}
