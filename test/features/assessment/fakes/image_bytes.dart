import 'dart:typed_data';

List<int> _u16(int v) => [(v ~/ 0x100) % 0x100, v % 0x100];
List<int> _u32(int v) => [
  (v ~/ 0x1000000) % 0x100,
  (v ~/ 0x10000) % 0x100,
  (v ~/ 0x100) % 0x100,
  v % 0x100,
];
List<int> _ascii(String s) => s.codeUnits;

Uint8List pngHeader({required int width, required int height}) =>
    Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      ..._u32(13),
      ..._ascii('IHDR'),
      ..._u32(width),
      ..._u32(height),
      8,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);

Uint8List jpegHeader({
  required int width,
  required int height,
  int sofMarker = 0xC0,
  bool withApp0 = true,
  bool withDhtBeforeSof = false,
  bool withFillBytes = false,
}) => Uint8List.fromList([
  0xFF,
  0xD8,
  if (withApp0) ...[
    0xFF,
    0xE0,
    ..._u16(16),
    ..._ascii('JFIF'),
    0,
    1,
    1,
    0,
    ..._u16(1),
    ..._u16(1),
    0,
    0,
  ],
  if (withDhtBeforeSof) ...[
    0xFF,
    0xC4,
    ..._u16(8),
    0x00,
    0x00,
    0x10,
    0x00,
    0x10,
    0x03,
  ],
  if (withFillBytes) ...[0xFF, 0xFF],
  0xFF,
  sofMarker,
  ..._u16(17),
  8,
  ..._u16(height),
  ..._u16(width),
  3,
  1,
  0x22,
  0,
  2,
  0x11,
  1,
  3,
  0x11,
  1,
  0xFF,
  0xD9,
]);

Uint8List jpegWithScanBeforeFrame() => Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xDA,
  ..._u16(8),
  1,
  1,
  0,
  0,
  0x3F,
  0,
  0xFF,
  0xD9,
]);

Uint8List ftypHeader(String majorBrand, {List<String> compatible = const []}) {
  final int size = 16 + 4 * compatible.length;
  return Uint8List.fromList([
    ..._u32(size),
    ..._ascii('ftyp'),
    ..._ascii(majorBrand),
    ..._u32(0),
    for (final brand in compatible) ..._ascii(brand),
    0,
    0,
    0,
    8,
    ..._ascii('free'),
  ]);
}

Uint8List padTo(Uint8List header, int totalLength) {
  final out = Uint8List(totalLength);
  out.setRange(0, header.length, header);
  return out;
}
