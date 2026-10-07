# Manga page shift

This reader-only KOReader plugin applies a per-book horizontal CSS shift to
images in fixed-layout EPUB manga. It can also center each rendered manga page
automatically by ignoring unequal white strips around its visible artwork.
Automatic centering is available for fixed-layout EPUB, PDF, DjVu, CBR, CBZ, and CBT. Fixed-page formats also support per-book continuous-view width and page-turn overlap controls.

## Installation

- In the KOReader App Store, search for **Manga Center** and choose **Direct
  download from repo** or the latest release.
- For manual installation, copy the complete `mangacenter.koplugin` directory
  into KOReader's `plugins` directory and restart KOReader.

The plugin also bundles two ordinary user Style Tweaks. At startup it copies
them, only when missing, into:

`koreader/styletweaks/Manga_page_shift/`

They then appear under **Style tweaks → User style tweaks → Manga page shift**.
Existing copies are never overwritten, so user edits survive plugin updates.

The adjustable per-book controls are registered directly at **Style tweaks →
Manga page shift**, as a sibling immediately after **User style tweaks**. This
is independent of whether KOReader has scanned the copied files yet. Its
top-level reader-menu entry remains as a shortcut.

Open an EPUB, then select **Manga page shift** from the reader menu. Choose:

- **Auto-center visible image content** to center the artwork independently on
  every image-heavy page. It samples KOReader's existing rendered page buffer,
  ignores unequal near-white outer strips, and caches the resulting pixel offset
  by page, screen size, and rendering settings. It does not alter or unpack the
  EPUB and does not trigger an extra pagination pass.

  Narrow straight lines around added white strips are treated as outer-strip
  rules when both sides are mostly empty. A straight line remains a real picture
  border when the page-edge side is white and the inward side has sustained
  image content; sparse translucent notes in a strip are ignored.

- **Constant shift** when every page needs the same correction, such as when
  disabling embedded styles leaves every image aligned to the left.
- **Opposite shift on alternating pages** when printed-book gutter whitespace
  makes successive page images lean in opposite directions.

Open **Adjust shift**, enter a percentage of the reader page width, and tap
**Apply and preview**. Positive values move constant-mode images to the right;
negative values move them left. In alternating mode, the following spine page
gets the opposite value: odd spine items use the entered value and even spine
items use its opposite. The entry accepts signed decimal values from -25 to 25
and closes after applying so the result can be previewed. Enter the same
magnitude with the opposite sign to reverse the alternating parity.

Use **Reverse shift direction** directly below **Adjust shift** to change the
current value from positive to negative, or negative to positive, in one tap.
The item is disabled when the shift is zero.

Automatic centering overrides the manual CSS shift while it is enabled, but
preserves the manual value and mode for later use. For EPUB it works in
single-page page mode on image-heavy pages. It deliberately leaves scroll mode,
two-page mode, and night mode untouched. Use **Clear auto-center cache** after
changing a book style or when a page was detected poorly; pages are analyzed
again as they are next drawn.

For PDF, DjVu, and comic archives, open **Manga page shift** from the reader's
**Typesetting** menu. **Auto-center visible image content** controls horizontal
left/right trimming, while **Fit detected image content vertically** controls
top/bottom trimming. In single-page full, width, and height fit modes these
toggles build one effective detected crop rectangle first; KOReader's own native
zoom mode then fits that cropped rectangle. Width mode may therefore remain
taller than the screen and pan through real artwork, but cropped white footer
space is no longer part of the page. Height mode likewise fits the cropped
height rather than the original page height. The vertical toggle is unavailable
in continuous mode.

Detection opens the source page through KOReader's KOPT interface and builds
fast Leptonica row/column ink projections. Those projections are passed through
the same sustained/dominant-body classifier used by the centering path: real
picture edges must continue inward across a band of content, while isolated
watermarks, page numbers, running headers, and other marginal satellites are
ignored where possible. Connected-component analysis remains as a fallback,
followed by KOPT's built-in auto-bbox detector if needed. This analysis is
independent of the on-screen tile cache, so it does not depend on
`drawSinglePage()` having already rendered the page. For paging documents the
detected bounds are also stored persistently in the book's KOReader metadata
under `manga_center_crop_bounds_v1`, so reopening a previously analyzed page
does not require running the detector again even if KOReader's rendered-page
cache has been evicted.

### Continuous manga controls

For PDF, DjVu, CBR, CBZ, and CBT, MangaCenter adds per-book controls in
continuous view:

- **Continuous manga width**: tap and type any value from 50% to 100%. It scales
  KOReader's native page-width/content-width zoom while keeping continuous mode.
  100% disables the extra zoom-out.
- **Panel-aware page-down**: Korean-webtoon structural rules are classified as
  both panel **ends** and panel **starts**. If a panel end is visible below the
  top, the next tap puts that end at the top first, so the separator and its
  narration/text are actually shown. A later tap snaps the next panel start to
  the top. Wide low-texture gray/colored separators are allowed to contain sparse
  text, and rectangular narration-box borders inside them are suppressed. Panel
  starts can still expand upward to include a substantial protruding speech or
  caption object. Tall panels/separators use the configured fallback overlap.
- **Fallback scroll overlap**: tap and type 0% to 90%. This is used whenever
  panel-aware paging has no structural anchor to snap to, and also for ordinary continuous
  page-down when panel-aware paging is disabled. Leave blank for KOReader's native
  `DOVERLAPPIXELS`. A custom percentage is measured against the whole visible screen, not the final underlying PDF-page fragment.
- **Continuous scroll gesture multiplier**: tap and type 0.25x to 10x. This scales
  vertical finger movement in all three KOReader continuous-scrolling methods.
  1.0x preserves native behavior, 0.5x halves the gesture effect, and 2.0x doubles
  it. In Classic it scales live finger-following distance; in Turbo it scales the
  displacement-driven scroll speed; in On-release it scales the net distance
  committed when the finger is lifted.

Width, panel-aware paging, fallback overlap, and the continuous gesture multiplier are exposed as Dispatcher actions for Profiles. Automatic
visible-content centering is also applied to continuous page states, so narrower
pages remain content-centered rather than merely canvas-centered.

In single-page full/width/height fit modes, the detected content box becomes a
temporary effective page rectangle: horizontal auto-center trims X, vertical fit
trims Y, and KOReader's native fit mode supplies the zoom. The source PDF/comic
is not modified. In continuous mode the vertical crop is disabled and the older
horizontal offset behavior is retained so existing continuous scrolling remains
stable. Detection results, including failures/zero-shift pages, are cached per
page; **Clear auto-center cache** forces another detection pass. Manual CSS
shifts are EPUB-only.

The plugin stores enablement, mode, and shift in the current book's document
settings. It does not modify the EPUB or replace the user's book-specific Style
Tweak. The first EPUB spine item is excluded so a cover is normally not shifted.

The same per-book controls are available to gestures and Profiles as dispatcher
actions: enable or disable the shift, toggle it, select constant or alternating
mode, set a numeric horizontal shift from -25% to 25%, or reverse the current
shift direction. Automatic centering also has explicit set and toggle actions.
A non-zero dispatched manual shift enables the manual feature and exits auto
mode; setting it to zero disables it. Reversing a zero shift does nothing.

Negative margins and page overflow are best supported with KOReader's
**Render mode: Web**.

The reader-menu shift and the ordinary Style Tweaks use the same technique. Do
not enable both at once unless their shifts are intentionally meant to add up.

Plugin UI translations are included for Simplified Chinese (`zh_CN`) and
Traditional Chinese (`zh_TW`, also used for `zh_HK`, `zh_MO`, and Hant locale
aliases). Generic Chinese and Hans locale aliases use Simplified Chinese.

### Startup and page prefetch behavior

For PDF/DjVu/comic paging documents, MangaCenter deliberately does not install its crop-aware
zoom/layout hooks during the plugin's initial setup. KOReader may temporarily hold page 1 while
restoring the saved reading location, and analyzing that transient page would add unnecessary
startup work.

At `ReaderReady`, after KOReader has restored the real current page but before input is enabled,
MangaCenter detects only the crop required for that restored page and then installs the minimal
crop-aware zoom/layout hooks. Continuous-scroll/overlap helper hooks are deferred until after the
startup input gate.

KOReader's native ReaderHinting already pre-renders the next page (one page ahead by default via
`DHINTCOUNT = 1`). Once MangaCenter's hooks are active, the hinting call to `getZoom(next_page)`
also populates MangaCenter's crop store for that page before KOReader renders it, so ordinary page
turns can use both a prefetched crop and KOReader's normal rendered-page cache. Newly detected
bounds are marked dirty and written to the per-book sidecar after 2 seconds of detector idle time;
additional hinted pages reset that timer so nearby results are batched into one write. Dirty bounds
are also flushed on document close. v6-and-earlier table-valued paging records from
`manga_center_auto_offsets` are migrated automatically to `manga_center_crop_bounds_v1`.

## Per-book edge-strip strictness

For automatic fixed-page cropping, MangaCenter exposes separate **Horizontal strip strictness** and **Vertical strip strictness** controls. Each is stored per book and offers five presets: **Very loose**, **Loose**, **Normal**, **Strict**, and **Very strict**. **Normal is exactly the historical detector behavior**. Moving toward Strict makes MangaCenter demand stronger evidence before discarding edge content, so it crops less and protects small or isolated panels and speech bubbles; moving toward Loose crops more aggressively. Horizontal presets group the projection ink-density/persistence and outer-strip checks, while vertical presets group ink activity, minimum protected panel size, relative panel strength, and attachment/gap tolerance. Changing either preset clears that book's detected crop cache and immediately re-evaluates pages with the new setting.
