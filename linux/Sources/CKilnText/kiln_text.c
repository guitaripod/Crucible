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
    if (style->letter_spacing_px != 0) {
        PangoAttrList *attributes = pango_attr_list_new();
        pango_attr_list_insert(attributes, pango_attr_letter_spacing_new((int) lround(style->letter_spacing_px * PANGO_SCALE)));
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
    pango_layout_set_text(layout, utf8, -1);
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
        .truncated = pango_layout_is_ellipsized(layout),
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
