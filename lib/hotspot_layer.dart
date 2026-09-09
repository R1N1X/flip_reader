import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'hotspots.dart' as model;

/// Tappable regions drawn over one page.
///
/// Sits above the page image but only while the page is at rest. Mid-turn the
/// paper is warped by the curl painter and a flat rectangle would no longer sit
/// over the content it belongs to, so the layer is simply not built then.
class HotspotLayer extends StatelessWidget {
  const HotspotLayer({
    super.key,
    required this.hotspots,
    required this.reveal,
    required this.onGoToPage,
  });

  final List<model.Hotspot> hotspots;

  /// 0..1 highlight strength. Interactive areas are invisible in a PDF, so the
  /// reader is shown where they are on arrival rather than being expected to
  /// hunt for them.
  final double reveal;

  final ValueChanged<int> onGoToPage;

  @override
  Widget build(BuildContext context) {
    if (hotspots.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, cons) => Stack(
        children: [
          for (final spot in hotspots)
            Positioned(
              left: spot.rect.left * cons.maxWidth,
              top: spot.rect.top * cons.maxHeight,
              width: spot.rect.width * cons.maxWidth,
              height: spot.rect.height * cons.maxHeight,
              child: _HotspotTarget(
                spot: spot,
                reveal: reveal,
                onGoToPage: onGoToPage,
              ),
            ),
        ],
      ),
    );
  }
}

class _HotspotTarget extends StatelessWidget {
  const _HotspotTarget({
    required this.spot,
    required this.reveal,
    required this.onGoToPage,
  });

  final model.Hotspot spot;
  final double reveal;
  final ValueChanged<int> onGoToPage;

  Future<void> _activate(BuildContext context) async {
    switch (spot.action) {
      case model.HotspotAction.openUrl:
        final raw = spot.url;
        if (raw == null) return;
        final uri = Uri.tryParse(raw);
        // A link that cannot be opened has to say so. Silently doing nothing
        // reads as a broken page.
        final opened = uri != null &&
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!opened && context.mounted) {
          _toast(context, 'Could not open $raw');
        }

      case model.HotspotAction.goToPage:
        final target = spot.targetPage;
        if (target != null) onGoToPage(target);

      case model.HotspotAction.popup:
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1A1E27),
            title: Text(spot.title ?? '', style: const TextStyle(color: Colors.white)),
            content: Text(
              spot.body ?? '',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );

      case model.HotspotAction.tooltip:
        _toast(context, spot.label ?? spot.title ?? '');

      case model.HotspotAction.video:
      case model.HotspotAction.audio:
        final source = spot.url;
        if (source == null) return;
        await showDialog<void>(
          context: context,
          builder: (_) => _MediaDialog(
            source: source,
            title: spot.title,
            audioOnly: spot.action == model.HotspotAction.audio,
          ),
        );
    }
  }

  void _toast(BuildContext context, String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  IconData get _icon => switch (spot.action) {
        model.HotspotAction.openUrl => Icons.open_in_new,
        model.HotspotAction.goToPage => Icons.turn_right,
        model.HotspotAction.popup => Icons.article_outlined,
        model.HotspotAction.tooltip => Icons.info_outline,
        model.HotspotAction.video => Icons.play_circle_outline,
        model.HotspotAction.audio => Icons.volume_up_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so the tap lands here rather than falling through to the page
      // turn behind it.
      behavior: HitTestBehavior.opaque,
      onTap: () => _activate(context),
      child: AnimatedOpacity(
        opacity: reveal,
        duration: const Duration(milliseconds: 250),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x2E4FA3FF),
            border: Border.all(color: const Color(0xCC4FA3FF), width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(_icon, size: 13, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Plays a video or audio file in an overlay.
///
/// video_player covers both: an audio-only file has no picture, so the surface
/// is replaced with a title and the controls carry the interaction.
class _MediaDialog extends StatefulWidget {
  const _MediaDialog({required this.source, required this.title, required this.audioOnly});

  final String source;
  final String? title;
  final bool audioOnly;

  @override
  State<_MediaDialog> createState() => _MediaDialogState();
}

class _MediaDialogState extends State<_MediaDialog> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final source = widget.source;
    final controller = source.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(source))
        : VideoPlayerController.asset(source);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (error) {
      await controller.dispose();
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Dialog(
      backgroundColor: const Color(0xFF11141B),
      insetPadding: const EdgeInsets.all(20),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  widget.title!,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            if (_error != null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'This media could not be played.',
                  style: TextStyle(color: Colors.white54),
                ),
              )
            else if (controller == null)
              // Blank while it opens rather than a spinner, matching the pages.
              const SizedBox(height: 120)
            else ...[
              if (!widget.audioOnly)
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Icon(Icons.graphic_eq, size: 48, color: Colors.white38),
                ),
              VideoProgressIndicator(controller, allowScrubbing: true),
              ValueListenableBuilder(
                valueListenable: controller,
                builder: (context, value, _) => IconButton(
                  color: Colors.white,
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () =>
                      value.isPlaying ? controller.pause() : controller.play(),
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
