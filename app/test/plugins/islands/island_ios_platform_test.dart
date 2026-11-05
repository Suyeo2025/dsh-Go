// The islands on iOS: `dsh/islands` answers on Android and iOS only
// (ios/Runner/IslandsChannel.swift implements `device` and nothing else),
// what iOS doesn't implement comes back as "not available", an unanswered
// `device` keeps islands off, and WKWebView devices keep to two islands.

import 'package:dsh_app/plugins/seams/seat_models.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/islands.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1024 * 1024 * 1024;
const _channel = MethodChannel('dsh/islands');

/// What ios/Runner/IslandsChannel.swift answers.
Future<Object?> _ios(MethodCall call) async {
  if (call.method == 'device') {
    return {'totalMem': 8 * _gb, 'availMem': 3 * _gb, 'lowRam': false, 'webView': 'WKWebView'};
  }
  throw MissingPluginException(); // FlutterMethodNotImplemented, as the codec delivers it
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call.method);
      return _ios(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('platform gate', () {
    test('iOS asks the native side', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final device = await MethodChannelIslandPlatform().device();
      expect(calls, ['device']);
      expect(device.totalMem, 8 * _gb);
      expect(device.availMem, 3 * _gb);
      expect(device.lowRam, isFalse);
      expect(device.isWkWebView, isTrue);
    });

    test('Android still asks', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await MethodChannelIslandPlatform().device();
      expect(calls, ['device']);
    });

    test('other platforms never call', () async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        final device = await MethodChannelIslandPlatform().device();
        expect(device.totalMem, 0, reason: '$platform');
      }
      expect(calls, isEmpty);
    });

    test('what iOS does not implement is "not available", never an error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final platform = MethodChannelIslandPlatform();
      expect(await platform.attach(7, dark: true, textZoom: 100), isFalse);
      await platform.setDark(7, false);
      await platform.setTextZoom(7, 120);
      await platform.pause(7);
      await platform.resume(7);
      await platform.destroy(7);
      expect(await platform.appPss(), isNull);
      expect(calls, ['attach', 'setDark', 'setTextZoom', 'pause', 'resume', 'destroy', 'appPss']);
    });
  });

  group('device unknown', () {
    test('no `device` answer: unknown, the smallest tier, islands off', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(_channel, null); // no native side at all
      final device = await MethodChannelIslandPlatform().device();
      expect(device.totalMem, 0);
      expect(device.isWkWebView, isFalse);
      expect(maxLiveIslands(device), 1);
      final spec = IslandSpec(host: HostRef.direct('h'), form: IslandForm.page, slot: 'settings.section', cell: 'x');
      IslandBudgetSnapshot budget({required bool supported}) =>
          IslandBudgetSnapshot(supported: supported, max: maxLiveIslands(device), live: const [], allowHost: (_) => true);
      expect(budget(supported: device.totalMem > 0).canOpen(spec), isFalse);
      expect(budget(supported: true).canOpen(spec), isTrue, reason: 'only the missing answer keeps it closed');
    });

    test('malformed answers read as unknown', () {
      expect(IslandDevice.fromJson(null).totalMem, 0);
      expect(IslandDevice.fromJson({'totalMem': '8'}).totalMem, 0);
      expect(IslandDevice.fromJson({'totalMem': 8 * _gb, 'webView': 3}).webView, isNull);
    });
  });

  group('WKWebView tiers', () {
    IslandDevice ios(num gb, {bool lowRam = false}) =>
        IslandDevice(totalMem: (gb * _gb).round(), lowRam: lowRam, webView: IslandDevice.wkWebView);

    test('at most two islands, however much memory', () {
      expect(maxLiveIslands(ios(16)), IslandBudgetRules.maxWkWebViewIslands);
      expect(maxLiveIslands(ios(12)), 2);
      expect(maxLiveIslands(ios(8)), 2);
      // The same memory on Android keeps its three.
      expect(maxLiveIslands(IslandDevice(totalMem: 16 * _gb)), 3);
    });

    test('small and low-memory devices keep to one', () {
      expect(maxLiveIslands(ios(4)), 1);
      expect(maxLiveIslands(ios(2.8, lowRam: true)), 1);
      expect(maxLiveIslands(ios(16, lowRam: true)), 1);
      expect(maxLiveIslands(ios(16), islandMb: 160), 1);
    });
  });
}
