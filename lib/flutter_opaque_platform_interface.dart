import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_opaque_method_channel.dart';

abstract class FlutterOpaquePlatform extends PlatformInterface {
  /// Constructs a FlutterOpaquePlatform.
  FlutterOpaquePlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterOpaquePlatform _instance = MethodChannelFlutterOpaque();

  /// The default instance of [FlutterOpaquePlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterOpaque].
  static FlutterOpaquePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterOpaquePlatform] when
  /// they register themselves.
  static set instance(FlutterOpaquePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
