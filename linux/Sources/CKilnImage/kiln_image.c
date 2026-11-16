#include "kiln_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <turbojpeg.h>
#include <png.h>
#include <webp/decode.h>
#include <librsvg/rsvg.h>
#include <gif_lib.h>

static void fail(char *error, size_t error_size, const char *reason) {
    if (error && error_size) snprintf(error, error_size, "%s", reason);
}

static bool is_jpeg(const uint8_t *data, size_t size) { return size > 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF; }
static bool is_png(const uint8_t *data, size_t size) { return size > 8 && memcmp(data, "\x89PNG\r\n\x1a\n", 8) == 0; }
static bool is_webp(const uint8_t *data, size_t size) { return size > 12 && memcmp(data, "RIFF", 4) == 0 && memcmp(data + 8, "WEBP", 4) == 0; }
static bool is_gif(const uint8_t *data, size_t size) { return size > 6 && memcmp(data, "GIF8", 4) == 0; }

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t offset;
} gif_source;

static int gif_read(GifFileType *file, GifByteType *buffer, int length) {
    gif_source *source = file->UserData;
    size_t left = source->size - source->offset;
    size_t count = (size_t) length < left ? (size_t) length : left;
    memcpy(buffer, source->data + source->offset, count);
    source->offset += count;
    return (int) count;
}

uint8_t *kiln_gif_decode_frames(const uint8_t *data, size_t size, int max_frames, int *width, int *height, int *count, int **delays,
                                char *error, size_t error_size) {
    gif_source source = { data, size, 0 };
    int status = 0;
    GifFileType *file = DGifOpen(&source, gif_read, &status);
    if (!file) {
        fail(error, error_size, "gif open");
        return NULL;
    }
    if (DGifSlurp(file) != GIF_OK || file->ImageCount < 1 || file->SWidth <= 0 || file->SHeight <= 0) {
        fail(error, error_size, "gif decode");
        DGifCloseFile(file, &status);
        return NULL;
    }
    int w = file->SWidth, h = file->SHeight;
    int frames = file->ImageCount < max_frames ? file->ImageCount : max_frames;
    size_t frame_bytes = (size_t) w * h * 4;
    uint8_t *out = calloc(frame_bytes * frames, 1);
    uint8_t *canvas = calloc(frame_bytes, 1);
    uint8_t *previous = calloc(frame_bytes, 1);
    int *times = calloc(frames, sizeof(int));
    if (!out || !canvas || !previous || !times) {
        free(out); free(canvas); free(previous); free(times);
        fail(error, error_size, "gif memory");
        DGifCloseFile(file, &status);
        return NULL;
    }
    for (int index = 0; index < frames; index++) {
        SavedImage *image = &file->SavedImages[index];
        GraphicsControlBlock control = { .DisposalMode = DISPOSAL_UNSPECIFIED, .DelayTime = 10, .TransparentColor = NO_TRANSPARENT_COLOR };
        DGifSavedExtensionToGCB(file, index, &control);
        ColorMapObject *map = image->ImageDesc.ColorMap ? image->ImageDesc.ColorMap : file->SColorMap;
        if (control.DisposalMode == DISPOSE_PREVIOUS) memcpy(previous, canvas, frame_bytes);
        int left = image->ImageDesc.Left, top = image->ImageDesc.Top;
        int frame_width = image->ImageDesc.Width, frame_height = image->ImageDesc.Height;
        for (int y = 0; y < frame_height && map; y++) {
            int row = image->ImageDesc.Interlace ? -1 : y;
            if (image->ImageDesc.Interlace) {
                static const int starts[] = { 0, 4, 2, 1 }, steps[] = { 8, 8, 4, 2 };
                int seen = 0;
                for (int pass = 0; pass < 4 && row < 0; pass++) {
                    int rows = (frame_height - starts[pass] + steps[pass] - 1) / steps[pass];
                    if (y < seen + rows) row = starts[pass] + (y - seen) * steps[pass];
                    seen += rows;
                }
            }
            int canvas_y = top + row;
            if (canvas_y < 0 || canvas_y >= h) continue;
            for (int x = 0; x < frame_width; x++) {
                int canvas_x = left + x;
                if (canvas_x < 0 || canvas_x >= w) continue;
                int color = image->RasterBits[y * frame_width + x];
                if (color == control.TransparentColor || color >= map->ColorCount) continue;
                uint8_t *pixel = canvas + ((size_t) canvas_y * w + canvas_x) * 4;
                pixel[0] = map->Colors[color].Red;
                pixel[1] = map->Colors[color].Green;
                pixel[2] = map->Colors[color].Blue;
                pixel[3] = 255;
            }
        }
        memcpy(out + frame_bytes * index, canvas, frame_bytes);
        times[index] = control.DelayTime > 1 ? control.DelayTime * 10 : 100;
        if (control.DisposalMode == DISPOSE_BACKGROUND) {
            for (int y = top; y < top + frame_height && y < h; y++) {
                if (y < 0) continue;
                for (int x = left; x < left + frame_width && x < w; x++) {
                    if (x >= 0) memset(canvas + ((size_t) y * w + x) * 4, 0, 4);
                }
            }
        } else if (control.DisposalMode == DISPOSE_PREVIOUS) {
            memcpy(canvas, previous, frame_bytes);
        }
    }
    free(canvas);
    free(previous);
    DGifCloseFile(file, &status);
    *width = w;
    *height = h;
    *count = frames;
    *delays = times;
    return out;
}

static uint8_t *decode_gif(const uint8_t *data, size_t size, int *width, int *height, char *error, size_t error_size) {
    int count = 0;
    int *delays = NULL;
    uint8_t *frames = kiln_gif_decode_frames(data, size, 1, width, height, &count, &delays, error, error_size);
    free(delays);
    return frames;
}

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
    if (is_gif(data, size)) return decode_gif(data, size, width, height, error, error_size);
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

bool kiln_image_write_png(const char *path, const uint8_t *rgba, int width, int height) {
    png_image image;
    memset(&image, 0, sizeof image);
    image.version = PNG_IMAGE_VERSION;
    image.width = (png_uint_32)width;
    image.height = (png_uint_32)height;
    image.format = PNG_FORMAT_RGBA;
    return png_image_write_to_file(&image, path, 0, rgba, width * 4, NULL) != 0;
}

uint8_t *kiln_image_encode_png(const uint8_t *rgba, int width, int height, size_t *length) {
    png_image image;
    memset(&image, 0, sizeof image);
    image.version = PNG_IMAGE_VERSION;
    image.width = (png_uint_32)width;
    image.height = (png_uint_32)height;
    image.format = PNG_FORMAT_RGBA;
    png_alloc_size_t size = 0;
    if (!png_image_write_to_memory(&image, NULL, &size, 0, rgba, width * 4, NULL) || size == 0) return NULL;
    uint8_t *bytes = malloc(size);
    if (!bytes) return NULL;
    if (!png_image_write_to_memory(&image, bytes, &size, 0, rgba, width * 4, NULL)) {
        free(bytes);
        return NULL;
    }
    *length = size;
    return bytes;
}
