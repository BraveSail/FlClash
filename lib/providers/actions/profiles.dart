part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(int id) async {
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
  }

  Future<String> validateConfigWithData(String data) async {
    return _core.validateConfigWithData(data);
  }

  Future<void> autoUpdateProfiles() async {
    final setting = ref.read(appSettingProvider);
    for (final profile in ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      if (isHubUrl(profile.url, setting.hubUrl)) {
        continue;
      }
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(compactError(e), logLevel: LogLevel.warning);
      }
    }
    await syncHubProfile();
  }

  bool get _isHubEnable {
    final setting = ref.read(appSettingProvider);
    return isHubEnabled(setting.hubUrl, setting.hubToken);
  }

  StreamSubscription<dynamic>? _hubPushSubscription;
  Timer? _hubPushRetry;

  /// Holds a socket to the hub so a save there reaches this device at once,
  /// instead of waiting out the rotation: the hub profile is pulled on the same
  /// 20-minute timer as everything else, so a dashboard edit otherwise lands up
  /// to twenty minutes after it was made.
  ///
  /// The socket is best-effort. Everything it delivers is a profile the pull
  /// path can also fetch, so a hub that refuses the upgrade, a network that
  /// drops it, or a platform without socket support all fall back to the poll
  /// that already exists - this only makes the common case immediate.
  void watchHubProfile() {
    if (!_isHubEnable) {
      return;
    }
    unawaited(_openHubPush());
  }

  Future<void> _openHubPush() async {
    _hubPushRetry?.cancel();
    await _hubPushSubscription?.cancel();
    _hubPushSubscription = null;
    if (!_isHubEnable) {
      return;
    }
    final setting = ref.read(appSettingProvider);
    final id = await deviceId();
    if (id.isEmpty) {
      return;
    }
    // No revision is named: the device only learns its ETag through the pull
    // path, and a socket that names none is answered with the current YAML
    // once. That costs one redundant write on connect, and guessing at a
    // revision the hub would not match would silence the first real change.
    final target = hubSocketUrl(hubProfileWatchUrl(setting.hubUrl, id, ''));
    if (target.isEmpty) {
      return;
    }
    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse(target),
        headers: hubAuthHeaders(setting.hubToken),
        connectTimeout: hubPushTimeout,
      );
      await channel.ready;
      _hubPushSubscription = channel.stream.listen(
        (message) => unawaited(_onHubPush(message)),
        onError: (_) => _scheduleHubPushRetry(),
        onDone: _scheduleHubPushRetry,
        cancelOnError: true,
      );
    } catch (e) {
      commonPrint.log('hub push socket failed: ${compactError(e)}',
          logLevel: LogLevel.warning);
      _scheduleHubPushRetry();
    }
  }

  void _scheduleHubPushRetry() {
    if (!_isHubEnable) {
      return;
    }
    _hubPushRetry?.cancel();
    _hubPushRetry = Timer(hubPushRetryDuration, () {
      unawaited(_openHubPush());
    });
  }

  /// A frame from the hub: the YAML this device should be running. It goes
  /// through the same validation a pull takes, so a bad payload cannot take the
  /// device down, and the profile that is running is only replaced once the new
  /// one is known good.
  Future<void> _onHubPush(dynamic message) async {
    if (message is! String) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['type'] != 'profile') {
      return;
    }
    final yaml = decoded['yaml'];
    if (yaml is! String || yaml.trim().isEmpty) {
      return;
    }
    try {
      await applyHubYaml(yaml);
    } catch (e) {
      commonPrint.log('hub push apply failed: ${compactError(e)}',
          logLevel: LogLevel.warning);
    }
  }

  Future<void> closeHubPush() async {
    _hubPushRetry?.cancel();
    _hubPushRetry = null;
    await _hubPushSubscription?.cancel();
    _hubPushSubscription = null;
  }

  /// Deep links and the album scanner reach the import actions without
  /// passing through the sheet that greys them out, so the gate lives here.
  bool _isHubManaged() {
    if (!_isHubEnable) {
      return false;
    }
    dialogs.showNotifier(
      currentAppLocalizations.hubImportDisabledTip,
      level: MessageLevel.warning,
    );
    return true;
  }

  bool _isSyncingHub = false;

  /// Pulls this device's profile from the Hub and puts it in use, stored as a
  /// normal URL profile so the regular update loop keeps refreshing it.
  Future<void> syncHubProfile({
    bool silence = true,
    bool notifyMissing = false,
  }) async {
    if (!_isHubEnable || _isSyncingHub) {
      return;
    }
    _isSyncingHub = true;
    try {
      final profile = await globalState.loadingRun(
        tag: silence ? null : LoadingTag.profiles,
        () => _fetchHubProfile(notifyMissing: notifyMissing),
        title: currentAppLocalizations.sync,
        silence: silence,
      );
      if (profile == null) {
        return;
      }
      ref.read(profilesProvider.notifier).put(profile);
      if (ref.read(currentProfileIdProvider) != profile.id) {
        ref.read(currentProfileIdProvider.notifier).value = profile.id;
      }
      ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: silence);
    } finally {
      _isSyncingHub = false;
    }
  }

  /// Writes a YAML the hub pushed over the socket, through the same profile the
  /// pull path maintains: same label, same auto-update settings, same
  /// validation. The file is only replaced after the core accepts it, so a
  /// payload that fails to load leaves the running profile alone.
  ///
  /// A push that lands while a pull is writing this same profile waits for that
  /// write to finish rather than being dropped: the pushed revision is the newer
  /// one, and dropping it would strand the device on the old YAML until the next
  /// rotation - the very wait this socket exists to remove.
  Future<void> applyHubYaml(String yaml) async {
    for (var attempt = 0; attempt < hubPushApplyWaits && _isSyncingHub; attempt++) {
      await Future<void>.delayed(hubPushApplyGap);
    }
    if (_isSyncingHub) {
      // A write that outlasts the bound is not worth racing; the next rotation
      // still picks the profile up.
      return;
    }
    _isSyncingHub = true;
    try {
      final setting = ref.read(appSettingProvider);
      final id = await deviceId();
      if (id.isEmpty) {
        return;
      }
      final url = hubProfileUrl(setting.hubUrl, id);
      final existing = ref
          .read(profilesProvider)
          .where((item) => item.url == url)
          .firstOrNull;
      final profile = (existing ?? Profile.normal(url: url)).copyWith(
        label: (existing?.label).takeFirstValid([
          currentAppLocalizations.hubProfile,
        ]),
        autoUpdate: true,
        autoUpdateDuration: hubUpdateDuration,
      );
      final saved = await profile.saveFile(
        Uint8List.fromList(utf8.encode(yaml)),
        validate: _core.validateConfig,
      );
      ref.read(profilesProvider.notifier).put(saved);
      if (ref.read(currentProfileIdProvider) != saved.id) {
        ref.read(currentProfileIdProvider.notifier).value = saved.id;
      }
      ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
    } finally {
      _isSyncingHub = false;
    }
  }

  Future<Profile?> _fetchHubProfile({bool notifyMissing = false}) async {
    final setting = ref.read(appSettingProvider);
    final id = await deviceId();
    if (id.isEmpty) {
      throw MessageException(currentAppLocalizations.hubDeviceIdTip);
    }
    final url = hubProfileUrl(setting.hubUrl, id);
    final existing = ref
        .read(profilesProvider)
        .where((item) => item.url == url)
        .firstOrNull;
    final profile = (existing ?? Profile.normal(url: url)).copyWith(
      label: (existing?.label).takeFirstValid([
        currentAppLocalizations.hubProfile,
      ]),
      autoUpdate: true,
      autoUpdateDuration: hubUpdateDuration,
    );
    try {
      return await profile.update(validate: _core.validateConfig);
    } on DioException catch (error) {
      final missing = error.response?.statusCode == HttpStatus.notFound;
      if (!missing) {
        rethrow;
      }
      // An unconfigured device answers 404; only the user's own pull says so.
      if (notifyMissing) {
        throw MessageException(currentAppLocalizations.hubProfileMissing);
      }
      commonPrint.log(
        'the hub has no profile for $id',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    try {
      ref.read(profilesProvider.notifier).put(profile);
      final newProfile = await profile.update(
        validate: (path) => _core.validateConfig(path),
      );
      ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<void> addProfileFormFile() async {
    if (_isHubManaged()) {
      return;
    }
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          label: platformFile.name,
        ).saveFile(bytes, validate: (path) => _core.validateConfig(path));
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<void> addProfileFormURL(String url) async {
    if (_isHubManaged()) {
      return;
    }
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(
          url: url,
        ).update(validate: (path) => _core.validateConfig(path));
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFormURL(url));
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    try {
      final error = await _core.clearEffect(profileId);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    } catch (error) {
      commonPrint.log(
        'clearEffect($profileId) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }
}
