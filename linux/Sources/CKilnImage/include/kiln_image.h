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

/** Decodes every frame of a GIF, each composited over the ones before it as the GIF's disposal asks, into `*count`
 * straight-alpha RGBA8 frames of `*width` by `*height` laid one after another, with each frame's delay in milliseconds in
 * `*delays` (free with `kiln_image_free`). At most `max_frames` frames. Returns NULL with a reason in `error`. */
uint8_t *kiln_gif_decode_frames(const uint8_t *data, size_t size, int max_frames, int *width, int *height, int *count, int **delays,
                                char *error, size_t error_size);

/** Renders an SVG document into a `pixel_size` square of 8-bit coverage (stride `pixel_size` rounded up to 4). */
uint8_t *kiln_svg_render_mask(const uint8_t *data, size_t size, int pixel_size, int *stride, char *error, size_t error_size);

/** Writes 8-bit RGBA rows (top first) as a PNG file. */
bool kiln_image_write_png(const char *path, const uint8_t *rgba, int width, int height);

/** Encodes 8-bit RGBA rows (top first) as PNG bytes in memory, to free, with their count in `length`; NULL on failure. */
uint8_t *kiln_image_encode_png(const uint8_t *rgba, int width, int height, size_t *length);

#endif
