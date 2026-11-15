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
} kiln_text_style;

typedef struct {
    int width;
    int height;
    int lines;
    int baseline;
    bool truncated;
} kiln_text_metrics;

/** Makes a font file available to Pango for this process (bundled Inter). */
bool kiln_text_register_font(const char *path);

/** Lays the text out with Pango: wrapping at `max_width_px`, at most `max_lines` lines, tail ellipsis past them. */
kiln_text_metrics kiln_text_measure(const char *utf8, const kiln_text_style *style);

/** Rasterises the laid-out text as 8-bit coverage into `alpha` (`stride` bytes per row), top left at the origin. */
bool kiln_text_render(const char *utf8, const kiln_text_style *style, uint8_t *alpha, int width, int height, int stride);

#endif
