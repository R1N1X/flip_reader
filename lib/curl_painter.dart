import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// ============================================================
/// GEOMETRY
/// ============================================================
///
/// A corner peel, the way FlipHTML5 and turn.js do it. The reader grabs a
/// corner of the leaf (top or bottom, whichever is nearer the finger) and
/// drags it to P. Paper does not stretch, so the fold is the perpendicular
/// bisector of the corner C and P: every point nearer C than P has lifted
/// and is reflected across that line, showing its back face. The line can
/// sit at any angle, so the page follows the finger in any direction.
///
/// Coordinates are page space: origin at the top of the spine, x toward the
/// free edge, page W x H. The leaf is flat when P = C and has fully turned
/// when P = (-W, C.y): the fold is then the spine itself and the reflected
/// leaf lies exactly over the left page.
///
/// The leaf is bound at the spine, so P is kept within reach of both spine
/// ends. Without that the page would fold past its own binding and tear off.
class PageFold {
  const PageFold(this.w, this.h);

  final double w;
  final double h;

  Offset corner(bool top) => Offset(w, top ? 0 : h);
  Offset landed(bool top) => Offset(-w, top ? 0 : h);

  /// Pulls P back inside what a spine-bound page can reach: within W of the
  /// spine end on the grabbed corner's edge, and within the page diagonal of
  /// the other. Each pull can nudge the other limit, so settle a few rounds.
  Offset constrain(Offset p, bool top) {
    final near = Offset(0, top ? 0 : h);
    final far = Offset(0, top ? h : 0);
    final diagonal = sqrt(w * w + h * h);
    for (var i = 0; i < 3; i++) {
      p = _within(p, far, diagonal);
      p = _within(p, near, w);
    }
    return p;
  }

  static Offset _within(Offset p, Offset centre, double radius) {
    final d = p - centre;
    final len = d.distance;
    return len <= radius ? p : centre + d * (radius / len);
  }

  /// 0 flat to 1 fully turned, from how far the corner has travelled.
  double progress(Offset p) => ((w - p.dx) / (2 * w)).clamp(0.0, 1.0);

  List<Offset> get outline => [Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)];

  /// The part of [poly] on one side of the fold through [m] with unit normal
  /// [n]. Positive keeps the side n points to (the part still lying flat).
  static List<Offset> clip(List<Offset> poly, Offset m, Offset n, {required bool positive}) {
    double side(Offset x) {
      final v = (x.dx - m.dx) * n.dx + (x.dy - m.dy) * n.dy;
      return positive ? v : -v;
    }

    final out = <Offset>[];
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final sa = side(a), sb = side(b);
      if (sa >= 0) out.add(a);
      if ((sa >= 0) != (sb >= 0)) out.add(Offset.lerp(a, b, sa / (sa - sb))!);
    }
    return out;
  }

  /// Mirror of [x] across the fold through [m] with unit normal [n].
  static Offset reflect(Offset x, Offset m, Offset n) {
    final d = (x.dx - m.dx) * n.dx + (x.dy - m.dy) * n.dy;
    return x - n * (2 * d);
  }
}

/// Long-lived paint objects. paint() mutates these; the per-frame
/// allocations are the fold's clip paths and gradients, all small.
class CurlPaintResources {
  final Paint pagePaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint whitePaint = Paint()..color = Colors.white;
  final Paint shadePaint = Paint();
  final Paint gradientPaint = Paint();
  final Paint spinePaint = Paint();

  CurlPaintResources() {
    spinePaint.shader = ui.Gradient.linear(
      const Offset(-1, 0),
      const Offset(1, 0),
      [
        const Color(0x00000000),
        const Color(0x2E000000),
        const Color(0x00000000),
      ],
      const [0.0, 0.5, 1.0],
    );
  }
}

/// Draws the whole book area: static left page, the page revealed under the
/// fold, the flat part of the leaf, the folded-over flap showing its back
/// face, and the shading that sells the fold.
///
/// Only clips, one mirror transform and plain image draws. A drawVertices
/// mesh aborted the raster thread under Impeller on a Nothing Phone
/// (bad_function_call), so nothing here relies on it.
class CurlPainter extends CustomPainter {
  final CurlPaintResources res;
  final ui.Image? leftImage;
  final ui.Image? underImage;
  final ui.Image? frontImage;
  final ui.Image? backImage;
  final double spineX;
  final double pageW;

  /// Where the grabbed corner is now, in page space, or null while flat.
  final Offset? peel;

  /// Which corner is grabbed.
  final bool top;

  /// Width of the fold highlight as a fraction of the page, from the
  /// "Paper softness" setting. Wider reads as softer, more rounded paper.
  final double softness;

  /// Strength of the fold shading and cast shadow, from the "Depth" setting.
  final double depth;
  final bool twoUp;

  /// Pages left ahead and behind, drawn as a stack of edges so the book has
  /// visible thickness. A single sheet floating in space never reads as a book,
  /// however good the turn is.
  final int pagesAhead;
  final int pagesBehind;

  const CurlPainter({
    required this.res,
    required this.leftImage,
    required this.underImage,
    required this.frontImage,
    required this.backImage,
    required this.spineX,
    required this.pageW,
    required this.peel,
    required this.top,
    required this.twoUp,
    this.softness = 0.14,
    this.depth = 1.0,
    this.pagesAhead = 0,
    this.pagesBehind = 0,
  });

  /// At most this many edges are drawn. Beyond it the stack stops reading as
  /// depth and starts costing draw calls for nothing.
  static const int _maxStackEdges = 7;

  @override
  void paint(Canvas canvas, Size size) {
    // Deliberately no clip: the folded flap swings past the book's edges.
    final h = size.height;
    _drawStack(canvas, h);

    if (twoUp && leftImage != null) {
      _drawFull(canvas, leftImage!, Rect.fromLTWH(spineX - pageW, 0, pageW, h));
    }

    final fold = PageFold(pageW, h);
    final c = fold.corner(top);
    final p = peel;
    final pageRect = Rect.fromLTWH(spineX, 0, pageW, h);

    if (p == null || (p - c).distance < 0.5) {
      _drawPage(canvas, frontImage, pageRect);
    } else {
      canvas.save();
      canvas.translate(spineX, 0);
      _drawFold(canvas, fold, c, p);
      canvas.restore();
    }

    if (twoUp) {
      canvas.save();
      canvas.translate(spineX, 0);
      canvas.scale(pageW * 0.10, h);
      canvas.drawRect(const Rect.fromLTRB(-1, 0, 1, 1), res.spinePaint);
      canvas.restore();
    }
  }

  void _drawFold(Canvas canvas, PageFold fold, Offset c, Offset p) {
    final w = fold.w, h = fold.h;
    final page = Rect.fromLTWH(0, 0, w, h);
    final dist = (p - c).distance;
    final n = (p - c) / dist; // fold normal, pointing from the corner to P
    final m = (c + p) / 2; // a point on the fold

    final flat = PageFold.clip(fold.outline, m, n, positive: true);
    final lifted = PageFold.clip(fold.outline, m, n, positive: false);

    // Fade the shading in over the first bit of a peel and out as the page
    // lands, so it never pops on or off.
    final t = fold.progress(p);
    final fade = min(1.0, dist / (0.12 * w)) * min(1.0, (1 - t) * 5);
    final band = max(softness * w * 3, 8.0);

    // 1. The page underneath, whole. Drawn unclipped so no seam can open
    //    between it and the flat part along the fold.
    _drawPage(canvas, underImage, page);

    // 2. Shadow the lifted flap casts on it, darkest at the fold.
    if (lifted.length >= 3 && fade > 0) {
      canvas.save();
      canvas.clipPath(Path()..addPolygon(lifted, true));
      res.gradientPaint.shader = ui.Gradient.linear(
        m,
        m - n * band,
        [Color.fromRGBO(0, 0, 0, (0.45 * depth * fade).clamp(0.0, 0.9)), const Color(0x00000000)],
      );
      canvas.drawRect(page, res.gradientPaint);
      canvas.restore();
    }

    // 3. The part of the leaf still lying flat.
    if (flat.length >= 3) {
      canvas.save();
      canvas.clipPath(Path()..addPolygon(flat, true));
      _drawPage(canvas, frontImage, page);
      canvas.restore();
    }

    // 4. The flap: the lifted part mirrored across the fold, back face up.
    //    Clipping to the lifted polygon under the mirror transform puts the
    //    clip exactly where the flap lands.
    if (lifted.length >= 3) {
      final k = 2 * (m.dx * n.dx + m.dy * n.dy);
      final mirror = Matrix4(
        1 - 2 * n.dx * n.dx, -2 * n.dx * n.dy, 0, 0,
        -2 * n.dx * n.dy, 1 - 2 * n.dy * n.dy, 0, 0,
        0, 0, 1, 0,
        k * n.dx, k * n.dy, 0, 1,
      );
      canvas.save();
      canvas.transform(mirror.storage);
      canvas.clipPath(Path()..addPolygon(lifted, true));

      // The back face is the next page seen from behind, so it is mirrored in
      // x as well; with the fold mirror on top it reads the right way round,
      // and lands exactly as the static page when the turn completes.
      canvas.save();
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
      _drawPage(canvas, backImage, page);
      canvas.restore();

      // Grey at the crease, a soft highlight just past it where the paper
      // bends toward the light, then clear.
      if (fade > 0) {
        final a = depth.clamp(0.0, 2.0) * fade;
        res.gradientPaint.shader = ui.Gradient.linear(
          m,
          m - n * band,
          [
            Color.fromRGBO(0, 0, 0, (0.22 * a).clamp(0.0, 0.6)),
            Color.fromRGBO(255, 255, 255, (0.30 * a).clamp(0.0, 0.6)),
            const Color(0x00FFFFFF),
          ],
          const [0.0, 0.3, 1.0],
        );
        canvas.drawRect(page, res.gradientPaint);
      }
      canvas.restore();
    }
  }

  /// Edges of the pages not being shown, fanned out from the block's outer
  /// side. Drawn before everything else so the live pages sit on top.
  void _drawStack(Canvas canvas, double h) {
    void edges(int count, double fromX, double direction) {
      final n = count.clamp(0, _maxStackEdges);
      for (var i = n; i > 0; i--) {
        final inset = i * 1.4;
        res.shadePaint.color = Color.fromRGBO(0, 0, 0, 0.05 + 0.03 * (n - i));
        canvas.drawRect(
          Rect.fromLTWH(fromX + direction * inset, inset * 0.6, 2.2, h - inset * 1.2),
          res.shadePaint,
        );
      }
    }

    edges(pagesAhead, spineX + pageW, 1);
    if (twoUp) edges(pagesBehind, spineX - pageW, -1);
  }

  /// A page image, or a blank white sheet while it is still rendering.
  void _drawPage(Canvas canvas, ui.Image? img, Rect dst) {
    if (img == null) {
      canvas.drawRect(dst, res.whitePaint);
    } else {
      _drawFull(canvas, img, dst);
    }
  }

  void _drawFull(Canvas canvas, ui.Image img, Rect dst) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      res.pagePaint,
    );
  }

  @override
  bool shouldRepaint(CurlPainter old) =>
      peel != old.peel ||
      top != old.top ||
      softness != old.softness ||
      depth != old.depth ||
      spineX != old.spineX ||
      pageW != old.pageW ||
      twoUp != old.twoUp ||
      pagesAhead != old.pagesAhead ||
      pagesBehind != old.pagesBehind ||
      leftImage != old.leftImage ||
      underImage != old.underImage ||
      frontImage != old.frontImage ||
      backImage != old.backImage;
}

/// Which image a slot request refers to during a turn.
enum CurlSlot { leftStatic, under, front, back }

/// Owns the drag state machine and release animation. Index semantics:
/// a turn always belongs to the CURRENT index going forward (flat to
/// landed advances). A backward gesture pre-decrements the index and starts
/// landed, so both directions share one code path, and release always
/// animates from wherever the corner is - never from the start.
class CurlBookView extends StatefulWidget {
  final int spreadCount;
  final int index;
  final bool twoUp;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback? onInteraction;

  /// A tap in the middle of the page, which is not a turn. The shell uses it to
  /// show and hide the chrome; without it this widget swallows every tap on the
  /// book and that toggle stops working.
  final VoidCallback? onTapCentre;
  final ui.Image? Function(int spread, CurlSlot slot) resolve;

  /// "Paper softness": width of the fold highlight, as a fraction of the page.
  final double radiusFactor;

  /// "Depth": strength of the fold shading and cast shadow.
  final double perspective;

  /// How long a released page takes to finish its turn at full distance. A
  /// partial turn is scaled down from this, so a nearly-complete drag snaps
  /// closed rather than crawling.
  final Duration duration;

  const CurlBookView({
    super.key,
    required this.spreadCount,
    required this.index,
    required this.twoUp,
    required this.onIndexChanged,
    required this.resolve,
    this.onInteraction,
    this.onTapCentre,
    this.radiusFactor = 0.13,
    this.perspective = 1.0,
    this.duration = const Duration(milliseconds: 520),
  });

  @override
  State<CurlBookView> createState() => CurlBookViewState();
}

class CurlBookViewState extends State<CurlBookView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this)
    ..addListener(_onTick);

  /// Where the grabbed corner is, in page space. Null while the leaf is flat.
  /// The painter listens to this directly, so a drag repaints without a
  /// rebuild.
  final ValueNotifier<Offset?> _peel = ValueNotifier(null);

  /// Guards the completion callback.
  ///
  /// AnimationController.animateTo() finishes with status `completed` whether
  /// or not the page was meant to turn, so a spring-back once announced itself
  /// exactly like a landing and the reader advanced a page on every cancelled
  /// drag. The outcome is decided from the target we asked for, and the
  /// generation makes a superseded or interrupted run do nothing.
  int _animGeneration = 0;
  final CurlPaintResources _res = CurlPaintResources();

  /// The spread this view is showing. Kept here rather than read from the
  /// widget because a turn can land and the next one start before the parent
  /// has rebuilt with the new index; reading the stale widget.index then sent
  /// a quick back-tap two pages back.
  late int _index = widget.index;

  bool _turning = false;
  bool _gestureForward = true;
  bool _dragging = false;
  bool _top = false;
  double _bookW = 1;
  double _bookH = 1;

  /// The running animation's path: a curve from [_from] to [_to] bowed
  /// through [_via], so the corner swings in an arc instead of sliding in a
  /// straight line, which would keep the fold vertical like a plain hinge.
  Offset _from = Offset.zero;
  Offset _via = Offset.zero;
  Offset _to = Offset.zero;

  /// Whether the running animation ends with the page turned.
  bool _toTurned = false;

  /// Finger and corner position when the drag took hold of the leaf. The
  /// corner follows the finger's movement from there rather than jumping to
  /// sit under it.
  Offset _dragF0 = Offset.zero;
  Offset _dragP0 = Offset.zero;

  /// True while the one-off "you can drag this" nudge is playing, so its
  /// spring-back does not fire the haptic a real cancelled drag would.
  bool _hinting = false;

  double get _pageW => widget.twoUp ? _bookW / 2 : _bookW;
  double get _spineX => widget.twoUp ? _bookW / 2 : 0;
  PageFold get _fold => PageFold(_pageW, _bookH);

  @override
  void didUpdateWidget(CurlBookView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _index) return;
    // Moved from outside (slider, thumbnails, contents, rotation): whatever
    // turn was in flight belongs to the old page, so drop it.
    _anim.stop();
    _animGeneration++;
    _peel.value = null;
    _turning = false;
    _dragging = false;
    _hinting = false;
    _index = widget.index;
  }

  @override
  void dispose() {
    _anim.dispose();
    _peel.dispose();
    super.dispose();
  }

  void _setIndex(int i) {
    _index = i;
    widget.onIndexChanged(i);
  }

  void _onTick() {
    final s = _anim.value, u = 1 - s;
    final p = _from * (u * u) + _via * (2 * u * s) + _to * (s * s);
    _peel.value = _fold.constrain(p, _top);
  }

  /// Animates the corner from where it is to [to].
  void _run(
    Offset to, {
    required bool turned,
    Curve curve = Curves.easeOutCubic,
    Duration? duration,
    VoidCallback? then,
    bool isHint = false,
  }) {
    final generation = ++_animGeneration;
    final fold = _fold;
    _from = _peel.value ?? fold.corner(_top);
    _to = to;
    _toTurned = turned;

    // Bow the path toward the middle of the page, more for longer journeys.
    final span = ((to.dx - _from.dx).abs() / (2 * fold.w)).clamp(0.0, 1.0);
    _via = (_from + to) / 2 + Offset(0, (_top ? 1 : -1) * 0.22 * fold.h * span);

    final full = widget.duration.inMilliseconds;
    _anim.value = 0;
    _anim
        .animateTo(
          1,
          duration: duration ??
              Duration(milliseconds: (full * span).clamp(120, full).toInt()),
          curve: curve,
        )
        .whenComplete(() => _settle(generation, isHint: isHint, then: then));
  }

  /// Lands a running turn immediately, exactly as if it had finished.
  void _finishNow() {
    if (!_turning || _dragging) return;
    _anim.stop();
    if (_hinting) {
      _animGeneration++;
      _hinting = false;
      _turning = false;
      _peel.value = null;
      setState(() {});
      return;
    }
    _peel.value = _to;
    _settle(++_animGeneration, isHint: false);
  }

  /// Called when a run finishes. Ignores runs that were interrupted or
  /// superseded by a new gesture.
  void _settle(int generation, {required bool isHint, VoidCallback? then}) {
    if (!mounted || generation != _animGeneration || _dragging) return;
    if (then != null) {
      then();
      return;
    }

    _turning = false;
    _peel.value = null;

    if (isHint) {
      _hinting = false;
      setState(() {});
      return;
    }

    if (_toTurned) {
      // A page landing is the one moment worth a tick. It is what makes a
      // finished turn feel like an event rather than an animation ending.
      HapticFeedback.lightImpact();
      _setIndex(_index + 1);
    } else {
      HapticFeedback.selectionClick();
    }
    setState(() {});
  }

  /// Programmatic full turn (chevrons, autoplay, taps), from the bottom
  /// corner. A turn still in flight is landed first, so quick repeated taps
  /// each turn a page instead of being ignored.
  void next() {
    _finishNow();
    if (_turning || _index >= widget.spreadCount - 1) return;
    _turning = true;
    _gestureForward = true;
    _top = false;
    _peel.value = _fold.corner(false);
    _run(_fold.landed(false), turned: true, curve: Curves.easeInOutCubic);
    setState(() {});
  }

  void prev() {
    _finishNow();
    if (_turning || _index <= 0) return;
    _setIndex(_index - 1);
    _turning = true;
    _gestureForward = false;
    _top = false;
    _peel.value = _fold.landed(false);
    _run(_fold.corner(false), turned: false, curve: Curves.easeInOutCubic);
    setState(() {});
  }

  void _onTapUp(TapUpDetails d, double width) {
    widget.onInteraction?.call();
    final x = d.localPosition.dx;
    if (x > width * 0.66) {
      next();
    } else if (x < width * 0.34) {
      prev();
    } else {
      widget.onTapCentre?.call();
    }
  }

  /// A short peel of the bottom corner and release, once, to show the page
  /// is draggable. Nothing about a still image says "pull my corner".
  void hint() {
    if (_turning || widget.spreadCount < 2) return;
    final fold = _fold;
    _hinting = true;
    _turning = true;
    _gestureForward = true;
    _top = false;
    final corner = fold.corner(false);
    _peel.value = corner;
    setState(() {});
    _run(
      corner + Offset(-0.22 * fold.w, -0.12 * fold.h),
      turned: false,
      duration: const Duration(milliseconds: 420),
      isHint: true,
      then: () => _run(corner, turned: false, isHint: true),
    );
  }

  void _onDragStart(DragStartDetails d) {
    widget.onInteraction?.call();
    // A new swipe while a page is still moving lands that page and turns the
    // next one, so fast flicks each count instead of fighting the animation.
    _finishNow();
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final fold = _fold;

    if (!_turning) {
      if (d.delta.dx.abs() < 0.5) return;
      final forward = d.delta.dx < 0;
      if (forward && _index >= widget.spreadCount - 1) return;
      if (!forward && _index <= 0) return;
      _gestureForward = forward;
      _turning = true;
      // Grab the corner on the finger's half of the page, like a real one.
      _top = d.localPosition.dy < _bookH / 2;
      if (!forward) _setIndex(_index - 1);
      _dragP0 = forward ? fold.corner(_top) : fold.landed(_top);
      _dragF0 = d.localPosition;
      setState(() {});
    }

    // The corner travels 2 page widths across. Over a spread the finger has
    // that room, so the corner follows it 1:1; on a single page it has half,
    // so the corner moves at twice the finger across, which keeps the fold
    // itself under the finger. Up and down is always 1:1.
    final gain = widget.twoUp ? 1.0 : 2.0;
    final delta = d.localPosition - _dragF0;
    _peel.value = fold.constrain(_dragP0 + Offset(delta.dx * gain, delta.dy), _top);
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    if (!_turning) return;

    final fold = _fold;
    final vx = d.velocity.pixelsPerSecond.dx;
    final t = fold.progress(_peel.value ?? fold.corner(_top));
    bool turn;
    if (vx < -300) {
      turn = true;
    } else if (vx > 300) {
      turn = false;
    } else if (_gestureForward) {
      turn = t > 0.35;
    } else {
      turn = t >= 0.65;
    }
    _run(turn ? fold.landed(_top) : fold.corner(_top), turned: turn);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      _bookW = cons.maxWidth;
      _bookH = cons.maxHeight;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        // A horizontal drag starts the turn, so vertical movement is still
        // free for anything above; once it has started, the corner follows the
        // finger's full position, up and down included.
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        // Tapping the outer third of a page turns it. Dragging is the good
        // gesture, but a reader who has not discovered it yet still needs the
        // book to respond to the obvious thing.
        onTapUp: (d) => _onTapUp(d, cons.maxWidth),
        child: ValueListenableBuilder<Offset?>(
          valueListenable: _peel,
          builder: (context, peel, _) {
            final i = _index;
            return CustomPaint(
              size: Size(cons.maxWidth, cons.maxHeight),
              painter: CurlPainter(
                res: _res,
                leftImage: widget.resolve(i, CurlSlot.leftStatic),
                underImage: widget.resolve(i, CurlSlot.under),
                frontImage: widget.resolve(i, CurlSlot.front),
                backImage: widget.resolve(i, CurlSlot.back),
                spineX: _spineX,
                pageW: _pageW,
                peel: _turning ? peel : null,
                top: _top,
                twoUp: widget.twoUp,
                softness: widget.radiusFactor,
                depth: widget.perspective,
                pagesAhead: widget.spreadCount - 1 - i,
                pagesBehind: i,
              ),
            );
          },
        ),
      );
    });
  }
}
