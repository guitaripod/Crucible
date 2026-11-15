#ifndef KILN_IMAGE_H
#define KILN_IMAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/** Decodes a JPEG, PNG or WebP into straight-alpha RGBA8 rows, top first, at least `min_width` by `min_height` when the
 * format can decode smaller (JPEG's DCT scaling) and the full size otherwise. Returns a buffer for `kiln_image_free`, or
 * NULL with a reason in `error`. */
uint8_t *kiln_image_decode(const uint8_t *data, size_t size, int min_width, int min_height, int *width, int *height,
                           char *error, size_t error_size);
void kiln_image_free(uint8_t *pixels);

/** Renders an SVG document into a `pixel_size` square of 8-bit coverage (stride `pixel_size` rounded up to 4). */
uint8_t *kiln_svg_render_mask(const uint8_t *data, size_t size, int pixel_size, int *stride, char *error, size_t error_size);

#endif
