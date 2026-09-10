import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'contents_sheet.dart';
import 'curl_painter.dart';
import 'hotspot_layer.dart';
import 'pdf_pipeline.dart';
import 'reader_controller.dart';
import 'reader_settings.dart';
import 'settings_sheet.dart';

/// The reader chrome around the curl view: stage, chevrons, thumbnail
/// strip, toolbar, thumbnail grid overlay, autoplay, zoom. Everything
/// auto-hides after 3 s and reappears on tap.
///
/// A view only. Expects a [PdfBook], [ReaderSettings] and [ReaderController]
/// above it, provided by the route that opens the reader.
class ReaderShell extends StatelessWidget {
  const ReaderShell({super.key});

  @override
  Widget build(BuildContext context) {
    final book = context.watch<PdfBook>();
    final settings = context.watch<ReaderSettings>();
    final c = context.watch<ReaderController>();

    final mq = MediaQuery.of(context);
    c.applyTwoUp(mq.orientation == Orientation.landscape && settings.doublePageInLandscape);

    if (!book.isOpen) {
      return const ColoredBox(color: Color(0xFF10131A));
    }

    return LayoutBuilder(
      builder: (context, cons) {
        // Book box: keep the PDF's own aspect ratio.
        final bookAspect = c.twoUp ? book.aspect * 2 : book.aspect;
        var bw = cons.maxWidth - 24;
        var bh = bw / bookAspect;
        // Generous vertical margin so a lifted page has somewhere to hang past
        // the book's edges, but never more than the screen can give: on a short
        // viewport a fixed 96 would drive the book to zero height or negative.
        final maxH = (cons.maxHeight - 96).clamp(120.0, cons.maxHeight);
        if (bh > maxH) {
          bh = maxH;
          bw = bh * bookAspect;
        }
        book.setRenderTarget(c.twoUp ? bw / 2 : bw, mq.devicePixelRatio);
        c.onLayout();

        TapDownDetails? doubleTapDown;

        return Stack(
          children: [
            // Stage + book
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: c.toggleChrome,
                onDoubleTapDown: (d) => doubleTapDown = d,
                onDoubleTap: () {
                  c.zoomTo(c.zoomed ? 1 : 2.2, doubleTapDown?.localPosition ?? Offset.zero);
                  c.poke();
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: settings.skin.isGradient ? null : settings.skin.colors.first,
                    gradient: settings.skin.isGradient ? settings.skin.gradient : null,
                  ),
                  alignment: Alignment.center,
                  child: InteractiveViewer(
                    transformationController: c.zoom,
                    panEnabled: c.zoomed,
                    scaleEnabled: true,
                    maxScale: 5,
                    child: SizedBox(
                      width: bw,
                      height: bh,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          boxShadow: [
                            BoxShadow(color: Colors.black87, blurRadius: 32, offset: Offset(0, 12)),
                          ],
                        ),
                        child: Stack(
                          children: [
                            IgnorePointer(
                              // While zoomed, drags pan; the leaf is not draggable.
                              ignoring: c.zoomed,
                              child: CurlBookView(
                                key: c.curlKey,
                                spreadCount: c.spreadCount,
                                index: c.spread,
                                twoUp: c.twoUp,
                                onIndexChanged: c.onTurned,
                                onInteraction: c.poke,
                                onTapCentre: c.toggleChrome,
                                resolve: c.resolve,
                                radiusFactor: settings.curlSoftness,
                                perspective: settings.perspective,
                                duration: settings.flipSpeed.duration,
                              ),
                            ),
                            if (settings.showHotspots && !c.zoomed) ..._hotspotLayers(c),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Chevrons
            if (settings.showChevrons) ...[_chevron(c, left: true), _chevron(c, left: false)],

            if (settings.showLogo) _logo(c, cons),

            // Bottom chrome: thumbnail strip + toolbar
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !c.chrome,
                child: AnimatedOpacity(
                  opacity: c.chrome ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (settings.showThumbStrip) _thumbStrip(c),
                      if (settings.showToolbar) _toolbar(context, c),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _chevron(ReaderController c, {required bool left}) {
    final enabled = left ? !c.atStart : !c.atEnd;
    return Positioned(
      left: left ? 4 : null,
      right: left ? null : 4,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: c.chrome && enabled ? 0.8 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !c.chrome || !enabled,
            child: IconButton(
              iconSize: 36,
              color: Colors.white,
              style: IconButton.styleFrom(backgroundColor: Colors.black38),
              icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
              onPressed: () {
                c.poke();
                left ? c.prev() : c.next();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbStrip(ReaderController c) {
    final book = c.book;
    final n = book.pageCount;
    return Container(
      height: 84,
      color: const Color(0xCC15181F),
      child: Row(
        children: [
          IconButton(
            tooltip: 'First page',
            color: Colors.white70,
            icon: const Icon(Icons.first_page),
            onPressed: c.atStart
                ? null
                : () {
                    c.setSpread(0);
                    c.poke();
                  },
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: n,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (context, i) {
                final img = book.thumb(i);
                final selected = c.twoUp
                    ? (i == c.leftPage(c.spread) || i == c.rightPage(c.spread))
                    : i == c.currentPage;
                return GestureDetector(
                  onTap: () {
                    c.goToPage(i);
                    c.poke();
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
            onPressed: c.atEnd
                ? null
                : () {
                    c.setSpread(c.spreadCount - 1);
                    c.poke();
                  },
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context, ReaderController c) {
    final settings = c.settings;
    final page = c.currentPage;
    return Container(
      color: settings.skin.toolbarColor.withValues(alpha: 0.9),
      padding: EdgeInsets.only(left: 4, right: 4, bottom: MediaQuery.paddingOf(context).bottom),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Library',
            color: Colors.white70,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          IconButton(
            tooltip: 'Zoom',
            color: Colors.white70,
            icon: Icon(c.zoomed ? Icons.zoom_out : Icons.zoom_in),
            onPressed: () {
              c.zoomTo(c.zoomed ? 1 : 2, Offset(MediaQuery.sizeOf(context).width / 4, 0));
              c.poke();
            },
          ),
          IconButton(
            tooltip: 'Contents and bookmarks',
            color: Colors.white70,
            icon: const Icon(Icons.grid_view),
            onPressed: () => _openContents(context, c),
          ),
          IconButton(
            tooltip: settings.isBookmarked(page) ? 'Remove bookmark' : 'Bookmark',
            color: Colors.white70,
            icon: Icon(settings.isBookmarked(page) ? Icons.bookmark : Icons.bookmark_border),
            onPressed: () {
              settings.toggleBookmark(page);
              c.poke();
            },
          ),
          if (settings.showPageNumber)
            Text(c.indicator, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: page.toDouble(),
                min: 0,
                max: (c.book.pageCount - 1).toDouble(),
                onChanged: (v) {
                  c.goToPage(v.round());
                  c.poke();
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
              c.poke();
            },
          ),
          IconButton(
            tooltip: c.autoplay ? 'Pause' : 'Autoplay',
            color: Colors.white70,
            icon: Icon(c.autoplay ? Icons.pause_circle : Icons.play_circle),
            onPressed: c.toggleAutoplay,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            iconColor: Colors.white70,
            onSelected: (v) {
              if (v == 'settings') _openSettings(context, c);
              if (v == 'goto') _promptGoTo(context, c);
              if (v == 'reset') c.zoomTo(1, Offset.zero);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Customize…')),
              PopupMenuItem(value: 'goto', child: Text('Go to page…')),
              PopupMenuItem(value: 'reset', child: Text('Reset zoom')),
            ],
          ),
        ],
      ),
    );
  }

  /// Hotspot layers for the visible page or pages.
  ///
  /// In a spread the two halves are separate pages with their own coordinate
  /// space, so each half gets its own layer. One layer stretched across the
  /// spread would put every hotspot at the wrong x.
  List<Widget> _hotspotLayers(ReaderController c) {
    if (c.hotspots.isEmpty) return const [];

    Widget? layerFor(int page) {
      final spots = c.hotspots.forPage(page);
      if (spots.isEmpty) return null;
      return HotspotLayer(hotspots: spots, reveal: c.hotspotReveal, onGoToPage: c.goToPage);
    }

    if (!c.twoUp) {
      final layer = layerFor(c.currentPage);
      return layer == null ? const [] : [Positioned.fill(child: layer)];
    }

    // Spread 0 is the cover alone on the right, matching the curl painter.
    final left = c.spread == 0 ? null : layerFor(c.leftPage(c.spread));
    final right = layerFor(c.rightPage(c.spread));
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

  /// Branding overlay, positioned as a fraction of the screen and draggable
  /// once unlocked.
  ///
  /// Locked it ignores pointers entirely, so it can never swallow a page turn
  /// that starts underneath it. Unlocked it takes drags, which is the whole
  /// point, and gains a dashed outline so the reader can see what is grabbable.
  Widget _logo(ReaderController c, BoxConstraints cons) {
    final settings = c.settings;
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
            opacity: unlocked ? 1 : (c.chrome ? settings.logoOpacity : settings.logoOpacity * 0.35),
            duration: const Duration(milliseconds: 200),
            child: Container(
              decoration: unlocked
                  ? BoxDecoration(
                      border: Border.all(color: const Color(0xCC4FA3FF), width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              padding: unlocked ? const EdgeInsets.all(3) : EdgeInsets.zero,
              child: _logoContent(settings),
            ),
          ),
        ),
      ),
    );
  }

  /// The logo itself: a picked image when there is one, otherwise the text.
  Widget _logoContent(ReaderSettings settings) {
    final path = settings.logoImagePath;
    final text = Text(
      settings.logoText,
      style: TextStyle(
        color: Colors.white,
        fontSize: settings.logoHeight * 0.45,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );

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
          ? text
          : Image.file(
              File(path),
              height: settings.logoHeight,
              fit: BoxFit.contain,
              // The picked file lives in the app cache and can be cleared, so
              // fall back to the text logo rather than showing a broken box.
              errorBuilder: (_, _, _) => text,
            ),
    );
  }

  /// A bottom sheet is its own route, above this reader's providers, so the
  /// sheet gets the same instances handed back down to it.
  Widget _withReader(ReaderController c, Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: c.book),
      ChangeNotifierProvider.value(value: c.settings),
    ],
    child: child,
  );

  void _openSettings(BuildContext context, ReaderController c) {
    c.holdChrome();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _withReader(c, const SettingsSheet()),
    ).whenComplete(c.poke);
  }

  void _openContents(BuildContext context, ReaderController c) {
    c.holdChrome();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _withReader(
        c,
        ContentsSheet(
          currentPage: c.currentPage,
          onJump: (page) {
            Navigator.of(sheetContext).pop();
            c.goToPage(page);
          },
        ),
      ),
    ).whenComplete(c.poke);
  }

  Future<void> _promptGoTo(BuildContext context, ReaderController c) async {
    final ctrl = TextEditingController();
    final n = c.book.pageCount;
    final result = await showDialog<int>(
      context: context,
      // In landscape the keyboard leaves roughly 100dp, so the dialog is one
      // field: the title is its label, submit is the arrow or the keyboard's Go
      // key, and cancel is back or a tap outside. A title and a button row
      // cannot fit in that height and push the field out of view.
      builder: (ctx) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          decoration: InputDecoration(
            labelText: 'Go to page',
            hintText: '1 - $n',
            suffixIcon: IconButton(
              tooltip: 'Go',
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, int.tryParse(ctrl.text)),
        ),
      ),
    );
    if (result != null && result >= 1 && result <= n) {
      c.goToPage(result - 1);
    }
  }
}
