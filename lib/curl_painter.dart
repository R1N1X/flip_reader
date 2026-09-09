import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// ============================================================
/// GEOMETRY
/// ============================================================
///
/// The turning leaf is modeled as paper wrapping around a vertical
/// cylinder of radius r. Paper coordinate x runs from the spine (x = 0)
/// to the free edge (x = W). The fold line sits at paper coordinate c.
///
///   x <= c            flat on the book, front face up:  x' = x
///   c < x <= c+pi*r   on the cylinder, wrap angle th = (x - c) / r:
///                       x' = c + r*sin(th)
///                     For th < pi/2 the strip still faces the viewer
///                     (front face); past pi/2 it has bent over and the
///                     BACK face shows. Strip width compresses by cos(th):
///                     this foreshortening is what reads as a roll,
///                     not a hinge.
///   x > c + pi*r      wrapped a full half-turn, lying flat ON TOP,
///                     back face up, travelling left:
///                       x' = 2c + pi*r - x
///
/// As c sweeps from W down to -pi*r the whole leaf rolls over the
/// cylinder and comes to rest to the LEFT of the spine.
///
/// Back face content is the next page. A back strip at paper x samples
/// the back image at (W - x); combined with the reversed destination
/// mapping, the landed page reads left-to-right.
class CurlGeometry {
  final double pageW;
  final double r;
  const CurlGeometry(this.pageW, this.r);

  double get travel => pageW + pi * r; // c: pageW -> -pi*r

  double cForT(double t) => pageW - t * travel;
  double tForC(double c) => (pageW - c) / travel;

  double project(double x, double c) {
    if (x <= c) return x;
    final th = (x - c) / r;
    if (th <= pi) return c + r * sin(th);
    return 2 * c + pi * r - x;
  }

  /// How far a paper point stands out of the page plane, 0 flat on the book up
  /// to 2r at the far side of the cylinder. This is what perspective needs: the
  /// lifted paper is physically nearer the eye than the page beneath it.
  double depth(double x, double c) {
    if (x <= c) return 0;
    final th = (x - c) / r;
    if (th <= pi) return r * (1 - cos(th));
    return 2 * r;
  }

  /// cos of the wrap angle: > 0 front face visible, < 0 back face.
  double facing(double x, double c) {
    if (x <= c) return 1;
    final th = (x - c) / r;
    if (th <= pi) return cos(th);
    return -1;
  }

  double edge(double c) => project(pageW, c);

  /// Invert edge(): find c so the free edge sits at [target]. edge(c) is
  /// monotonic in c, so bisection converges in a couple dozen steps.
  /// This is what lets the leaf track the finger 1:1.
  double cForEdge(double target) {
    var lo = -pi * r, hi = pageW;
    final t = target.clamp(edge(lo), edge(hi));
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (edge(mid) < t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }
}

/// Long-lived paint objects. paint() only mutates these; it never
/// allocates a Paint, Path or Shader.
class CurlPaintResources {
  final Paint pagePaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint whitePaint = Paint()..color = Colors.white;
  final Paint shadePaint = Paint();
  final Paint shadowPaint = Paint();
  /// The shadow's depth. shadowPaint carries a shader, and a Paint with a
  /// shader ignores its own colour, so the fade has to come from a layer
  /// alpha instead. Allocated once, like everything else here.
  final Paint shadowLayerPaint = Paint();
  final Paint spinePaint = Paint();

  CurlPaintResources() {
    // Unit-space gradients, positioned per frame with canvas transforms.
    shadowPaint.shader = ui.Gradient.linear(
      const Offset(0, 0),
      const Offset(1, 0),
      [const Color(0xFF000000), const Color(0x00000000)],
    );
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

/// Draws the whole book area: static left page, the page under the leaf,
/// the leaf itself in vertical strips warped by the cylinder model,
/// curvature shading and the travelling fold shadow.
class CurlPainter extends CustomPainter {
  final CurlPaintResources res;
  final ui.Image? leftImage;
  final ui.Image? underImage;
  final ui.Image? frontImage;
  final ui.Image? backImage;
  final double spineX;
  final double pageW;
  final double c; // c >= pageW means the leaf lies flat (not turning)
  final double radius;
  final bool twoUp;

  /// Pages left ahead and behind, drawn as a stack of edges so the book has
  /// visible thickness. A single sheet floating in space never reads as a book,
  /// however good the turn is.
  final int pagesAhead;
  final int pagesBehind;

  /// Strength of the perspective on the lifted leaf, 0 for none.
  ///
  /// Without it every strip is the page's full height and the turn reads flat,
  /// like a page sliding rather than lifting. With it the raised paper grows and
  /// leans, because it is nearer the eye than the book it is lifting off.
  final double perspective;

  const CurlPainter({
    required this.res,
    required this.leftImage,
    required this.underImage,
    required this.frontImage,
    required this.backImage,
    required this.spineX,
    required this.pageW,
    required this.c,
    required this.radius,
    required this.twoUp,
    this.pagesAhead = 0,
    this.pagesBehind = 0,
    this.perspective = 1.0,
  });

  static const int _strips = 240;

  /// Viewer distance in page widths, and how far the leaf drifts down as it
  /// rises. Both tuned by eye against a real flipbook rather than derived:
  /// a physically exact camera looks stiffer than this.
  static const double _eyeDistance = 2.6;
  static const double _leanFactor = 0.055;

  /// At most this many edges are drawn. Beyond it the stack stops reading as
  /// depth and starts costing draw calls for nothing.
  static const int _maxStackEdges = 7;

  @override
  void paint(Canvas canvas, Size size) {
    // Deliberately no clip: a lifted page is taller than the book and hangs
    // past its top and bottom edges. Clipping to the book box is what makes a
    // turn look like a sliding rectangle.
    final h = size.height;
    final geom = CurlGeometry(pageW, radius);
    _drawStack(canvas, h);
    final turning = c < pageW;

    if (twoUp && leftImage != null) {
      _drawFull(
          canvas, leftImage!, Rect.fromLTWH(spineX - pageW, 0, pageW, h));
    }

    final rightRect = Rect.fromLTWH(spineX, 0, pageW, h);
    if (turning) {
      if (underImage != null) {
        _drawFull(canvas, underImage!, rightRect);
      } else {
        canvas.drawRect(rightRect, res.whitePaint); // blank sheet, no spinner
      }
      _drawLeaf(canvas, geom, h);
      _drawCastShadow(canvas, geom, h);
    } else {
      if (frontImage != null) {
        _drawFull(canvas, frontImage!, rightRect);
      } else {
        canvas.drawRect(rightRect, res.whitePaint);
      }
    }

    if (twoUp) {
      canvas.save();
      canvas.translate(spineX, 0);
      canvas.scale(pageW * 0.10, h);
      canvas.drawRect(const Rect.fromLTRB(-1, 0, 1, 1), res.spinePaint);
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

  void _drawFull(Canvas canvas, ui.Image img, Rect dst) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      res.pagePaint,
    );
  }

  void _drawLeaf(Canvas canvas, CurlGeometry geom, double h) {
    final dx = pageW / _strips;

    // Strips are drawn in ascending paper x, which is also ascending
    // height above the book, so plain painter's order is correct.
    for (var i = 0; i < _strips; i++) {
      final x0 = i * dx;
      final x1 = x0 + dx;
      final xm = x0 + dx / 2;

      final p0 = spineX + geom.project(x0, c);
      final p1 = spineX + geom.project(x1, c);
      if ((p1 - p0).abs() < 0.05) continue; // edge-on, invisible

      final face = geom.facing(xm, c);

      // Perspective. A strip standing z out of the page is nearer the eye, so
      // it projects taller, and the whole leaf leans as it rises. eyeDistance
      // is in page widths; smaller exaggerates, larger flattens.
      final z = geom.depth(xm, c);
      final scale = z <= 0
          ? 1.0
          : 1 + perspective * (z / (_eyeDistance * pageW)).clamp(0.0, 0.45);
      final lean = perspective * (z / max(2 * radius, 1)) * h * _leanFactor;
      final halfH = h * scale / 2;
      final centreY = h / 2 + lean;

      final dst = Rect.fromLTRB(
        min(p0, p1),
        centreY - halfH,
        max(p0, p1),
        centreY + halfH,
      );

      if (face >= 0) {
        final front = frontImage;
        if (front == null) {
          canvas.drawRect(dst, res.whitePaint);
        } else {
          final sx = front.width / pageW;
          canvas.drawImageRect(
            front,
            Rect.fromLTRB(x0 * sx, 0, x1 * sx, front.height.toDouble()),
            dst,
            res.pagePaint,
          );
        }
      } else {
        // Back face: next page, sampled mirrored at (pageW - x). The
        // destination endpoints are reversed too, so the landed content
        // reads normally.
        final back = backImage;
        if (back == null) {
          canvas.drawRect(dst, res.whitePaint);
        } else {
          final sx = back.width / pageW;
          canvas.drawImageRect(
            back,
            Rect.fromLTRB(
              (pageW - x1) * sx,
              0,
              (pageW - x0) * sx,
              back.height.toDouble(),
            ),
            dst,
            res.pagePaint,
          );
        }
      }

      // Curvature shading: darkest where the paper is edge-on.
      final bend = 1 - face.abs();
      if (bend > 0.02) {
        res.shadePaint.color = Color.fromRGBO(0, 0, 0, 0.35 * bend);
        canvas.drawRect(dst, res.shadePaint);
      }
    }
  }

  /// Shadow the lifted paper casts on the page beneath: anchored at the
  /// fold, widening and deepening mid-turn. The unit gradient shader is
  /// positioned with a canvas transform; nothing is allocated here.
  void _drawCastShadow(Canvas canvas, CurlGeometry geom, double h) {
    final t = geom.tForC(c).clamp(0.0, 1.0);
    final lift = sin(pi * t);
    if (lift < 0.02) return;
    final foldX = spineX + max(c, -radius) + radius * 0.4;
    final width = radius * (1.5 + 2.5 * lift);
    canvas.save();
    canvas.translate(foldX, 0);
    canvas.scale(width, h);
    res.shadowLayerPaint.color = Color.fromRGBO(0, 0, 0, 0.55 * lift);
    canvas.saveLayer(const Rect.fromLTRB(0, 0, 1, 1), res.shadowLayerPaint);
    canvas.drawRect(const Rect.fromLTRB(0, 0, 1, 1), res.shadowPaint);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(CurlPainter old) =>
      c != old.c ||
      spineX != old.spineX ||
      pageW != old.pageW ||
      twoUp != old.twoUp ||
      perspective != old.perspective ||
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
/// a turn always belongs to the CURRENT index going forward (t: 0 -> 1
/// advances). A backward gesture pre-decrements the index and starts at
/// t = 1, so both directions share one code path, and release always
/// animates from the current position - never from 0.
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
  final double radiusFactor;

  /// Perspective strength on the lifted leaf, passed straight to the painter.
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
  late final AnimationController _anim = AnimationController(vsync: this, value: 0);

  /// Guards the completion callback.
  ///
  /// AnimationController.animateTo() finishes with status `completed` whatever
  /// the target is, so a spring-back to 0 announced itself exactly like a page
  /// landing on 1 and the reader advanced a page on every cancelled drag. The
  /// turn is decided here from the target we asked for, not from the status,
  /// and the generation makes a superseded or interrupted run do nothing.
  int _animGeneration = 0;
  final CurlPaintResources _res = CurlPaintResources();

  bool _turning = false;
  bool _gestureForward = true;
  bool _dragging = false;
  double _bookW = 1;

  /// True while the one-off "you can drag this" nudge is playing, so its
  /// spring-back does not fire the haptic a real cancelled drag would.
  bool _hinting = false;

  double get _pageW => widget.twoUp ? _bookW / 2 : _bookW;
  double get _spineX => widget.twoUp ? _bookW / 2 : 0;
  CurlGeometry get _geom => CurlGeometry(_pageW, _pageW * widget.radiusFactor);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// Programmatic full turn (chevrons, autoplay). Animated, but still
  /// starts from wherever the leaf currently is.
  void next() {
    if (_turning || widget.index >= widget.spreadCount - 1) return;
    _turning = true;
    _gestureForward = true;
    _anim.value = 0.001;
    _animateTo(1);
    setState(() {});
  }

  void prev() {
    if (_turning || widget.index <= 0) return;
    widget.onIndexChanged(widget.index - 1);
    _turning = true;
    _gestureForward = false;
    _anim.value = 0.999;
    _animateTo(0);
    setState(() {});
  }

  void _animateTo(double target, {bool isHint = false}) {
    final generation = ++_animGeneration;
    final dist = (target - _anim.value).abs();
    _anim
        .animateTo(
          target,
          duration: Duration(
            milliseconds: (widget.duration.inMilliseconds * dist)
                .clamp(120, widget.duration.inMilliseconds)
                .toInt(),
          ),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _settle(generation, target, isHint: isHint));
  }

  /// Called when a run finishes. Ignores runs that were interrupted, superseded
  /// by a new gesture, or stopped short of where they were headed.
  void _settle(int generation, double target, {required bool isHint}) {
    if (!mounted || generation != _animGeneration || _dragging) return;
    if ((_anim.value - target).abs() > 0.001) return;

    _turning = false;

    if (isHint) {
      _hinting = false;
      setState(() {});
      return;
    }

    if (target >= 1) {
      // A page landing is the one moment worth a tick. It is what makes a
      // finished turn feel like an event rather than an animation ending.
      HapticFeedback.lightImpact();
      widget.onIndexChanged(widget.index + 1);
      _anim.value = 0;
    } else {
      HapticFeedback.selectionClick();
    }
    setState(() {});
  }

  void _onTapUp(TapUpDetails d, double width) {
    if (_turning) return;
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

  /// A short peel and release on the first page, once, to show the page is
  /// draggable. Nothing about a still image says "pull my corner".
  void hint() {
    if (_turning || widget.spreadCount < 2) return;
    _hinting = true;
    _turning = true;
    _gestureForward = true;
    _anim.value = 0.001;
    setState(() {});
    final generation = ++_animGeneration;
    _anim
        .animateTo(0.18, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic)
        .whenComplete(() {
      // A real drag during the nudge bumps the generation and cancels it.
      if (!mounted || !_hinting || generation != _animGeneration) return;
      _animateTo(0, isHint: true);
    });
  }

  void _onDragStart(DragStartDetails d) {
    widget.onInteraction?.call();
    if (_turning && _anim.isAnimating) _anim.stop(); // grab mid-flight
    _hinting = false; // a real gesture cancels the nudge and its haptic rules
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;

    if (!_turning) {
      if (d.delta.dx.abs() < 0.5) return;
      final forward = d.delta.dx < 0;
      if (forward && widget.index >= widget.spreadCount - 1) return;
      if (!forward && widget.index <= 0) return;
      _gestureForward = forward;
      _turning = true;
      if (forward) {
        _anim.value = 0.001;
      } else {
        widget.onIndexChanged(widget.index - 1);
        _anim.value = 0.999;
      }
      setState(() {});
    }

    // 1:1 tracking: solve the fold so the free edge sits under the finger.
    final c = _geom.cForEdge(d.localPosition.dx - _spineX);
    _anim.value = _geom.tForC(c).clamp(0.001, 0.999);
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    if (!_turning) return;

    final vx = d.velocity.pixelsPerSecond.dx;
    final t = _anim.value;
    double target;
    if (vx < -300) {
      target = 1;
    } else if (vx > 300) {
      target = 0;
    } else if (_gestureForward) {
      target = t > 0.35 ? 1 : 0;
    } else {
      target = t < 0.65 ? 0 : 1;
    }
    _animateTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      _bookW = cons.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        // Tapping the outer third of a page turns it. Dragging is the good
        // gesture, but a reader who has not discovered it yet still needs the
        // book to respond to the obvious thing.
        onTapUp: (d) => _onTapUp(d, cons.maxWidth),
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final geom = _geom;
            final i = widget.index;
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
                radius: geom.r,
                twoUp: widget.twoUp,
                perspective: widget.perspective,
                pagesAhead: widget.spreadCount - 1 - i,
                pagesBehind: i,
                c: _turning ? geom.cForT(_anim.value) : geom.pageW + 1,
              ),
            );
          },
        ),
      );
    });
  }
}
