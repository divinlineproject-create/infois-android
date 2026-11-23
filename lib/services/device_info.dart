import 'package:flutter/services.dart';

/// Model perangkat ("Samsung SM-A155F", "SUNMI V2") untuk header
/// `X-Device-Model`: server menamai perangkat baru "{model} · {pengguna}".
class DeviceInfo {
  DeviceInfo._();

  static const _channel = MethodChannel('id.infois/device');

  /// Baca model dari Android (`Build.MANUFACTURER` + `Build.MODEL`); null bila
  /// tidak tersedia (tes, platform lain).
  static Future<String?> loadModel() async {
    try {
      final info = await _channel.invokeMapMethod<String, String>('model');
      return formatDeviceModel(info?['manufacturer'], info?['model']);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Gabung pabrikan + model dengan huruf besar yang wajar: "samsung" →
/// "Samsung", "SUNMI" tetap; model yang sudah diawali nama pabrikan tidak
/// diulang ("Google Pixel 7", bukan "Google Google Pixel 7").
String? formatDeviceModel(String? manufacturer, String? model) {
  final maker = (manufacturer ?? '').trim();
  final name = (model ?? '').trim();
  if (maker.isEmpty && name.isEmpty) {
    return null;
  }
  final brand = maker.isEmpty ? '' : (maker == maker.toLowerCase() ? '${maker[0].toUpperCase()}${maker.substring(1)}' : maker);
  if (name.isEmpty) {
    return brand;
  }
  if (brand.isEmpty || name.toLowerCase().startsWith(brand.toLowerCase())) {
    return name.length > 1 && name == name.toLowerCase() ? '${name[0].toUpperCase()}${name.substring(1)}' : name;
  }
  final full = '$brand $name';
  return full.length > 60 ? full.substring(0, 60) : full;
}
