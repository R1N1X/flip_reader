import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'library.dart';
import 'pdf_pipeline.dart';
import 'reader_controller.dart';
import 'reader_settings.dart';
import 'reader_shell.dart';

/// Landing screen: read the bundled sample, or open your own PDF.
///
/// The reader is opened on a document rather than started empty, so the choice
/// has to happen before it, not inside it. State lives in [Library].
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Pushes the reader with its book, settings and controller provided for the
  /// lifetime of the route. Settings are per reader, since bookmarks belong to
  /// one document. The book is owned by [Library], so it is passed by value
  /// and not disposed here.
  static ShowReader _reader(BuildContext context) => (book, hotspots) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MultiProvider(
          providers: [
            ChangeNotifierProvider<PdfBook>.value(value: book),
            ChangeNotifierProvider(create: (_) => ReaderSettings()),
            ChangeNotifierProvider(
              create: (ctx) => ReaderController(
                book: book,
                settings: ctx.read<ReaderSettings>(),
                hotspotsAsset: hotspots,
              ),
            ),
          ],
          child: const Scaffold(backgroundColor: Color(0xFF10131A), body: ReaderShell()),
        ),
      ),
    );
  };

  @override
  Widget build(BuildContext context) {
    final library = context.watch<Library>();
    final show = _reader(context);
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
                      enabled: !library.busy,
                      cover: library.sampleCover,
                      onTap: () => library.openSample(show),
                    ),
                    const SizedBox(height: 14),
                    _Choice(
                      icon: Icons.upload_file_outlined,
                      title: 'Open your own PDF',
                      subtitle: 'Pick any PDF from this device. Everything is customizable.',
                      accent: const Color(0xFF3DD6A0),
                      enabled: !library.busy,
                      onTap: () => library.openOwn(show),
                    ),
                    if (library.recentPath != null) ...[
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
                        title: library.recentName ?? 'Last document',
                        subtitle: 'Open again',
                        accent: const Color(0xFFF2A65A),
                        enabled: !library.busy,
                        cover: library.recentCover,
                        onTap: () => library.openRecent(show),
                      ),
                    ],
                    if (library.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 18),
                        child: Text(
                          library.error!,
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
