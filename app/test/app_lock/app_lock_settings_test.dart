import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/app_lock/app_lock_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a fresh install defaults to locked, after 1 minute', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppLockSettings.load();
    expect(s.enabled, isTrue);
    expect(s.lockAfter, LockAfter.oneMinute);
  });

  test('saved choices survive a relaunch', () async {
    SharedPreferences.setMockInitialValues({});
    await const AppLockSettings(
      enabled: false,
      lockAfter: LockAfter.fifteenMinutes,
    ).save();
    final s = await AppLockSettings.load();
    expect(s.enabled, isFalse);
    expect(s.lockAfter, LockAfter.fifteenMinutes);
  });

  test('an unknown stored grace falls back to 1 minute', () async {
    SharedPreferences.setMockInitialValues({'appLock.lockAfter': 'never'});
    final s = await AppLockSettings.load();
    expect(s.lockAfter, LockAfter.oneMinute);
  });
}
