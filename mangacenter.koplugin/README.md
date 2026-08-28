# Manga page shift

This reader-only KOReader plugin applies a per-book horizontal CSS shift to
images in fixed-layout EPUB manga. It can also center each rendered manga page
automatically by ignoring unequal white strips around its visible artwork.

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
preserves the manual value and mode for later use. It works in single-page page
mode on image-heavy pages. It deliberately leaves scroll mode, two-page mode,
and night mode untouched. Use **Clear auto-center cache** after changing a book
style or when a page was detected poorly; pages are analyzed again as they are
next drawn.

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
