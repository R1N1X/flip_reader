import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'pdf_pipeline.dart';

const kSampleAsset = 'assets/book.pdf';
const kSampleHotspots = 'assets/hotspots.json';

/// Shows the reader on an opened book and completes when the reader closes.
typedef ShowReader = Future<void> Function(PdfBook book, String? hotspotsAsset);

/// State behind the landing screen: the sample and recent covers, whether a
/// document is being opened, and the last open error.
class Library extends ChangeNotifier {
  Library() {
    renderPdfCover(assetPath: kSampleAsset).then((cover) {
      if (_disposed) {
        cover?.dispose();
        return;
      }
      _sampleCover = cover;
      notifyListeners();
    });
  }

  bool _disposed = false;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  ui.Image? _sampleCover;
  ui.Image? get sampleCover => _sampleCover;

  /// Cover and name of the last PDF opened this session, so the recent card
  /// shows what it will reopen rather than an empty tile.
  ui.Image? _recentCover;
  ui.Image? get recentCover => _recentCover;
  String? _recentPath;
  String? get recentPath => _recentPath;
  String? _recentName;
  String? get recentName => _recentName;

  @override
  void dispose() {
    _disposed = true;
    _sampleCover?.dispose();
    _recentCover?.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> openSample(ShowReader show) =>
      _open(show, (book) => book.open(kSampleAsset), hotspots: kSampleHotspots);

  Future<void> openOwn(ShowReader show) => _open(show, (book) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    // A cancelled picker is not a failure, it just means nothing to open.
    final path = picked?.path;
    if (path == null) throw const _Cancelled();
    await book.openFile(path);
    _rememberRecent(path, picked!.name);
  });

  /// Reopens the last picked PDF without going through the file browser again.
  Future<void> openRecent(ShowReader show) {
    final path = _recentPath!;
    return _open(show, (book) => book.openFile(path));
  }

  void _rememberRecent(String path, String name) {
    _recentPath = path;
    _recentName = name;
    _notify();
    renderPdfCover(filePath: path).then((cover) {
      if (_disposed) {
        cover?.dispose();
        return;
      }
      _recentCover?.dispose();
      _recentCover = cover;
      notifyListeners();
    });
  }

  /// Opens a document and hands it to [show].
  ///
  /// The book is created here and disposed when the reader closes, so returning
  /// to the landing screen genuinely releases the previous document's pages
  /// rather than leaving them cached for a book nobody is reading. Stays busy
  /// for the whole time, so a second tap cannot open a second reader.
  Future<void> _open(
    ShowReader show,
    Future<void> Function(PdfBook) opener, {
    String? hotspots,
  }) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notify();

    final book = PdfBook();
    try {
      await opener(book);
      if (!_disposed) await show(book, hotspots);
    } on _Cancelled {
      // Nothing chosen, stay here quietly.
    } catch (_) {
      _error = 'That file could not be opened as a PDF.';
    } finally {
      book.dispose();
      _busy = false;
      _notify();
    }
  }
}

/// Signals a cancelled picker, which is not an error worth showing.
class _Cancelled implements Exception {
  const _Cancelled();
}
