import 'package:fl_clash/common/fdsan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fdsan', () {
    test(
      'is a no-op off Android, so a test host never changes its own libc',
      () {
        // The host these tests run on is not Android, so the guard is what keeps
        // this from reaching for a symbol that does not exist there. It must
        // return rather than throw, because it is called from main() before any
        // error handling is installed.
        expect(keepFdsanViolationsNonFatal, returnsNormally);
      },
    );
  });
}
