# flip_reader

A page-curl PDF reader for Android, in Flutter. Open a PDF and read it like a book: drag the
corner and the paper lifts, bends and turns over, tracking your finger.

## Running it

```
flutter run
```

Needs Flutter 3.41 or newer and an Android device. A sample brochure is bundled, so it runs with
no setup.

## How the turn works

The turning page is modelled as paper wrapping a vertical cylinder of radius `r`. Paper coordinate
`x` runs from the spine to the free edge, and the fold sits at `c`:

```
x <= c              flat on the book, front face up
c < x <= c + pi*r   on the cylinder: x' = c + r*sin(theta), theta = (x - c) / r
x >  c + pi*r       wrapped past half a turn, lying flat on top, back face up
```

Two things follow from that model and they are what make it read as paper rather than as a
folding card:

- **Strips compress by `cos(theta)`.** That foreshortening is the roll. A `Transform.rotateY` about
  an edge gives none of it, which is why a hinge always looks like a hinge.
- **Past `theta = pi/2` the back face shows**, and the back of a page is the *next* page, sampled
  mirrored at `pageW - x`.

`CurlGeometry.cForEdge()` inverts the projection by bisection, so the free edge sits exactly under
the finger during a drag. Depth is projected too: paper standing out of the page plane is nearer
the eye, so it draws taller and leans, and it is allowed to hang past the book's edges.

Every `Paint` and `Shader` is allocated once in `CurlPaintResources`; `paint()` allocates nothing.

## Layout

| File | What it holds |
| --- | --- |
| `curl_painter.dart` | Curl geometry, the painter, and the drag state machine |
| `pdf_pipeline.dart` | PDF to `ui.Image` at device pixel ratio, sliding window, disposal, thumbnails |
| `reader_shell.dart` | Stage, toolbar, chevrons, thumbnail strip, zoom, autoplay, fullscreen |
| `reader_settings.dart` | Every user-changeable setting, as a `ChangeNotifier` |
| `settings_sheet.dart` | The customization panel |
| `contents_sheet.dart` | Contents and bookmarks |
| `hotspots.dart` / `hotspot_layer.dart` | Interactive elements and their actions |
| `home_screen.dart` | Sample or your own PDF, with covers |

## Reading

Drag a page to turn it, and it follows your finger. Tap the outer third of a page to turn without
dragging, tap the middle to show or hide the chrome. Pinch or double-tap to zoom. There is a
thumbnail strip, a scrub slider, autoplay, bookmarks, and a contents grid.

## Customizing

Toolbar overflow, then **Customize**:

- 18 skins, driving the stage and the toolbar
- Show or hide the toolbar, thumbnail strip, arrows, page number
- Fullscreen, and single or two-page in landscape
- Flip speed, **paper softness** (the curl radius) and **depth** (the perspective on the lifted
  leaf) — set depth to 0 for a flat turn and the difference is obvious
- A logo: type text or upload a PNG/JPEG, resize it, fade it, unlock it and drag it anywhere

## Interactive elements

Hotspots are described in a JSON sidecar next to the document, with coordinates normalised to the
page so they survive rotation, zoom and any render scale:

```json
{
  "page": 2,
  "rect": [0.20, 0.45, 0.60, 0.10],
  "action": "openUrl",
  "url": "https://example.com"
}
```

`action` is one of `openUrl`, `goToPage`, `popup`, `tooltip`, `video`, `audio`. They glow for a
moment when a page settles, then fade. A missing or malformed sidecar means no hotspots, never an
error.

Hotspot coordinates describe one specific document, so they are passed per document rather than
being global. A PDF opened from the device gets none.

## Performance notes

Pages render on demand at device pixel ratio, on a white backdrop so transparent PDFs do not
composite onto the dark stage. A window around the current page stays resident and everything else
is disposed, because a full-screen page image is several megabytes and a long document would
otherwise grow without bound. Thumbnails render small and are kept.

Nothing is cached to disk.

## Known limits

- The curl lifts the whole page edge. Dragging near a corner does not yet lift a triangle.
- The sliding window is fixed rather than derived from a memory budget.
- No text layer, so no text selection or search: `pdfx` exposes no text API, and adding one means a
  second PDF library.
