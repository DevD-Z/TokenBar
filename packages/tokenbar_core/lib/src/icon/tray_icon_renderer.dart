import 'dart:io';
import 'dart:typed_data';

/// Renders the tray icon: two horizontal bars showing the remaining share of
/// the session (top) and weekly (bottom) windows, styled like the app icon.
/// Encodes PNG (and ICO for Windows) without any image dependency.
class TrayIconRenderer {
  /// Supersampling factor: the icon is drawn at `size * _ss` and averaged down,
  /// which gives smooth (anti-aliased) rounded corners.
  static const _ss = 4;

  static Uint8List renderPng({double? top, double? bottom, bool error = false, int size = 32}) {
    // Same artwork as the app icon (tool/gen_icons.py): a dark squircle with two
    // gradient bars. The fills turn amber / red when that window runs low.
    final big = size * _ss;
    final px = Uint8List(big * big * 4);
    final half = big / 2;

    // Bar geometry in big-pixel units (matches the app icon's small layout).
    final x0 = big * 0.16, x1 = big * 0.84;
    final barH = big * 0.19, gap = big * 0.12;
    final y0 = (big - (barH * 2 + gap)) / 2;
    final bars = [(y: y0, remaining: top), (y: y0 + barH + gap, remaining: bottom)];
    final r = barH / 2;

    bool inCapsule(double x, double y, double bx0, double by0, double bx1) {
      final lo = bx0 + r;
      final hi = bx1 - r > lo ? bx1 - r : lo;
      final cx = x < lo ? lo : (x > hi ? hi : x);
      final dx = x - cx, dy = y - (by0 + r);
      return dx * dx + dy * dy <= r * r;
    }

    for (var y = 0; y < big; y++) {
      for (var x = 0; x < big; x++) {
        final fx = x + 0.5, fy = y + 0.5;
        final nx = ((fx - half) / (half * 0.98)).abs(), ny = ((fy - half) / (half * 0.98)).abs();
        // Superellipse (n = 5): Apple-style continuous corners.
        if (_pow5(nx) + _pow5(ny) > 1) continue;

        final t = fy / big;
        var color = [_mix(0x1E, 0x0A, t), _mix(0x29, 0x0E, t), _mix(0x46, 0x1C, t)];

        for (final bar in bars) {
          if (fy < bar.y || fy > bar.y + barH) continue;
          if (!inCapsule(fx, fy, x0, bar.y, x1)) continue;
          // Track.
          color = _over(color, const [255, 255, 255], 0.13);
          final remaining = bar.remaining;
          if (remaining == null) continue;
          if (remaining <= 0) continue;
          // Keep at least a full pill visible so a nearly empty bar is not a sliver.
          final fill = (x0 + (x1 - x0) * (remaining.clamp(0, 100) / 100))
              .clamp(x0 + barH, x1)
              .toDouble();
          if (fx > fill || !inCapsule(fx, fy, x0, bar.y, fill)) continue;
          final (c0, c1) = _barColors(bar.y == y0, remaining);
          final u = ((fx - x0) / (fill - x0)).clamp(0.0, 1.0);
          final shade = 1.12 - 0.22 * ((fy - bar.y) / barH);
          color = [
            for (var ch = 0; ch < 3; ch++) (_mix(c0[ch], c1[ch], u) * shade).clamp(0, 255).round(),
          ];
        }

        final i = (y * big + x) * 4;
        px[i] = color[0];
        px[i + 1] = color[1];
        px[i + 2] = color[2];
        px[i + 3] = 255;
      }
    }

    if (error) {
      final cx = big - big * 0.15, cy = big * 0.15, rad = big * 0.12;
      for (var y = 0; y < big; y++) {
        for (var x = 0; x < big; x++) {
          final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
          final d2 = dx * dx + dy * dy;
          if (d2 > rad * rad) continue;
          final i = (y * big + x) * 4;
          final ring = d2 > (rad * 0.72) * (rad * 0.72);
          px[i] = ring ? 0x1E : 0xF8;
          px[i + 1] = ring ? 0x29 : 0x71;
          px[i + 2] = ring ? 0x46 : 0x71;
          px[i + 3] = 255;
        }
      }
    }
    return _encodePng(_downsample(px, big, size), size);
  }

  static double _pow5(double v) => v * v * v * v * v;

  static int _mix(num a, num b, double t) => (a + (b - a) * t).round();

  static List<int> _over(List<int> base, List<int> top, double alpha) => [
    for (var i = 0; i < 3; i++) (base[i] + (top[i] - base[i]) * alpha).round(),
  ];

  /// Gradient ends for a bar: brand colours while healthy, amber / red when low.
  static (List<int>, List<int>) _barColors(bool isTop, double remaining) {
    if (remaining <= 20) return (const [0xF8, 0x71, 0x71], const [0xEF, 0x44, 0x44]);
    if (remaining <= 50) return (const [0xFB, 0xBF, 0x24], const [0xF5, 0x9E, 0x0B]);
    return isTop
        ? (const [52, 211, 153], const [34, 211, 238])
        : (const [129, 140, 248], const [192, 132, 252]);
  }

  /// Box-filter downsample with premultiplied alpha, so transparent corner
  /// pixels do not bleed their (black) colour into the edge.
  static Uint8List _downsample(Uint8List src, int big, int size) {
    final out = Uint8List(size * size * 4);
    final n = _ss * _ss;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        for (var dy = 0; dy < _ss; dy++) {
          for (var dx = 0; dx < _ss; dx++) {
            final i = ((y * _ss + dy) * big + (x * _ss + dx)) * 4;
            final al = src[i + 3] / 255;
            r += src[i] * al;
            g += src[i + 1] * al;
            b += src[i + 2] * al;
            a += al;
          }
        }
        final o = (y * size + x) * 4;
        if (a > 0) {
          out[o] = (r / a).round();
          out[o + 1] = (g / a).round();
          out[o + 2] = (b / a).round();
        }
        out[o + 3] = (a / n * 255).round();
      }
    }
    return out;
  }

  /// ICO container wrapping a single PNG image (supported since Vista).
  static Uint8List wrapIco(Uint8List png, {int size = 32}) {
    final dim = size >= 256 ? 0 : size;
    final header = ByteData(22)
      ..setUint16(0, 0, Endian.little)
      ..setUint16(2, 1, Endian.little)
      ..setUint16(4, 1, Endian.little)
      ..setUint8(6, dim)
      ..setUint8(7, dim)
      ..setUint8(8, 0)
      ..setUint8(9, 0)
      ..setUint16(10, 1, Endian.little)
      ..setUint16(12, 32, Endian.little)
      ..setUint32(14, png.length, Endian.little)
      ..setUint32(18, 22, Endian.little);
    return (BytesBuilder()
          ..add(header.buffer.asUint8List())
          ..add(png))
        .toBytes();
  }

  static Uint8List _encodePng(Uint8List rgba, int size) {
    final raw = BytesBuilder();
    for (var y = 0; y < size; y++) {
      raw.addByte(0);
      raw.add(Uint8List.sublistView(rgba, y * size * 4, (y + 1) * size * 4));
    }
    final ihdr = ByteData(13)
      ..setUint32(0, size)
      ..setUint32(4, size)
      ..setUint8(8, 8)
      ..setUint8(9, 6)
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);
    final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
    _chunk(out, 'IDAT', Uint8List.fromList(ZLibEncoder().convert(raw.toBytes())));
    _chunk(out, 'IEND', Uint8List(0));
    return out.toBytes();
  }

  static void _chunk(BytesBuilder out, String type, Uint8List data) {
    final typeBytes = Uint8List.fromList(type.codeUnits);
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    out.add(typeBytes);
    out.add(data);
    final crc = _crc32([...typeBytes, ...data]);
    out.add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });

  static int _crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
