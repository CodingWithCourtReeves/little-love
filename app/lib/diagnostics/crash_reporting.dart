/// Opt-in, content-scrubbed crash reporting to our self-hosted Bugsink.
///
/// This is the app counterpart to the server's error monitoring (see
/// `docs/error-monitoring.md`). The app is the only place plaintext exists, so
/// reporting is **off by default** and only turns on when the user flips the
/// toggle in Profile. Two further gates back that up:
///
///  1. *Compile-time*: the DSN arrives via `--dart-define=SENTRY_DSN=...`
///     (baked into `ios/Flutter/Release.xcconfig`). With no DSN, Sentry never
///     initializes — a no-op, mirroring the server's unset-`SENTRY_DSN` gate.
///  2. *Run-time*: even initialized, every event/breadcrumb passes through
///     [gateEvent]/[gateBreadcrumb], which drop everything unless the user has
///     opted in. So a mid-session opt-out stops transmission immediately, and
///     on the next launch an opted-out user never initializes the SDK at all.
///
/// We use the **pure-Dart `sentry` package**, not `sentry_flutter`: it has no
/// native iOS dependency, so it keeps our iOS 13 deployment target and adds no
/// native crash handler, screenshots, view-hierarchy capture, or native
/// auto-breadcrumbs (each of which is a plaintext leak vector on this app). The
/// cost is that hard native crashes aren't captured; per the issue, the leak
/// risk we care about is Dart breadcrumbs and exception strings, which this
/// covers. Everything outbound is scrubbed at the [scrub] chokepoint first.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry/sentry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scrub.dart';

/// SharedPreferences key for the opt-in flag. Non-sensitive: a single bool.
const String _prefKey = 'diagnostics.crashReporting.enabled';

const String _dsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');
const String _environment = String.fromEnvironment(
  'SENTRY_ENVIRONMENT',
  defaultValue: 'production',
);
const String _release = String.fromEnvironment('SENTRY_RELEASE');

/// Whether a DSN was compiled in. Without one, reporting can never turn on, so
/// the Profile toggle hides itself.
bool get crashReportingAvailable => _dsn.isNotEmpty;

/// Live opt-in state, read synchronously by the gates below. Kept in sync with
/// the persisted flag by [CrashReporting] and the controller.
bool _enabled = false;
bool _initialized = false;

/// Pure decision behind `beforeSend`: scrub and forward when the user has opted
/// in, drop the event entirely otherwise. Separated out so the opt-in invariant
/// is testable without booting the SDK.
SentryEvent? gateEvent(SentryEvent? event, {required bool enabled}) =>
    enabled ? scrubEvent(event) : null;

/// Pure decision behind `beforeBreadcrumb`: scrub and keep when opted in, drop
/// otherwise (so an opted-out session records nothing).
Breadcrumb? gateBreadcrumb(Breadcrumb? crumb, {required bool enabled}) =>
    enabled ? scrubBreadcrumb(crumb) : null;

/// Orchestrates SDK lifecycle around the opt-in flag.
class CrashReporting {
  CrashReporting._();

  static bool get enabled => _enabled;

  /// Configure the SDK. Privacy-first defaults: no PII, both hooks routed
  /// through the gates, and `serverName` left null so no device name is
  /// attached.
  static void _configure(SentryOptions o) {
    o.dsn = _dsn;
    o.environment = _environment;
    if (_release.isNotEmpty) o.release = _release;
    o.sendDefaultPii = false;
    o.attachStacktrace = true;
    o.maxBreadcrumbs = 30;
    o.beforeSend = (event, hint) => gateEvent(event, enabled: _enabled);
    o.beforeBreadcrumb = (crumb, hint) =>
        gateBreadcrumb(crumb, enabled: _enabled);
  }

  /// Forward uncaught Flutter framework errors to Sentry while preserving the
  /// default console/red-screen presentation. Async errors are already caught
  /// by the `runZonedGuarded` that `Sentry.init`'s `appRunner` installs.
  static void _installFlutterErrorHandler() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      Sentry.captureException(details.exception, stackTrace: details.stack);
    };
  }

  /// Read the persisted opt-in flag and run [appRunner]. When the user has opted
  /// in (and a DSN is compiled in), run inside `Sentry.init` so errors are
  /// captured from the very first frame. Otherwise the SDK is never touched.
  static Future<void> bootstrap(AppRunner appRunner) async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefKey) ?? false;
    if (crashReportingAvailable && _enabled) {
      _initialized = true;
      await Sentry.init(
        _configure,
        appRunner: () {
          _installFlutterErrorHandler();
          appRunner();
        },
      );
    } else {
      await appRunner();
    }
  }

  /// Persist a new opt-in choice and apply it live. Turning it on for the first
  /// time this session initializes the SDK; turning it off flips the gates so
  /// nothing further is transmitted.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
    _enabled = value;
    if (value && crashReportingAvailable && !_initialized) {
      _initialized = true;
      await Sentry.init(_configure);
      _installFlutterErrorHandler();
    }
  }
}

/// Drives the Profile toggle. Reflects the current opt-in state and persists +
/// applies changes.
final crashReportingProvider = NotifierProvider<CrashReportingController, bool>(
  CrashReportingController.new,
);

class CrashReportingController extends Notifier<bool> {
  @override
  bool build() => CrashReporting.enabled;

  Future<void> setEnabled(bool value) async {
    await CrashReporting.setEnabled(value);
    state = value;
  }
}
