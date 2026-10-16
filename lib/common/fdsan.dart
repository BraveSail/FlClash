import 'dart:ffi';
import 'dart:io';

/// fdsan aborts the process when it catches a file-descriptor ownership
/// violation, and on Android 16 the VPN stack raises one of its own.
///
/// `VpnService.protect(fd)` reaches `protectFromVpn`, which closes a descriptor
/// that its own `unique_fd` still owns. The abort lands on whatever code touches
/// the recycled number first, so the stack trace names unrelated places - a
/// Vulkan fence, a `Surface` destructor, a binder thread - and the crash looks
/// random. It is not ours to fix: a socket mihomo opens carries no fdsan tag, so
/// closing one could not raise this, while every report names a C++ `unique_fd`
/// as the owner of the descriptor being closed.
///
/// Until the platform closes it correctly, ask fdsan to warn instead of aborting.
/// The violation is still logged, so the underlying bug stays visible in logcat
/// while it stops taking the app down.
///
/// Best effort throughout: a libc without the symbol, or one that declines the
/// level, leaves the app running exactly as it did before.
enum _FdsanErrorLevel {
  /// `android_fdsan_error_level` from `<android/fdsan.h>`: 0 disabled, 1 warn
  /// once, 2 warn always, 3 fatal - the platform default since API 30, and the
  /// reason a violation kills the process. Only the level used is named here.
  ///
  /// `FDSAN_ERROR_LEVEL_WARN_ALWAYS`: every violation is logged, none abort.
  warnAlways(2);

  const _FdsanErrorLevel(this.value);

  final int value;
}

typedef _SetErrorLevelNative = Void Function(Int32);
typedef _SetErrorLevelDart = void Function(int);

/// Makes an fdsan violation a log line rather than a `SIGABRT`. Android only;
/// a no-op everywhere else.
void keepFdsanViolationsNonFatal() {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    final libc = DynamicLibrary.open('libc.so');
    final setErrorLevel = libc
        .lookupFunction<_SetErrorLevelNative, _SetErrorLevelDart>(
          'android_fdsan_set_error_level',
        );
    setErrorLevel(_FdsanErrorLevel.warnAlways.value);
  } catch (_) {
    // Nothing to do: the app is no worse off than before this ran.
  }
}
