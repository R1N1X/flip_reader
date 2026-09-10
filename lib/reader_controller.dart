import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'curl_painter.dart';
import 'hotspots.dart' as hs;
import 'pdf_pipeline.dart';
import 'reader_settings.dart';

/// State of one open reader: which spread is showing, whether the chrome is
/// up, autoplay, zoom, and the hotspot highlight.
///
/// Provided alongside the book and settings for the lifetime of the reader
/// route, and disposed with it. The shell is a plain view over this.
class ReaderController extends ChangeNotifier {
  ReaderController({required this.book, required this.settings, String? hotspotsAsset}) {
    book.addListener(_onBook);
    settings.addListener(_onFullscreenMaybeChanged);
    zoom.addListener(_onZoom);
    restartChromeTimer();
    if (hotspotsAsset != null) {
      hs.HotspotSet.load(hotspotsAsset).then((set) {
        if (_disposed) return;
        _hotspots = set;
        notifyListeners();
      });
    }
  }

  final PdfBook book;
  final ReaderSettings settings;

  /// Lets autoplay, the chevrons and the drag hint drive the curl view's own
  /// animation rather than jumping the index.
  final curlKey = GlobalKey<CurlBookViewState>();
  final zoom = TransformationController();

  bool _disposed = false;

  hs.HotspotSet _hotspots = hs.HotspotSet.empty();
  hs.HotspotSet get hotspots => _hotspots;

  /// Interactive areas glow briefly when a page settles, then fade. They are
  /// invisible in the PDF itself, so the reader has to be told they exist
  /// without the highlight sitting there permanently over the artwork.
  double _hotspotReveal = 0;
  double get hotspotReveal => _hotspotReveal;
  Timer? _hotspotTimer;

  /// The drag hint plays once per document, after the cover has actually
  /// rendered. Nudging a blank sheet teaches nothing.
  bool _hintShown = false;
  Timer? _hintTimer;

  int _spread = 0;
  int get spread => _spread;

  bool _twoUp = false;
  bool get twoUp => _twoUp;

  bool _chrome = true;
  bool get chrome => _chrome;

  bool _autoplay = false;
  bool get autoplay => _autoplay;

  Timer? _chromeTimer;
  Timer? _autoplayTimer;

  int _lastPageCount = 0;
  bool _windowInit = false;
  bool _fullscreenApplied = false;
  bool _zoomedLast = false;

  @override
  void dispose() {
    _disposed = true;
    book.removeListener(_onBook);
    settings.removeListener(_onFullscreenMaybeChanged);
    zoom.removeListener(_onZoom);
    _hotspotTimer?.cancel();
    _hintTimer?.cancel();
    _chromeTimer?.cancel();
    _autoplayTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    zoom.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// A new document can be shorter than the one it replaced, which would leave
  /// the index past the end. Reset to the cover and re-window whenever the
  /// document changes. The shell watches the book itself, so no notify here.
  void _onBook() {
    if (book.pageCount == _lastPageCount) return;
    _lastPageCount = book.pageCount;
    _spread = 0;
    _hintShown = false;
    _hotspots = hs.HotspotSet.empty();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
  }

  /// Fullscreen hides the status and navigation bars entirely. Applied only on
  /// change, since setting the UI mode every rebuild makes the bars flicker.
  void _onFullscreenMaybeChanged() {
    if (settings.fullscreen == _fullscreenApplied) return;
    _fullscreenApplied = settings.fullscreen;
    SystemChrome.setEnabledSystemUIMode(
      settings.fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// Pinch zoom moves the matrix on every frame; the shell only cares when it
  /// crosses in or out of zoomed, which flips panning and the hotspot layer.
  void _onZoom() {
    if (zoomed == _zoomedLast) return;
    _zoomedLast = zoomed;
    _notify();
  }

  // ---- layout, called from the shell's build ---------------------------

  /// Orientation decides one page or two. Called during build, so it adjusts
  /// state in place without notifying: the build in progress already uses it.
  void applyTwoUp(bool twoUp) {
    if (twoUp == _twoUp) return;
    final page = leftPage(_spread);
    _twoUp = twoUp;
    _spread = spreadOfPage(page);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
  }

  /// First layout: window the pages around the cover and play the drag hint.
  void onLayout() {
    if (!_windowInit) {
      _windowInit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateWindow());
    }
    _maybeHint();
  }

  void _maybeHint() {
    if (_hintShown || book.image(0) == null) return;
    _hintShown = true;
    _hintTimer = Timer(const Duration(milliseconds: 550), () {
      if (!_disposed) curlKey.currentState?.hint();
    });
  }

  // ---- spread math ------------------------------------------------------

  int get spreadCount {
    final n = book.pageCount;
    if (n == 0) return 1;
    return _twoUp ? 1 + ((n - 1) / 2).ceil() : n;
  }

  int leftPage(int spread) => _twoUp ? (spread == 0 ? 0 : spread * 2 - 1) : spread;
  int rightPage(int spread) => _twoUp ? (spread == 0 ? 0 : spread * 2) : spread;
  int spreadOfPage(int p) => _twoUp ? (p == 0 ? 0 : (p + 1) ~/ 2) : p;

  int get currentPage => leftPage(_spread);
  bool get atStart => _spread <= 0;
  bool get atEnd => _spread >= spreadCount - 1;

  void setSpread(int s) {
    _revealHotspots();
    _spread = s.clamp(0, spreadCount - 1);
    _notify();
    _updateWindow();
  }

  void goToPage(int page) => setSpread(spreadOfPage(page));

  /// The curl view reports a finished turn. Autoplay stops on the last spread.
  void onTurned(int i) {
    setSpread(i);
    if (_autoplay && i >= spreadCount - 1) toggleAutoplay();
  }

  void _updateWindow() {
    if (_disposed) return;
    final l = leftPage(_spread), r = rightPage(_spread);
    book.setWindow([for (var p = l - 4; p <= r + 4; p++) p]);
  }

  /// Which page image goes in each slot of the curl view for a given spread.
  ui.Image? resolve(int spread, CurlSlot slot) {
    final n = book.pageCount;
    int? page;
    if (_twoUp) {
      if (slot == CurlSlot.leftStatic) {
        page = spread == 0 ? null : leftPage(spread);
      } else if (slot == CurlSlot.front) {
        page = rightPage(spread);
      } else if (slot == CurlSlot.under) {
        final next = spread + 1;
        page = next < spreadCount ? rightPage(next) : null;
      } else {
        final next = spread + 1;
        page = next < spreadCount ? leftPage(next) : null;
      }
    } else {
      if (slot == CurlSlot.leftStatic) return null;
      if (slot == CurlSlot.front) page = spread;
      if (slot == CurlSlot.under || slot == CurlSlot.back) page = spread + 1;
    }
    if (page == null || page < 0 || page >= n) return null;
    return book.image(page);
  }

  String get indicator {
    final n = book.pageCount;
    if (!_twoUp || _spread == 0) return '${leftPage(_spread) + 1}/$n';
    final l = leftPage(_spread) + 1;
    final r = (rightPage(_spread) + 1).clamp(1, n);
    return l == r ? '$l/$n' : '$l-$r/$n';
  }

  // ---- hotspots -----------------------------------------------------------

  /// Pulse the hotspot highlights, then let them fade back out.
  void _revealHotspots() {
    _hotspotTimer?.cancel();
    if (!settings.showHotspots) return;
    _hotspotReveal = 1;
    _notify();
    _hotspotTimer = Timer(const Duration(milliseconds: 1600), () {
      _hotspotReveal = 0.18;
      _notify();
    });
  }

  // ---- chrome / autoplay --------------------------------------------------

  void restartChromeTimer() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(const Duration(seconds: 3), () {
      _chrome = false;
      _notify();
    });
  }

  /// Keeps the chrome up while a sheet or dialog is open over the reader.
  void holdChrome() => _chromeTimer?.cancel();

  /// Any interaction brings the chrome back and restarts its hide timer.
  void poke() {
    if (!_chrome) {
      _chrome = true;
      _notify();
    }
    restartChromeTimer();
  }

  void toggleChrome() {
    _chrome = !_chrome;
    _notify();
    if (_chrome) restartChromeTimer();
  }

  void toggleAutoplay() {
    _autoplay = !_autoplay;
    _notify();
    _autoplayTimer?.cancel();
    if (_autoplay) {
      _autoplayTimer = Timer.periodic(Duration(seconds: settings.autoplaySeconds), (_) {
        if (atEnd) {
          toggleAutoplay();
        } else {
          curlKey.currentState?.next();
        }
      });
    }
    poke();
  }

  void next() => curlKey.currentState?.next();
  void prev() => curlKey.currentState?.prev();

  // ---- zoom -----------------------------------------------------------------

  bool get zoomed => zoom.value.getMaxScaleOnAxis() > 1.01;

  void zoomTo(double scale, Offset focal) {
    if (scale <= 1) {
      zoom.value = Matrix4.identity();
    } else {
      zoom.value = Matrix4.identity()
        ..translateByDouble(-focal.dx * (scale - 1), -focal.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, scale, 1);
    }
  }
}
