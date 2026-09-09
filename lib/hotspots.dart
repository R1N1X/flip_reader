import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a hotspot does when tapped.
///
/// These mirror the trigger actions of a commercial flipbook tool, minus the
/// ones that need an authoring UI to be worth anything.
enum HotspotAction {
  /// Open a URL in the browser.
  openUrl,

  /// Jump to another page in this document.
  goToPage,

  /// Show a titled panel of text, optionally with an image.
  popup,

  /// Show a short label near the tap, no dismissal needed.
  tooltip,

  /// Play a video in an overlay.
  video,

  /// Play an audio file, with no video surface.
  audio;

  static HotspotAction parse(String raw) => HotspotAction.values.firstWhere(
        (a) => a.name.toLowerCase() == raw.toLowerCase(),
        orElse: () => HotspotAction.tooltip,
      );
}

/// One tappable region on one page.
///
/// Coordinates are normalised to the page (0..1 in both axes) rather than
/// pixels, so a hotspot stays put across rotation, zoom and any render scale.
/// A pixel rect would be wrong the moment the page is drawn at a different size.
@immutable
class Hotspot {
  const Hotspot({
    required this.page,
    required this.rect,
    required this.action,
    this.url,
    this.targetPage,
    this.title,
    this.body,
    this.label,
  });

  /// 0-based page index.
  final int page;

  /// left, top, width, height as fractions of the page.
  final Rect rect;

  final HotspotAction action;
  final String? url;
  final int? targetPage;
  final String? title;
  final String? body;
  final String? label;

  static Hotspot? fromJson(Map<String, dynamic> json) {
    final page = json['page'];
    final r = json['rect'];
    if (page is! int || r is! List || r.length != 4) return null;
    return Hotspot(
      page: page,
      rect: Rect.fromLTWH(
        (r[0] as num).toDouble(),
        (r[1] as num).toDouble(),
        (r[2] as num).toDouble(),
        (r[3] as num).toDouble(),
      ),
      action: HotspotAction.parse(json['action'] as String? ?? 'tooltip'),
      url: json['url'] as String?,
      targetPage: json['targetPage'] as int?,
      title: json['title'] as String?,
      body: json['body'] as String?,
      label: json['label'] as String?,
    );
  }
}

/// Minimal rect so this file does not depend on the widget layer.
@immutable
class Rect {
  const Rect.fromLTWH(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;
}

/// Hotspots for the open document, grouped by page.
///
/// Loaded from `assets/hotspots.json`, which is optional: a document with no
/// sidecar simply has no interactive elements, and the reader behaves exactly
/// as it did before. A missing or malformed file must never stop the book
/// opening, so every failure path here ends in "no hotspots".
class HotspotSet {
  HotspotSet._(this._byPage);

  final Map<int, List<Hotspot>> _byPage;

  static HotspotSet empty() => HotspotSet._(const {});

  bool get isEmpty => _byPage.isEmpty;

  List<Hotspot> forPage(int page) => _byPage[page] ?? const [];

  static Future<HotspotSet> load(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      final list = decoded is List ? decoded : (decoded as Map)['hotspots'] as List;

      final byPage = <int, List<Hotspot>>{};
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final spot = Hotspot.fromJson(entry);
        if (spot == null) continue;
        byPage.putIfAbsent(spot.page, () => []).add(spot);
      }
      return HotspotSet._(byPage);
    } catch (_) {
      return HotspotSet._(const {});
    }
  }
}
