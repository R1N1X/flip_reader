import 'package:flip_reader/curl_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fold = PageFold(400, 600);

  double area(List<Offset> poly) {
    var a = 0.0;
    for (var i = 0; i < poly.length; i++) {
      final p = poly[i], q = poly[(i + 1) % poly.length];
      a += p.dx * q.dy - q.dx * p.dy;
    }
    return a.abs() / 2;
  }

  test('a fully turned leaf mirrors exactly onto the left page', () {
    for (final top in [true, false]) {
      final c = fold.corner(top), p = fold.landed(top);
      final n = (p - c) / (p - c).distance, m = (c + p) / 2;
      for (final x in [const Offset(0, 0), const Offset(150, 300), const Offset(400, 600)]) {
        final r = PageFold.reflect(x, m, n);
        expect(r.dx, closeTo(-x.dx, 1e-9));
        expect(r.dy, closeTo(x.dy, 1e-9));
      }
    }
  });

  test('the fold splits the page into two parts that add back up', () {
    const c = Offset(400, 600), p = Offset(250, 380);
    final n = (p - c) / (p - c).distance, m = (c + p) / 2;
    final flat = PageFold.clip(fold.outline, m, n, positive: true);
    final lifted = PageFold.clip(fold.outline, m, n, positive: false);
    expect(area(flat) + area(lifted), closeTo(400 * 600, 1e-6));
    expect(area(lifted), greaterThan(0));
    expect(area(lifted), lessThan(area(flat)));
  });

  test('the corner can never pull the page off its spine', () {
    for (final top in [true, false]) {
      final near = Offset(0, top ? 0 : 600);
      for (final p in [const Offset(-900, -900), const Offset(900, 1500), const Offset(-50, 300)]) {
        final q = fold.constrain(p, top);
        expect((q - near).distance, lessThanOrEqualTo(400 + 1e-6));
      }
      // Both resting positions are already reachable and stay put.
      expect(fold.constrain(fold.corner(top), top), fold.corner(top));
      expect((fold.constrain(fold.landed(top), top) - fold.landed(top)).distance, lessThan(1e-6));
    }
  });

  test('progress runs from 0 flat to 1 turned', () {
    expect(fold.progress(fold.corner(false)), 0);
    expect(fold.progress(fold.landed(false)), 1);
    expect(fold.progress(const Offset(0, 600)), closeTo(0.5, 1e-9));
  });
}
