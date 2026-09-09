import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';

/// Opens assets/book.pdf, renders pages on demand at device pixel ratio,
/// keeps a sliding window of full-res pages, evicts and disposes the rest.
/// Thumbnails are rendered small and kept for the whole session.
class PdfBook extends ChangeNotifier {
  PdfDocument? _doc;
  int pageCount = 0;

  /// width / height of page 1, taken from the PDF itself.
  double aspect = 0.7;

  final Map<int, ui.Image> _cache = {}; // 0-based page -> full-res image
  final Map<int, ui.Image> _thumbs = {};
  final Set<int> _renderingFull = {};
  final Set<int> _renderingThumb = {};

  Set<int> _window = {};
  double _targetLogicalWidth = 400;
  double _dpr = 2;

  bool get isOpen => _doc != null;

  /// Name of whatever is open, for the UI to show.
  String title = '';

  Future<void> open(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    await _adopt(
      await PdfDocument.openData(data.buffer.asUint8List()),
      assetPath.split('/').last,
    );
  }

  /// Opens a PDF the user picked from their device.
  ///
  /// Throws if the file is not a readable PDF, so the caller can say so rather
  /// than leaving the reader on a document that never arrives.
  Future<void> openFile(String path) async {
    await _adopt(await PdfDocument.openFile(path), path.split(RegExp(r'[\/]')).last);
  }

  /// Swaps in a new document and throws away everything rendered from the old
  /// one. Without this the caches would keep serving the previous book's pages
  /// under the new book's indices.
  Future<void> _adopt(PdfDocument doc, String name) async {
    final previous = _doc;
    _doc = doc;
    title = name;
    pageCount = doc.pagesCount;

    for (final image in _cache.values) {
      image.dispose();
    }
    for (final image in _thumbs.values) {
      image.dispose();
    }
    _cache.clear();
    _thumbs.clear();
    _renderingFull.clear();
    _renderingThumb.clear();
    _window = {};

    final p1 = await doc.getPage(1);
    aspect = p1.width / p1.height;
    await p1.close();

    await previous?.close();
    notifyListeners();
  }

  /// Logical on-screen page width and the device pixel ratio.
  /// Full-res pages render at targetLogicalWidth * dpr physical pixels,
  /// so they are crisp, not soft.
  void setRenderTarget(double logicalPageWidth, double dpr) {
    // Re-render only if the needed width grew noticeably (e.g. rotation).
    if (logicalPageWidth * dpr > _targetLogicalWidth * _dpr * 1.2) {
      _targetLogicalWidth = logicalPageWidth;
      _dpr = dpr;
      final pages = _cache.keys.toList();
      for (final p in pages) {
        _cache.remove(p)?.dispose();
      }
      _requestWindow();
    } else {
      _targetLogicalWidth = logicalPageWidth;
      _dpr = dpr;
    }
  }

  /// Pages that must stay resident. Everything else full-res is disposed.
  void setWindow(Iterable<int> pages) {
    _window = pages.where((p) => p >= 0 && p < pageCount).toSet();
    final evict = _cache.keys.where((p) => !_window.contains(p)).toList();
    for (final p in evict) {
      _cache.remove(p)?.dispose();
    }
    _requestWindow();
  }

  void _requestWindow() {
    for (final p in _window) {
      _renderFull(p);
    }
  }

  ui.Image? image(int page) => _cache[page];
  ui.Image? thumb(int page) {
    if (!_thumbs.containsKey(page)) _renderThumb(page);
    return _thumbs[page];
  }

  Future<void> _renderFull(int page) async {
    final doc = _doc;
    if (doc == null ||
        _cache.containsKey(page) ||
        _renderingFull.contains(page)) {
      return;
    }
    _renderingFull.add(page);
    try {
      final img = await _render(page, _targetLogicalWidth * _dpr);
      // The window may have moved while we rendered.
      if (_window.contains(page)) {
        _cache[page] = img;
        notifyListeners();
      } else {
        img.dispose();
      }
    } finally {
      _renderingFull.remove(page);
    }
  }

  Future<void> _renderThumb(int page) async {
    if (_doc == null ||
        _thumbs.containsKey(page) ||
        _renderingThumb.contains(page)) {
      return;
    }
    _renderingThumb.add(page);
    try {
      _thumbs[page] = await _render(page, 140);
      notifyListeners();
    } finally {
      _renderingThumb.remove(page);
    }
  }

  Future<ui.Image> _render(int page, double pixelWidth) async {
    final p = await _doc!.getPage(page + 1);
    try {
      final img = await p.render(
        width: pixelWidth,
        height: pixelWidth * p.height / p.width,
        format: PdfPageImageFormat.png,
        // White background: transparent PDFs must not composite onto the
        // dark stage.
        backgroundColor: '#FFFFFF',
      );
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(img!.bytes, completer.complete);
      return completer.future;
    } finally {
      await p.close();
    }
  }

  @override
  void dispose() {
    for (final i in _cache.values) {
      i.dispose();
    }
    for (final i in _thumbs.values) {
      i.dispose();
    }
    _doc?.close();
    super.dispose();
  }
}

/// Renders page 1 of a PDF as a standalone image, without opening a [PdfBook].
///
/// The chooser needs a cover before anything is open, and spinning up the whole
/// render window and its caches for one thumbnail would be wasteful. Returns
/// null rather than throwing: a cover that cannot be drawn is a missing picture,
/// not a failure worth interrupting the screen for.
Future<ui.Image?> renderPdfCover({
  String? assetPath,
  String? filePath,
  double pixelWidth = 320,
}) async {
  PdfDocument? doc;
  try {
    if (assetPath != null) {
      final data = await rootBundle.load(assetPath);
      doc = await PdfDocument.openData(data.buffer.asUint8List());
    } else if (filePath != null) {
      doc = await PdfDocument.openFile(filePath);
    } else {
      return null;
    }

    final page = await doc.getPage(1);
    try {
      final rendered = await page.render(
        width: pixelWidth,
        height: pixelWidth * page.height / page.width,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (rendered == null) return null;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(rendered.bytes, completer.complete);
      return await completer.future;
    } finally {
      await page.close();
    }
  } catch (_) {
    return null;
  } finally {
    await doc?.close();
  }
}
