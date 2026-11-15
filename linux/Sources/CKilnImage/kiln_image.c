#include "kiln_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <turbojpeg.h>
#include <png.h>
#include <webp/decode.h>
#include <librsvg/rsvg.h>

static void fail(char *error, size_t error_size, const char *reason) {
    if (error && error_size) snprintf(error, error_size, "%s", reason);
}

static bool is_jpeg(const uint8_t *data, size_t size) { return size > 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF; }
static bool is_png(const uint8_t *data, size_t size) { return size > 8 && memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0; }
static bool is_webp(const uint8_t *data, size_t size) { return size > 12 && memcmp(data, "RIFF", 4) == 0 && memcmp(data + 8, "WEBP", 4) == 0; }

/** The smallest DCT scaling factor that still covers the requested size, so a 4K backdrop asked for at 1280 decodes at
 * half or quarter size in a fraction of the time. */
static tjscalingfactor jpeg_scale(int width, int height, int min_width, int min_height) {
    int count = 0;
    tjscalingfactor *factors = tj3GetScalingFactors(&count);
    tjscalingfactor best = { 1, 1 };
    if (!factors || min_width <= 0 || min_height <= 0) return best;
    for (int i = 0; i < count; i++) {
        tjscalingfactor f = factors[i];
        if (f.num > f.denom) continue;
        int w = TJSCALED(width, f);
        int h = TJSCALED(height, f);
        if (w >= min_width && h >= min_height && w * h < TJSCALED(width, best) * TJSCALED(height, best)) best = f;
    }
    return best;
}

static uint8_t *decode_jpeg(const uint8_t *data, size_t size, int min_width, int min_height, int *width, int *height, char *error, size_t error_size) {
    tjhandle handle = tj3Init(TJINIT_DECOMPRESS);
    if (!handle) {
        fail(error, error_size, "turbojpeg init");
        return NULL;
    }
    uint8_t *pixels = NULL;
    if (tj3DecompressHeader(handle, data, size) != 0) {
        fail(error, error_size, tj3GetErrorStr(handle));
        goto done;
    }
    int full_width = tj3Get(handle, TJPARAM_JPEGWIDTH);
    int full_height = tj3Get(handle, TJPARAM_JPEGHEIGHT);
    tjscalingfactor factor = jpeg_scale(full_width, full_height, min_width, min_height);
    tj3SetScalingFactor(handle, factor);
    tj3Set(handle, TJPARAM_FASTDCT, 0);
    tj3Set(handle, TJPARAM_FASTUPSAMPLE, 0);
    int w = TJSCALED(full_width, factor);
    int h = TJSCALED(full_height, factor);
    pixels = malloc((size_t)w * h * 4);
    if (!pixels) {
        fail(error, error_size, "out of memory");
        goto done;
    }
    if (tj3Decompress8(handle, data, size, pixels, w * 4, TJPF_RGBA) != 0 && tj3GetErrorCode(handle) == TJERR_FATAL) {
        fail(error, error_size, tj3GetErrorStr(handle));
        free(pixels);
        pixels = NULL;
        goto done;
    }
    *width = w;
    *height = h;
done:
    tj3Destroy(handle);
    return pixels;
}

static uint8_t *decode_png(const uint8_t *data, size_t size, int *width, int *height, char *error, size_t error_size) {
    png_image image;
    memset(&image, 0, sizeof image);
    image.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&image, data, size)) {
        fail(error, error_size, image.message);
        return NULL;
    }
    image.format = PNG_FORMAT_RGBA;
    uint8_t *pixels = malloc(PNG_IMAGE_SIZE(image));
    if (!pixels) {
        png_image_free(&image);
        fail(error, error_size, "out of memory");
        return NULL;
    }
    if (!png_image_finish_read(&image, NULL, pixels, 0, NULL)) {
        fail(error, error_size, image.message);
        free(pixels);
        return NULL;
    }
    *width = (int)image.width;
    *height = (int)image.height;
    return pixels;
}

static uint8_t *decode_webp(const uint8_t *data, size_t size, int *width, int *height, char *error, size_t error_size) {
    uint8_t *decoded = WebPDecodeRGBA(data, size, width, height);
    if (!decoded) {
        fail(error, error_size, "webp decode");
        return NULL;
    }
    size_t bytes = (size_t)(*width) * (*height) * 4;
    uint8_t *pixels = malloc(bytes);
    if (pixels) memcpy(pixels, decoded, bytes);
    WebPFree(decoded);
    if (!pixels) fail(error, error_size, "out of memory");
    return pixels;
}

uint8_t *kiln_image_decode(const uint8_t *data, size_t size, int min_width, int min_height, int *width, int *height,
                           char *error, size_t error_size) {
    if (!data || !size) {
        fail(error, error_size, "empty");
        return NULL;
    }
    if (is_jpeg(data, size)) return decode_jpeg(data, size, min_width, min_height, width, height, error, error_size);
    if (is_png(data, size)) return decode_png(data, size, width, height, error, error_size);
    if (is_webp(data, size)) return decode_webp(data, size, width, height, error, error_size);
    fail(error, error_size, "unknown image format");
    return NULL;
}

void kiln_image_free(uint8_t *pixels) { free(pixels); }

uint8_t *kiln_svg_render_mask(const uint8_t *data, size_t size, int pixel_size, int *stride, char *error, size_t error_size) {
    GError *gerror = NULL;
    RsvgHandle *handle = rsvg_handle_new_from_data(data, size, &gerror);
    if (!handle) {
        fail(error, error_size, gerror ? gerror->message : "svg parse");
        if (gerror) g_error_free(gerror);
        return NULL;
    }
    int row = cairo_format_stride_for_width(CAIRO_FORMAT_A8, pixel_size);
    uint8_t *pixels = calloc((size_t)row * pixel_size, 1);
    cairo_surface_t *surface = cairo_image_surface_create_for_data(pixels, CAIRO_FORMAT_A8, pixel_size, pixel_size, row);
    cairo_t *cr = cairo_create(surface);
    RsvgRectangle viewport = { 0, 0, pixel_size, pixel_size };
    bool ok = rsvg_handle_render_document(handle, cr, &viewport, &gerror);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    cairo_surface_destroy(surface);
    g_object_unref(handle);
    if (!ok) {
        fail(error, error_size, gerror ? gerror->message : "svg render");
        if (gerror) g_error_free(gerror);
        free(pixels);
        return NULL;
    }
    *stride = row;
    return pixels;
}
