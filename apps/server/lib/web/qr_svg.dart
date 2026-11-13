import 'package:qr/qr.dart';

/// [data] as a QR code in SVG, for the setup page's "Add a device".
String qrSvg(String data, {int moduleSize = 6, int quietZone = 4}) {
  final image = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  final size = (image.moduleCount + quietZone * 2) * moduleSize;
  final path = StringBuffer();
  for (var row = 0; row < image.moduleCount; row++) {
    for (var col = 0; col < image.moduleCount; col++) {
      if (image.isDark(row, col)) {
        path.write(
          'M${(col + quietZone) * moduleSize},${(row + quietZone) * moduleSize}h${moduleSize}v${moduleSize}h-${moduleSize}z',
        );
      }
    }
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" width="$size" height="$size">'
      '<rect width="100%" height="100%" fill="#fff"/><path fill="#000" d="$path"/></svg>';
}
