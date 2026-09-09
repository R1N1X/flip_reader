import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'pdf_pipeline.dart';
import 'reader_shell.dart';

/// Landing screen: read the bundled sample, or open your own PDF.
///
/// The reader is opened on a document rather than started empty, so the choice
/// has to happen before it, not inside it.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  String? _error;

  ui.Image? _sampleCover;

  /// Cover and name of the last PDF opened this session, so the second card
  /// shows what it will reopen rather than an empty tile.
  ui.Image? _recentCover;
  String? _recentPath;
  String? _recentName;

  @override
  void initState() {
    super.initState();
    renderPdfCover(assetPath: 'assets/book.pdf').then((cover) {
      if (mounted) {
        setState(() => _sampleCover = cover);
      } else {
        cover?.dispose();
      }
    });
  }

  @override
  void dispose() {
    _sampleCover?.dispose();
    _recentCover?.dispose();
    super.dispose();
  }

  Future<void> _openSample() =>
      _open((book) => book.open('assets/book.pdf'), hotspots: 'assets/hotspots.json');

  Future<void> _openOwn() => _open((book) async {
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
  Future<void> _openRecent() {
    final path = _recentPath!;
    return _open((book) => book.openFile(path));
  }

  void _rememberRecent(String path, String name) {
    _recentPath = path;
    _recentName = name;
    renderPdfCover(filePath: path).then((cover) {
      if (!mounted) {
        cover?.dispose();
        return;
      }
      setState(() {
        _recentCover?.dispose();
        _recentCover = cover;
      });
    });
  }

  /// Opens a document and pushes the reader onto it.
  ///
  /// The book is created here and disposed when the reader is popped, so
  /// returning to this screen genuinely releases the previous document's pages
  /// rather than leaving them cached for a book nobody is reading.
  Future<void> _open(
    Future<void> Function(PdfBook) opener, {
    String? hotspots,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final book = PdfBook();
    try {
      await opener(book);
      if (!mounted) {
        book.dispose();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: const Color(0xFF10131A),
            body: ReaderShell(book: book, hotspotsAsset: hotspots),
          ),
        ),
      );
    } on _Cancelled {
      // Nothing chosen, stay here quietly.
    } catch (_) {
      if (mounted) setState(() => _error = 'That file could not be opened as a PDF.');
    } finally {
      book.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1B2340), Color(0xFF0B0E18)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Flipbook Reader',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Read any PDF as a book, with a real page curl.',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const SizedBox(height: 28),
                    _Choice(
                      icon: Icons.auto_stories_outlined,
                      title: 'Open the sample',
                      subtitle: 'The bundled brochure, with interactive elements already placed.',
                      accent: const Color(0xFF4FA3FF),
                      enabled: !_busy,
                      cover: _sampleCover,
                      onTap: _openSample,
                    ),
                    const SizedBox(height: 14),
                    _Choice(
                      icon: Icons.upload_file_outlined,
                      title: 'Open your own PDF',
                      subtitle: 'Pick any PDF from this device. Everything is customizable.',
                      accent: const Color(0xFF3DD6A0),
                      enabled: !_busy,
                      onTap: _openOwn,
                    ),
                    if (_recentPath != null) ...[
                      const SizedBox(height: 22),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 10, left: 2),
                          child: Text(
                            'RECENT',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      _Choice(
                        icon: Icons.history,
                        title: _recentName ?? 'Last document',
                        subtitle: 'Open again',
                        accent: const Color(0xFFF2A65A),
                        enabled: !_busy,
                        cover: _recentCover,
                        onTap: _openRecent,
                      ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 13),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Signals a cancelled picker, which is not an error worth showing.
class _Cancelled implements Exception {
  const _Cancelled();
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.enabled,
    required this.onTap,
    this.cover,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  /// The document's first page. Null until it renders, or when there is no
  /// document behind the card yet.
  final ui.Image? cover;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                _CoverTile(icon: icon, accent: accent, cover: cover),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.35),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's leading tile: the document's cover once it has rendered,
/// otherwise the card's icon.
///
/// Sized to a page rather than a square, so a real cover is not letterboxed
/// into something that stops reading as a book.
class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.icon, required this.accent, required this.cover});

  final IconData icon;
  final Color accent;
  final ui.Image? cover;

  @override
  Widget build(BuildContext context) {
    final image = cover;

    return Container(
      width: 48,
      height: 64,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: image == null ? accent.withValues(alpha: 0.18) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: image == null
            ? null
            : const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: image == null
          ? Icon(icon, color: accent, size: 24)
          : RawImage(image: image, fit: BoxFit.cover),
    );
  }
}
