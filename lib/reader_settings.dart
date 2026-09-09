import 'package:flutter/material.dart';

/// A named backdrop for the reading stage.
///
/// Skins are data, not code: adding one is a single entry in [kSkins] and it
/// appears in the picker, in the stage and in the swatch row with no other edit.
@immutable
class ReaderSkin {
  const ReaderSkin(this.name, this.colors, {this.toolbar});

  final String name;

  /// One colour is a flat backdrop, two or more is a gradient.
  final List<Color> colors;

  /// Toolbar tint, defaulting to a darkened first colour when unset.
  final Color? toolbar;

  bool get isGradient => colors.length > 1;

  Gradient get gradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      );

  Color get toolbarColor => toolbar ?? Color.alphaBlend(Colors.black54, colors.first);

  /// Readable text on this backdrop. Computed rather than stored, so a new skin
  /// cannot ship with an unreadable label by accident.
  Color get onSkin =>
      ThemeData.estimateBrightnessForColor(colors.first) == Brightness.dark ? Colors.white : Colors.black87;
}

const List<ReaderSkin> kSkins = [
  ReaderSkin('Midnight', [Color(0xFF10131A)]),
  ReaderSkin('Charcoal', [Color(0xFF1C1B1F)]),
  ReaderSkin('Slate', [Color(0xFF2B3440)]),
  ReaderSkin('Plum', [Color(0xFF4A1942)]),
  ReaderSkin('Wine', [Color(0xFF5B1D2B)]),
  ReaderSkin('Forest', [Color(0xFF1B3A2F)]),
  ReaderSkin('Teal', [Color(0xFF113B3B)]),
  ReaderSkin('Sand', [Color(0xFFE8DCC8)]),
  ReaderSkin('Paper', [Color(0xFFF4F1EA)]),
  ReaderSkin('Linen', [Color(0xFFEDE4D3)]),
  ReaderSkin('Dusk', [Color(0xFF2B1B4A), Color(0xFF0F1030)]),
  ReaderSkin('Ocean', [Color(0xFF0B3C6B), Color(0xFF071B33)]),
  ReaderSkin('Ember', [Color(0xFF6B2410), Color(0xFF2A0A05)]),
  ReaderSkin('Aurora', [Color(0xFF123B5E), Color(0xFF1F7A6B)]),
  ReaderSkin('Violet', [Color(0xFF3B2A6B), Color(0xFF6B4BA8)]),
  ReaderSkin('Rose', [Color(0xFF7A2B4A), Color(0xFF2A0E1C)]),
  ReaderSkin('Mint', [Color(0xFFDDF0E6), Color(0xFFB9DCCB)]),
  ReaderSkin('Graphite', [Color(0xFF2F3136), Color(0xFF16171A)]),
];

/// How fast a released page finishes its turn.
enum FlipSpeed {
  slow('Slow', 700),
  normal('Normal', 450),
  fast('Fast', 260);

  const FlipSpeed(this.label, this.millis);
  final String label;
  final int millis;

  Duration get duration => Duration(milliseconds: millis);
}

/// Everything the reader lets a user change, in one place.
///
/// A ChangeNotifier rather than a rebuilt widget tree: a skin change repaints
/// the stage without disturbing the book, which matters mid-turn.
class ReaderSettings extends ChangeNotifier {
  int _skinIndex = 0;
  FlipSpeed _flipSpeed = FlipSpeed.normal;

  bool _showToolbar = true;
  bool _showThumbStrip = true;
  bool _showChevrons = true;
  bool _showPageNumber = true;
  bool _showLogo = false;
  bool _fullscreen = false;
  bool _showHotspots = true;
  bool _doublePageInLandscape = true;

  /// Page curl radius as a fraction of page width. Larger reads as thicker,
  /// softer paper; smaller as a tighter, crisper roll.
  double _curlSoftness = 0.14;

  /// How much the lifted page grows and leans as it rises off the book.
  double _perspective = 1.0;

  int _autoplaySeconds = 3;
  String _logoText = 'BUZZERFAN';

  /// Absolute path to a picked logo image, or null for the text logo. Held as a
  /// path rather than bytes so a large image is not kept in memory twice, and
  /// decoded once by the image cache.
  String? _logoImagePath;

  /// Logo height in logical pixels. Width follows the image's aspect.
  double _logoHeight = 28;

  double _logoOpacity = 1.0;

  /// Logo position as a fraction of the screen, so it stays where it was put
  /// across rotation and across devices. A pixel offset would drift.
  double _logoX = 0.04;
  double _logoY = 0.04;

  /// While unlocked the logo can be dragged. Locked by default so a stray drag
  /// during reading cannot move it.
  bool _logoUnlocked = false;

  /// 0-based pages the reader has bookmarked, kept sorted for the TOC.
  final List<int> _bookmarks = [];

  ReaderSkin get skin => kSkins[_skinIndex];
  int get skinIndex => _skinIndex;
  FlipSpeed get flipSpeed => _flipSpeed;
  bool get showToolbar => _showToolbar;
  bool get showThumbStrip => _showThumbStrip;
  bool get showChevrons => _showChevrons;
  bool get showPageNumber => _showPageNumber;
  bool get showLogo => _showLogo;
  bool get fullscreen => _fullscreen;
  bool get showHotspots => _showHotspots;
  bool get doublePageInLandscape => _doublePageInLandscape;
  double get curlSoftness => _curlSoftness;
  double get perspective => _perspective;
  int get autoplaySeconds => _autoplaySeconds;
  String get logoText => _logoText;
  String? get logoImagePath => _logoImagePath;
  bool get hasLogoImage => _logoImagePath != null;
  double get logoHeight => _logoHeight;
  double get logoOpacity => _logoOpacity;
  double get logoX => _logoX;
  double get logoY => _logoY;
  bool get logoUnlocked => _logoUnlocked;
  List<int> get bookmarks => List.unmodifiable(_bookmarks);

  void setSkin(int index) => _set(() => _skinIndex = index.clamp(0, kSkins.length - 1));
  void setFlipSpeed(FlipSpeed value) => _set(() => _flipSpeed = value);
  void setShowToolbar(bool v) => _set(() => _showToolbar = v);
  void setShowThumbStrip(bool v) => _set(() => _showThumbStrip = v);
  void setShowChevrons(bool v) => _set(() => _showChevrons = v);
  void setShowPageNumber(bool v) => _set(() => _showPageNumber = v);
  void setShowLogo(bool v) => _set(() => _showLogo = v);
  void setFullscreen(bool v) => _set(() => _fullscreen = v);
  void setShowHotspots(bool v) => _set(() => _showHotspots = v);
  void setDoublePageInLandscape(bool v) => _set(() => _doublePageInLandscape = v);
  void setCurlSoftness(double v) => _set(() => _curlSoftness = v.clamp(0.05, 0.30));
  void setPerspective(double v) => _set(() => _perspective = v.clamp(0.0, 2.0));
  void setAutoplaySeconds(int v) => _set(() => _autoplaySeconds = v.clamp(1, 15));
  void setLogoText(String v) => _set(() => _logoText = v);
  void setLogoImagePath(String? v) => _set(() => _logoImagePath = v);
  void setLogoHeight(double v) => _set(() => _logoHeight = v.clamp(16, 96));
  void setLogoOpacity(double v) => _set(() => _logoOpacity = v.clamp(0.1, 1.0));
  void setLogoUnlocked(bool v) => _set(() => _logoUnlocked = v);

  /// Clamped so the logo can never be dragged fully off screen and lost.
  void setLogoPosition(double x, double y) => _set(() {
        _logoX = x.clamp(0.0, 0.92);
        _logoY = y.clamp(0.0, 0.92);
      });

  void resetLogoPosition() => setLogoPosition(0.04, 0.04);

  bool isBookmarked(int page) => _bookmarks.contains(page);

  void toggleBookmark(int page) => _set(() {
        if (!_bookmarks.remove(page)) {
          _bookmarks
            ..add(page)
            ..sort();
        }
      });

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }
}
