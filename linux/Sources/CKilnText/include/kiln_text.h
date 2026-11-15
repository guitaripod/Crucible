#ifndef KILN_TEXT_H
#define KILN_TEXT_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    const char *family;
    double size_px;
    double optical_size;
    int weight;
    bool italic;
    int max_width_px;
    int max_lines;
    int alignment;
    double letter_spacing_px;
    /** Byte ranges (start, end pairs) of the only text drawn: everything else is laid out but left transparent, so the
     * mask lines up with the full text's and tints just the matched words. NULL draws all of it. */
    const int *visible_ranges;
    int visible_range_count;
    /** The text is Pango markup (`<b>`, `<i>`, `<s>`, `<tt>`, `<span background=…>`), escaped by the caller; letter spacing
     * and visible ranges do not apply to it. */
    bool markup;
} kiln_text_style;

typedef struct {
    int width;
    int height;
    int lines;
    int baseline;
    bool truncated;
} kiln_text_metrics;

typedef struct {
    int x;
    int y;
    int height;
} kiln_text_caret;

/** Makes a font file available to Pango for this process (bundled Inter). */
bool kiln_text_register_font(const char *path);

/** Lays the text out with Pango: wrapping at `max_width_px`, at most `max_lines` lines, tail ellipsis past them. */
kiln_text_metrics kiln_text_measure(const char *utf8, const kiln_text_style *style);

/** Rasterises the laid-out text as 8-bit coverage into `alpha` (`stride` bytes per row), top left at the origin. */
bool kiln_text_render(const char *utf8, const kiln_text_style *style, uint8_t *alpha, int width, int height, int stride);

/** Rasterises the laid-out text in colour into `rgba` (straight-alpha RGBA, 8 bits a channel, `stride` bytes per row): the
 * glyphs in the sRGB colour `red`, `green`, `blue` (0 to 1) and colour glyphs (emoji) in their own colours. */
bool kiln_text_render_color(const char *utf8, const kiln_text_style *style, double red, double green, double blue, uint8_t *rgba, int width,
                            int height, int stride);

/** Where the caret before the byte at `byte_index` stands in the laid-out text, in pixels from the top left. */
kiln_text_caret kiln_text_caret_at(const char *utf8, const kiln_text_style *style, int byte_index);

/** The byte index of the character boundary nearest `x`, `y` (pixels from the top left) in the laid-out text. */
int kiln_text_index_at(const char *utf8, const kiln_text_style *style, int x, int y);

#endif
