import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_opaque/flutter_opaque.dart';
import 'package:flutter_opaque/flutter_opaque_platform_interface.dart';
import 'package:flutter_opaque/flutter_opaque_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterOpaquePlatform
    with MockPlatformInterfaceMixin
    implements FlutterOpaquePlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterOpaquePlatform initialPlatform = FlutterOpaquePlatform.instance;

  test('$MethodChannelFlutterOpaque is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterOpaque>());
  });

  test('getPlatformVersion', () async {
    FlutterOpaque flutterOpaquePlugin = FlutterOpaque();
    MockFlutterOpaquePlatform fakePlatform = MockFlutterOpaquePlatform();
    FlutterOpaquePlatform.instance = fakePlatform;

    expect(await flutterOpaquePlugin.getPlatformVersion(), '42');
  });
}
