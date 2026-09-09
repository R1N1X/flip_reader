import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dart:io';

import 'package:flutter/services.dart';

import 'contents_sheet.dart';
import 'curl_painter.dart';
import 'hotspot_layer.dart';
import 'hotspots.dart' as hs;
import 'pdf_pipeline.dart';
import 'reader_settings.dart';
import 'settings_sheet.dart';

/// The reader chrome around the curl view: stage, chevrons, thumbnail
/// strip, toolbar, thumbnail grid overlay, autoplay, zoom. Everything
/// auto-hides after 3 s and reappears on tap.
class ReaderShell extends StatefulWidget {
  final PdfBook book;
  const ReaderShell({super.key, required this.book, this.hotspotsAsset});

  /// Interactive elements for this document, or null when there are none.
  ///
  /// Hotspot coordinates describe one specific PDF, so they travel with that
  /// document rather than with the reader. A picked PDF gets none.
  final String? hotspotsAsset;

  @override
  State<ReaderShell> createState() => _ReaderShellState();
}

class _ReaderShellState extends State<ReaderShell> {
  final _curlKey = GlobalKey<CurlBookViewState>();
  final _zoomCtrl = TransformationController();
  final settings = ReaderSettings();

  hs.HotspotSet _hotspots = hs.HotspotSet.empty();

  /// Interactive areas glow briefly when a page settles, then fade. They are
  /// invisible in the PDF itself, so the reader has to be told they exist
  /// without the highlight sitting there permanently over the artwork.
  double _hotspotReveal = 0;
  Timer? _hotspotTimer;

  /// The drag hint plays once per document, after the cover has actually
  /// rendered. Nudging a blank sheet teaches nothing.
  bool _hintShown = false;
  Timer? _hintTimer;

  int _spread = 0;
  bool _twoUp = false;
  bool _chrome = true;
  bool _autoplay = false;
  Timer? _chromeTimer;
  Timer? _autoplayTimer;
  TapDownDetails? _doubleTapDown;

  PdfBook get book => widget.book;

  @override
  void initState() {
    super.initState();
    book.addListener(_onBook);
    settings.addListener(_onFullscreenMaybeChanged);
    settings.addListener(_onBook);
    _restartChromeTimer();
    final asset = widget.hotspotsAsset;
    if (asset != null) {
      hs.HotspotSet.load(asset).then((set) {
        if (mounted) setState(() => _hotspots = set);
      });
    }
  }

  @override
  void dispose() {
    book.removeListener(_onBook);
    settings.removeListener(_onBook);
    settings.removeListener(_onFullscreenMaybeChanged);
    settings.dispose();
    _hotspotTimer?.cancel();
    _hintTimer?.cancel();
    _chromeTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _autoplayTimer?.cancel();
    _zoomCtrl.dispose();
    super.dispose();
  }

  int _lastPageCount = 0;

  /// A new document can be shorter than the one it replaced, which would leave
  /// the index past the end. Reset to the cover and re-window whenever the
  /// document changes.
  void _onBook() {
    if (book.pageCount != _lastPageCount) {
      _lastPageCount = book.pageCount;
      _spread = 0;
      _hintShown = false;
      _hotspots = hs.HotspotSet.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
    }
    setState(() {});
  }

  bool _fullscreenApplied = false;

  /// Fullscreen hides the status and navigation bars entirely. Applied only on
  /// change, since setting the UI mode every rebuild makes the bars flicker.
  void _onFullscreenMaybeChanged() {
    if (settings.fullscreen == _fullscreenApplied) return;
    _fullscreenApplied = settings.fullscreen;
    SystemChrome.setEnabledSystemUIMode(
      settings.fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// Plays the drag hint once, as soon as the first page is on screen.
  void _maybeHint() {
    if (_hintShown || book.image(0) == null) return;
    _hintShown = true;
    _hintTimer = Timer(const Duration(milliseconds: 550), () {
      if (mounted) _curlKey.currentState?.hint();
    });
  }

  /// Pulse the hotspot highlights, then let them fade back out.
  void _revealHotspots() {
    _hotspotTimer?.cancel();
    if (!settings.showHotspots) return;
    setState(() => _hotspotReveal = 1);
    _hotspotTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hotspotReveal = 0.18);
    });
  }

  // ---- spread math ----------------------------------------------------

  int get _spreadCount {
    final n = book.pageCount;
    if (n == 0) return 1;
    return _twoUp ? 1 + ((n - 1) / 2).ceil() : n;
  }

  int _leftPage(int spread) => _twoUp ? (spread == 0 ? 0 : spread * 2 - 1) : spread;
  int _rightPage(int spread) => _twoUp ? (spread == 0 ? 0 : spread * 2) : spread;
  int _spreadOfPage(int p) => _twoUp ? (p == 0 ? 0 : (p + 1) ~/ 2) : p;

  void _setSpread(int s) {
    _revealHotspots();
    setState(() => _spread = s.clamp(0, _spreadCount - 1));
    _updateWindow();
  }

  void _updateWindow() {
    final l = _leftPage(_spread), r = _rightPage(_spread);
    book.setWindow([for (var p = l - 4; p <= r + 4; p++) p]);
  }

  // ---- image resolution for the curl view -----------------------------

  ui.Image? _resolve(int spread, CurlSlot slot) {
    final n = book.pageCount;
    int? page;
    if (_twoUp) {
      if (slot == CurlSlot.leftStatic) {
        page = spread == 0 ? null : _leftPage(spread);
      } else if (slot == CurlSlot.front) {
        page = _rightPage(spread);
      } else if (slot == CurlSlot.under) {
        final next = spread + 1;
        page = next < _spreadCount ? _rightPage(next) : null;
      } else {
        final next = spread + 1;
        page = next < _spreadCount ? _leftPage(next) : null;
      }
    } else {
      if (slot == CurlSlot.leftStatic) return null;
      if (slot == CurlSlot.front) page = spread;
      if (slot == CurlSlot.under || slot == CurlSlot.back) page = spread + 1;
    }
    if (page == null || page < 0 || page >= n) return null;
    return book.image(page);
  }

  // ---- chrome / autoplay ----------------------------------------------

  void _restartChromeTimer() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  void _poke() {
    if (!_chrome) setState(() => _chrome = true);
    _restartChromeTimer();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    if (_chrome) _restartChromeTimer();
  }

  void _toggleAutoplay() {
    setState(() => _autoplay = !_autoplay);
    _autoplayTimer?.cancel();
    if (_autoplay) {
      _autoplayTimer = Timer.periodic(Duration(seconds: settings.autoplaySeconds), (_) {
        if (_spread >= _spreadCount - 1) {
          _toggleAutoplay();
        } else {
          _curlKey.currentState?.next();
        }
      });
    }
    _poke();
  }

  // ---- zoom -----------------------------------------------------------

  bool get _zoomed => _zoomCtrl.value.getMaxScaleOnAxis() > 1.01;

  void _zoomTo(double scale, Offset focal) {
    if (scale <= 1) {
      _zoomCtrl.value = Matrix4.identity();
    } else {
      _zoomCtrl.value = Matrix4.identity()
        ..translateByDouble(-focal.dx * (scale - 1), -focal.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, scale, 1);
    }
    setState(() {});
  }

  void _toggleZoomButton() {
    _zoomTo(_zoomed ? 1 : 2,
        Offset(MediaQuery.sizeOf(context).width / 4, 0));
    _poke();
  }

  // ---- UI -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final twoUp = mq.orientation == Orientation.landscape && settings.doublePageInLandscape;
    if (twoUp != _twoUp) {
      final page = _leftPage(_spread);
      _twoUp = twoUp;
      _spread = _spreadOfPage(page);
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
    }

    if (!book.isOpen) {
      return const ColoredBox(color: Color(0xFF10131A));
    }

    return LayoutBuilder(builder: (context, cons) {
      // Book box: keep the PDF's own aspect ratio.
      final bookAspect = _twoUp ? book.aspect * 2 : book.aspect;
      var bw = cons.maxWidth - 24;
      var bh = bw / bookAspect;
      // Generous vertical margin: a lifted page projects taller than the book
      // and needs somewhere to hang past its edges.
      // Generous vertical margin so a lifted page has somewhere to hang past
      // the book's edges, but never more than the screen can give: on a short
      // viewport a fixed 96 would drive the book to zero height or negative.
      final maxH = (cons.maxHeight - 96).clamp(120.0, cons.maxHeight);
      if (bh > maxH) {
        bh = maxH;
        bw = bh * bookAspect;
      }
      book.setRenderTarget(_twoUp ? bw / 2 : bw, mq.devicePixelRatio);
      _updateWindowOnce();
      _maybeHint();

      return Stack(children: [
        // Stage + book
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleChrome,
            onDoubleTapDown: (d) => _doubleTapDown = d,
            onDoubleTap: () {
              final d = _doubleTapDown;
              _zoomTo(_zoomed ? 1 : 2.2, d?.localPosition ?? Offset.zero);
              _poke();
            },
            child: Container(
              decoration: BoxDecoration(
                color: settings.skin.isGradient ? null : settings.skin.colors.first,
                gradient: settings.skin.isGradient ? settings.skin.gradient : null,
              ),
              alignment: Alignment.center,
              child: InteractiveViewer(
                transformationController: _zoomCtrl,
                panEnabled: _zoomed,
                scaleEnabled: true,
                maxScale: 5,
                onInteractionEnd: (_) => setState(() {}),
                child: SizedBox(
                  width: bw,
                  height: bh,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(boxShadow: [
                      BoxShadow(
                        color: Colors.black87,
                        blurRadius: 32,
                        offset: Offset(0, 12),
                      ),
                    ]),
                    child: Stack(children: [
                      IgnorePointer(
                        // While zoomed, drags pan; the leaf is not draggable.
                        ignoring: _zoomed,
                        child: CurlBookView(
                          key: _curlKey,
                          spreadCount: _spreadCount,
                          index: _spread,
                          twoUp: _twoUp,
                          onIndexChanged: (i) {
                            _setSpread(i);
                            if (_autoplay && i >= _spreadCount - 1) {
                              _toggleAutoplay();
                            }
                          },
                          onInteraction: _poke,
                          onTapCentre: _toggleChrome,
                          resolve: _resolve,
                          radiusFactor: settings.curlSoftness,
                          perspective: settings.perspective,
                          duration: settings.flipSpeed.duration,
                        ),
                      ),
                      if (settings.showHotspots && !_zoomed) ..._hotspotLayers(),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),

        // Chevrons
        if (settings.showChevrons) ...[
          _chevron(left: true),
          _chevron(left: false),
        ],

        if (settings.showLogo) _logo(cons),

        // Bottom chrome: thumbnail strip + toolbar
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !_chrome,
            child: AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (settings.showThumbStrip) _thumbStrip(),
                if (settings.showToolbar) _toolbar(),
              ]),
            ),
          ),
        ),

        // Thumbnail grid overlay
      ]);
    });
  }

  bool _windowInit = false;
  void _updateWindowOnce() {
    if (_windowInit) return;
    _windowInit = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
  }

  Widget _chevron({required bool left}) {
    final enabled = left ? _spread > 0 : _spread < _spreadCount - 1;
    return Positioned(
      left: left ? 4 : null,
      right: left ? null : 4,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _chrome && enabled ? 0.8 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_chrome || !enabled,
            child: IconButton(
              iconSize: 36,
              color: Colors.white,
              style: IconButton.styleFrom(backgroundColor: Colors.black38),
              icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
              onPressed: () {
                _poke();
                left
                    ? _curlKey.currentState?.prev()
                    : _curlKey.currentState?.next();
              },
            ),
          ),
        ),
      ),
    );
  }

  String get _indicator {
    final n = book.pageCount;
    if (!_twoUp || _spread == 0) return '${_leftPage(_spread) + 1}/$n';
    final l = _leftPage(_spread) + 1;
    final r = (_rightPage(_spread) + 1).clamp(1, n);
    return l == r ? '$l/$n' : '$l-$r/$n';
  }

  Widget _thumbStrip() {
    final n = book.pageCount;
    final current = _leftPage(_spread);
    return Container(
      height: 84,
      color: const Color(0xCC15181F),
      child: Row(children: [
        IconButton(
          tooltip: 'First page',
          color: Colors.white70,
          icon: const Icon(Icons.first_page),
          onPressed: _spread > 0
              ? () {
                  _setSpread(0);
                  _poke();
                }
              : null,
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: n,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemBuilder: (context, i) {
              final img = book.thumb(i);
              final selected = _twoUp
                  ? (i == _leftPage(_spread) || i == _rightPage(_spread))
                  : i == current;
              return GestureDetector(
                onTap: () {
                  _setSpread(_spreadOfPage(i));
                  _poke();
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected ? Colors.lightBlueAccent : Colors.white24,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: AspectRatio(
                    aspectRatio: book.aspect,
                    child: img == null
                        ? const ColoredBox(color: Colors.white)
                        : RawImage(image: img, fit: BoxFit.cover),
                  ),
                ),
              );
            },
          ),
        ),
        IconButton(
          tooltip: 'Last page',
          color: Colors.white70,
          icon: const Icon(Icons.last_page),
          onPressed: _spread < _spreadCount - 1
              ? () {
                  _setSpread(_spreadCount - 1);
                  _poke();
                }
              : null,
        ),
      ]),
    );
  }

  Widget _toolbar() {
    return Container(
      color: settings.skin.toolbarColor.withValues(alpha: 0.9),
      padding: EdgeInsets.only(
        left: 4,
        right: 4,
        bottom: MediaQuery.paddingOf(context).bottom,
      ),
      child: Row(children: [
        IconButton(
          tooltip: 'Library',
          color: Colors.white70,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        IconButton(
          tooltip: 'Zoom',
          color: Colors.white70,
          icon: Icon(_zoomed ? Icons.zoom_out : Icons.zoom_in),
          onPressed: _toggleZoomButton,
        ),
        IconButton(
          tooltip: 'Contents and bookmarks',
          color: Colors.white70,
          icon: const Icon(Icons.grid_view),
          onPressed: _openContents,
        ),
        IconButton(
          tooltip: settings.isBookmarked(_leftPage(_spread)) ? 'Remove bookmark' : 'Bookmark',
          color: Colors.white70,
          icon: Icon(settings.isBookmarked(_leftPage(_spread))
              ? Icons.bookmark
              : Icons.bookmark_border),
          onPressed: () {
            settings.toggleBookmark(_leftPage(_spread));
            _poke();
          },
        ),
        if (settings.showPageNumber)
          Text(_indicator,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: _leftPage(_spread).toDouble(),
              min: 0,
              max: (book.pageCount - 1).toDouble(),
              onChanged: (v) {
                _setSpread(_spreadOfPage(v.round()));
                _poke();
              },
            ),
          ),
        ),
        IconButton(
          tooltip: settings.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
          color: Colors.white70,
          icon: Icon(settings.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
          onPressed: () {
            settings.setFullscreen(!settings.fullscreen);
            _poke();
          },
        ),
        IconButton(
          tooltip: _autoplay ? 'Pause' : 'Autoplay',
          color: Colors.white70,
          icon: Icon(_autoplay ? Icons.pause_circle : Icons.play_circle),
          onPressed: _toggleAutoplay,
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          iconColor: Colors.white70,
          onSelected: (v) {
            if (v == 'settings') _openSettings();
            if (v == 'goto') _promptGoTo();
            if (v == 'reset') _zoomTo(1, Offset.zero);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'settings', child: Text('Customize…')),
            PopupMenuItem(value: 'goto', child: Text('Go to page…')),
            PopupMenuItem(value: 'reset', child: Text('Reset zoom')),
          ],
        ),
      ]),
    );
  }

  /// Hotspot layers for the visible page or pages.
  ///
  /// In a spread the two halves are separate pages with their own coordinate
  /// space, so each half gets its own layer. One layer stretched across the
  /// spread would put every hotspot at the wrong x.
  List<Widget> _hotspotLayers() {
    if (_hotspots.isEmpty) return const [];

    Widget? layerFor(int page) {
      final spots = _hotspots.forPage(page);
      if (spots.isEmpty) return null;
      return HotspotLayer(
        hotspots: spots,
        reveal: _hotspotReveal,
        onGoToPage: (target) => _setSpread(_spreadOfPage(target)),
      );
    }

    if (!_twoUp) {
      final layer = layerFor(_leftPage(_spread));
      return layer == null ? const [] : [Positioned.fill(child: layer)];
    }

    // Spread 0 is the cover alone on the right, matching the curl painter.
    final left = _spread == 0 ? null : layerFor(_leftPage(_spread));
    final right = layerFor(_rightPage(_spread));
    if (left == null && right == null) return const [];

    return [
      Positioned.fill(
        child: Row(
          children: [
            Expanded(child: left ?? const SizedBox.shrink()),
            Expanded(child: right ?? const SizedBox.shrink()),
          ],
        ),
      ),
    ];
  }

  /// Branding overlay. Sits above the book but never eats a gesture, so it
  /// cannot block a page turn that starts near the top of the screen.
  /// Branding overlay, positioned as a fraction of the screen and draggable
  /// once unlocked.
  ///
  /// Locked it ignores pointers entirely, so it can never swallow a page turn
  /// that starts underneath it. Unlocked it takes drags, which is the whole
  /// point, and gains a dashed outline so the reader can see what is grabbable.
  Widget _logo(BoxConstraints cons) {
    final unlocked = settings.logoUnlocked;

    return Positioned(
      left: settings.logoX * cons.maxWidth,
      top: settings.logoY * cons.maxHeight,
      child: IgnorePointer(
        ignoring: !unlocked,
        child: GestureDetector(
          onPanUpdate: (d) => settings.setLogoPosition(
            settings.logoX + d.delta.dx / cons.maxWidth,
            settings.logoY + d.delta.dy / cons.maxHeight,
          ),
          child: AnimatedOpacity(
            opacity: unlocked ? 1 : (_chrome ? settings.logoOpacity : settings.logoOpacity * 0.35),
            duration: const Duration(milliseconds: 200),
            child: Container(
              decoration: unlocked
                  ? BoxDecoration(
                      border: Border.all(color: const Color(0xCC4FA3FF), width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              padding: unlocked ? const EdgeInsets.all(3) : EdgeInsets.zero,
              child: _logoContent(),
            ),
          ),
        ),
      ),
    );
  }

  /// The logo itself: a picked image when there is one, otherwise the text.
  Widget _logoContent() {
    final path = settings.logoImagePath;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: path == null ? 10 : 6,
        vertical: path == null ? 5 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: path == null
          ? Text(
              settings.logoText,
              style: TextStyle(
                color: Colors.white,
                fontSize: settings.logoHeight * 0.45,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            )
          : Image.file(
              File(path),
              height: settings.logoHeight,
              fit: BoxFit.contain,
              // The picked file lives in the app cache and can be cleared, so
              // fall back to the text logo rather than showing a broken box.
              errorBuilder: (_, _, _) => Text(
                settings.logoText,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: settings.logoHeight * 0.45,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
    );
  }

  void _openSettings() {
    _chromeTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SettingsSheet(settings: settings, book: book),
    ).whenComplete(_poke);
  }

  void _openContents() {
    _chromeTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => ContentsSheet(
        settings: settings,
        pageCount: book.pageCount,
        currentPage: _leftPage(_spread),
        thumbOf: book.thumb,
        onJump: (page) {
          Navigator.of(context).pop();
          _setSpread(_spreadOfPage(page));
        },
      ),
    ).whenComplete(_poke);
  }

  Future<void> _promptGoTo() async {
    final ctrl = TextEditingController();
    final n = book.pageCount;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '1 - $n'),
          onSubmitted: (_) => Navigator.pop(ctx, int.tryParse(ctrl.text)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (result != null && result >= 1 && result <= n) {
      _setSpread(_spreadOfPage(result - 1));
    }
  }

}
