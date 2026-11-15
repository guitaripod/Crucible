#include "kiln_text.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <pango/pangocairo.h>

static PangoContext *shared_context(void) {
    static PangoContext *context;
    if (!context) {
        PangoFontMap *map = pango_cairo_font_map_new();
        context = pango_font_map_create_context(map);
        cairo_font_options_t *options = cairo_font_options_create();
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
        cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_SLIGHT);
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF);
        pango_cairo_context_set_font_options(context, options);
        cairo_font_options_destroy(options);
        pango_context_set_round_glyph_positions(context, FALSE);
        g_object_unref(map);
    }
    return context;
}

bool kiln_text_register_font(const char *path) {
    return FcConfigAppFontAddFile(FcConfigGetCurrent(), (const FcChar8 *) path) == FcTrue;
}

/** Pango's line limit counts per paragraph, so text in several paragraphs runs past it: this cuts the text where line
 * `max_lines` would start and ends it in an ellipsis, keeping the attributes, and marks the layout as cut. */
static void limit_lines(PangoLayout *layout, int max_lines) {
    if (max_lines <= 0) return;
    for (int attempt = 0; attempt < 4 && pango_layout_get_line_count(layout) > max_lines; attempt++) {
        PangoLayoutLine *line = pango_layout_get_line_readonly(layout, max_lines);
        if (!line) return;
        const char *text = pango_layout_get_text(layout);
        int cut = line->start_index;
        while (cut > 0 && (text[cut - 1] == '\n' || text[cut - 1] == '\r' || text[cut - 1] == ' ')) cut--;
        if (attempt > 0) {
            const char *previous = g_utf8_find_prev_char(text, text + cut);
            if (previous) cut = (int) (previous - text);
        }
        GString *shortened = g_string_new_len(text, cut);
        g_string_append(shortened, "\u2026");
        PangoAttrList *attributes = pango_layout_get_attributes(layout);
        if (attributes) pango_attr_list_ref(attributes);
        pango_layout_set_text(layout, shortened->str, -1);
        if (attributes) {
            pango_layout_set_attributes(layout, attributes);
            pango_attr_list_unref(attributes);
        }
        g_string_free(shortened, TRUE);
        g_object_set_data(G_OBJECT(layout), "kiln-cut", GINT_TO_POINTER(1));
    }
}

/** One PangoLayout for the text and style; the caller unrefs it. */
static PangoLayout *make_layout(const char *utf8, const kiln_text_style *style) {
    PangoLayout *layout = pango_layout_new(shared_context());
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, style->family ? style->family : "Inter Variable");
    pango_font_description_set_absolute_size(font, style->size_px * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight) (style->weight > 0 ? style->weight : 400));
    pango_font_description_set_style(font, style->italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    if (style->optical_size > 0) {
        char variations[32];
        snprintf(variations, sizeof(variations), "opsz=%.1f", fmin(fmax(style->optical_size, 14), 32));
        pango_font_description_set_variations(font, variations);
    }
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    if (!style->markup && (style->letter_spacing_px != 0 || style->visible_ranges)) {
        PangoAttrList *attributes = pango_attr_list_new();
        if (style->letter_spacing_px != 0) {
            pango_attr_list_insert(attributes, pango_attr_letter_spacing_new((int) lround(style->letter_spacing_px * PANGO_SCALE)));
        }
        if (style->visible_ranges) {
            pango_attr_list_insert(attributes, pango_attr_foreground_alpha_new(1));
            for (int index = 0; index < style->visible_range_count; index++) {
                PangoAttribute *shown = pango_attr_foreground_alpha_new(65535);
                shown->start_index = (guint) style->visible_ranges[index * 2];
                shown->end_index = (guint) style->visible_ranges[index * 2 + 1];
                pango_attr_list_insert(attributes, shown);
            }
        }
        pango_layout_set_attributes(layout, attributes);
        pango_attr_list_unref(attributes);
    }
    pango_layout_set_alignment(layout, style->alignment == 1 ? PANGO_ALIGN_CENTER : style->alignment == 2 ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    if (style->max_width_px > 0) {
        pango_layout_set_width(layout, style->max_width_px * PANGO_SCALE);
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
    }
    if (style->max_lines > 0) {
        pango_layout_set_height(layout, -style->max_lines);
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
    }
    if (style->markup) {
        pango_layout_set_markup(layout, utf8, -1);
    } else {
        pango_layout_set_text(layout, utf8, -1);
    }
    limit_lines(layout, style->max_lines);
    return layout;
}

kiln_text_metrics kiln_text_measure(const char *utf8, const kiln_text_style *style) {
    PangoLayout *layout = make_layout(utf8, style);
    PangoRectangle logical;
    pango_layout_get_pixel_extents(layout, NULL, &logical);
    kiln_text_metrics metrics = {
        .width = style->max_width_px > 0 && style->alignment != 0 ? style->max_width_px : logical.x + logical.width,
        .height = logical.y + logical.height,
        .lines = pango_layout_get_line_count(layout),
        .baseline = PANGO_PIXELS(pango_layout_get_baseline(layout)),
        .truncated = pango_layout_is_ellipsized(layout) || g_object_get_data(G_OBJECT(layout), "kiln-cut") != NULL,
    };
    g_object_unref(layout);
    return metrics;
}

bool kiln_text_render(const char *utf8, const kiln_text_style *style, uint8_t *alpha, int width, int height, int stride) {
    if (width <= 0 || height <= 0 || stride < cairo_format_stride_for_width(CAIRO_FORMAT_A8, width)) return false;
    memset(alpha, 0, (size_t) stride * height);
    cairo_surface_t *surface = cairo_image_surface_create_for_data(alpha, CAIRO_FORMAT_A8, width, height, stride);
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = make_layout(utf8, style);
    pango_cairo_update_layout(cr, layout);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    cairo_surface_destroy(surface);
    return true;
}

bool kiln_text_render_color(const char *utf8, const kiln_text_style *style, double red, double green, double blue, uint8_t *rgba, int width,
                            int height, int stride) {
    if (width <= 0 || height <= 0 || stride < width * 4) return false;
    memset(rgba, 0, (size_t) stride * height);
    cairo_surface_t *surface = cairo_image_surface_create_for_data(rgba, CAIRO_FORMAT_ARGB32, width, height, stride);
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgb(cr, red, green, blue);
    PangoLayout *layout = make_layout(utf8, style);
    pango_cairo_update_layout(cr, layout);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    cairo_surface_destroy(surface);
    for (int y = 0; y < height; y++) {
        uint32_t *row = (uint32_t *) (rgba + (size_t) y * stride);
        for (int x = 0; x < width; x++) {
            uint32_t pixel = row[x];
            uint32_t a = pixel >> 24;
            uint32_t r = (pixel >> 16) & 0xFF, g = (pixel >> 8) & 0xFF, b = pixel & 0xFF;
            if (a > 0 && a < 255) {
                r = (r * 255 + a / 2) / a;
                g = (g * 255 + a / 2) / a;
                b = (b * 255 + a / 2) / a;
            }
            uint8_t *out = (uint8_t *) &row[x];
            out[0] = (uint8_t) (r > 255 ? 255 : r);
            out[1] = (uint8_t) (g > 255 ? 255 : g);
            out[2] = (uint8_t) (b > 255 ? 255 : b);
            out[3] = (uint8_t) a;
        }
    }
    return true;
}
