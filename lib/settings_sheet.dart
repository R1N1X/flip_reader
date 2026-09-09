import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'pdf_pipeline.dart';
import 'reader_settings.dart';

/// The customization panel: skin, display toggles, flip behaviour, logo.
///
/// Opened as a bottom sheet so the book stays visible behind it and a skin
/// change can be judged against the actual page rather than a preview tile.
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key, required this.settings, required this.book});

  final ReaderSettings settings;
  final PdfBook book;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, controller) => ColoredBox(
          color: const Color(0xFF15181F),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const _Heading('Document'),
              _DocumentPicker(book: book),
              const SizedBox(height: 8),
              const _Heading('Skin'),
              _SkinRow(settings: settings),
              const SizedBox(height: 8),
              const _Heading('Display'),
              _Toggle(
                label: 'Toolbar',
                value: settings.showToolbar,
                onChanged: settings.setShowToolbar,
              ),
              _Toggle(
                label: 'Thumbnail strip',
                value: settings.showThumbStrip,
                onChanged: settings.setShowThumbStrip,
              ),
              _Toggle(
                label: 'Page arrows',
                value: settings.showChevrons,
                onChanged: settings.setShowChevrons,
              ),
              _Toggle(
                label: 'Page number',
                value: settings.showPageNumber,
                onChanged: settings.setShowPageNumber,
              ),
              _Toggle(
                label: 'Fullscreen',
                value: settings.fullscreen,
                onChanged: settings.setFullscreen,
              ),
              _Toggle(
                label: 'Highlight interactive areas',
                value: settings.showHotspots,
                onChanged: settings.setShowHotspots,
              ),
              _Toggle(
                label: 'Two pages in landscape',
                value: settings.doublePageInLandscape,
                onChanged: settings.setDoublePageInLandscape,
              ),
              const SizedBox(height: 8),
              const _Heading('Flipping'),
              _SegmentRow<FlipSpeed>(
                values: FlipSpeed.values,
                selected: settings.flipSpeed,
                labelOf: (v) => v.label,
                onChanged: settings.setFlipSpeed,
              ),
              _SliderRow(
                label: 'Paper softness',
                value: settings.curlSoftness,
                min: 0.05,
                max: 0.30,
                display: settings.curlSoftness.toStringAsFixed(2),
                onChanged: settings.setCurlSoftness,
              ),
              _SliderRow(
                label: 'Depth',
                value: settings.perspective,
                min: 0.0,
                max: 2.0,
                display: settings.perspective.toStringAsFixed(1),
                onChanged: settings.setPerspective,
              ),
              _SliderRow(
                label: 'Autoplay interval',
                value: settings.autoplaySeconds.toDouble(),
                min: 1,
                max: 15,
                divisions: 14,
                display: '${settings.autoplaySeconds}s',
                onChanged: (v) => settings.setAutoplaySeconds(v.round()),
              ),
              const SizedBox(height: 8),
              const _Heading('Logo'),
              _Toggle(
                label: 'Show logo',
                value: settings.showLogo,
                onChanged: settings.setShowLogo,
              ),
              if (settings.showLogo) ...[
                _LogoPicker(settings: settings),
                if (!settings.hasLogoImage)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextFormField(
                      initialValue: settings.logoText,
                      onChanged: settings.setLogoText,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Logo text',
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                _SliderRow(
                  label: 'Logo size',
                  value: settings.logoHeight,
                  min: 16,
                  max: 96,
                  display: settings.logoHeight.round().toString(),
                  onChanged: settings.setLogoHeight,
                ),
                _SliderRow(
                  label: 'Logo opacity',
                  value: settings.logoOpacity,
                  min: 0.1,
                  max: 1.0,
                  display: '${(settings.logoOpacity * 100).round()}%',
                  onChanged: settings.setLogoOpacity,
                ),
                _Toggle(
                  label: 'Move logo (drag it on the page)',
                  value: settings.logoUnlocked,
                  onChanged: settings.setLogoUnlocked,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: settings.resetLogoPosition,
                    child: const Text('Reset logo position'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _SkinRow extends StatelessWidget {
  const _SkinRow({required this.settings});
  final ReaderSettings settings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kSkins.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final skin = kSkins[i];
          final selected = i == settings.skinIndex;
          return Tooltip(
            message: skin.name,
            child: GestureDetector(
              onTap: () => settings.setSkin(i),
              child: Container(
                width: 44,
                decoration: BoxDecoration(
                  color: skin.isGradient ? null : skin.colors.first,
                  gradient: skin.isGradient ? skin.gradient : null,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? Colors.white : Colors.white24,
                    width: selected ? 2.5 : 1,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
        value: value,
        onChanged: onChanged,
      );
}

class _SegmentRow<T> extends StatelessWidget {
  const _SegmentRow({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SegmentedButton<T>(
          segments: [
            for (final v in values) ButtonSegment(value: v, label: Text(labelOf(v))),
          ],
          selected: {selected},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
            width: 128,
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      );
}

/// Picks a logo image from the device.
///
/// image_picker returns a copy in the app's own cache, so the path stays
/// readable later without needing storage permission for the original file.
class _LogoPicker extends StatelessWidget {
  const _LogoPicker({required this.settings});

  final ReaderSettings settings;

  Future<void> _pick(BuildContext context) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // Cap the decode: a 12MP photo as a 28px-tall logo is pure waste.
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (picked != null) settings.setLogoImagePath(picked.path);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the image picker.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = settings.logoImagePath;

    return Row(
      children: [
        Container(
          width: 72,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: path == null
              ? const Icon(Icons.image_outlined, color: Colors.white38, size: 20)
              : Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    // A picked file can vanish (cache cleared, image deleted),
                    // so the preview must not throw when it does.
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image, color: Colors.white38, size: 20),
                  ),
                ),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          onPressed: () => _pick(context),
          icon: const Icon(Icons.upload, size: 16),
          label: Text(path == null ? 'Choose image' : 'Replace'),
        ),
        if (path != null)
          TextButton(
            onPressed: () => settings.setLogoImagePath(null),
            child: const Text('Remove'),
          ),
      ],
    );
  }
}

/// Opens a different PDF from the device.
///
/// The bundled asset is only a default. Anything the user picks replaces it for
/// the session, which is what makes this a reader rather than a demo of one PDF.
class _DocumentPicker extends StatefulWidget {
  const _DocumentPicker({required this.book});

  final PdfBook book;

  @override
  State<_DocumentPicker> createState() => _DocumentPickerState();
}

class _DocumentPickerState extends State<_DocumentPicker> {
  bool _busy = false;

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      final path = picked?.path;
      if (path == null) return;
      await widget.book.openFile(path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That file could not be opened as a PDF.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.picture_as_pdf_outlined, color: Colors.white38, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.book.title.isEmpty ? 'No document' : widget.book.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.folder_open, size: 16),
          label: const Text('Open PDF'),
        ),
      ],
    );
  }
}
