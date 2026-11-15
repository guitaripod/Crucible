#include "kiln_shape.h"

#include <cairo.h>

static void paint_coverage(cairo_t *cr, double coverage) {
    cairo_set_source_rgba(cr, 0, 0, 0, coverage);
}

bool kiln_shape_render(const kiln_shape_op *ops, int count, double scale, uint8_t *alpha, int width, int height, int stride) {
    if (width <= 0 || height <= 0 || stride < width) return false;
    cairo_surface_t *surface = cairo_image_surface_create_for_data(alpha, CAIRO_FORMAT_A8, width, height, stride);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return false;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_scale(cr, scale, scale);
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_GOOD);
    for (int index = 0; index < count; index++) {
        const kiln_shape_op *op = &ops[index];
        switch (op->verb) {
        case KILN_SHAPE_MOVE:
            cairo_move_to(cr, op->a, op->b);
            break;
        case KILN_SHAPE_LINE:
            cairo_line_to(cr, op->a, op->b);
            break;
        case KILN_SHAPE_ARC:
            cairo_arc(cr, op->a, op->b, op->c, op->d, op->e);
            break;
        case KILN_SHAPE_ARC_NEGATIVE:
            cairo_arc_negative(cr, op->a, op->b, op->c, op->d, op->e);
            break;
        case KILN_SHAPE_CURVE:
            cairo_curve_to(cr, op->a, op->b, op->c, op->d, op->e, op->f);
            break;
        case KILN_SHAPE_CLOSE:
            cairo_close_path(cr);
            break;
        case KILN_SHAPE_FILL:
            paint_coverage(cr, op->a);
            cairo_fill(cr);
            break;
        case KILN_SHAPE_FILL_VERTICAL_RAMP: {
            cairo_pattern_t *ramp = cairo_pattern_create_linear(0, op->b, 0, op->d);
            cairo_pattern_add_color_stop_rgba(ramp, 0, 0, 0, 0, op->a);
            cairo_pattern_add_color_stop_rgba(ramp, 1, 0, 0, 0, op->c);
            cairo_set_source(cr, ramp);
            cairo_fill(cr);
            cairo_pattern_destroy(ramp);
            break;
        }
        case KILN_SHAPE_STROKE: {
            bool round = op->c > 0.5;
            cairo_set_line_width(cr, op->a);
            cairo_set_line_cap(cr, round ? CAIRO_LINE_CAP_ROUND : CAIRO_LINE_CAP_BUTT);
            cairo_set_line_join(cr, round ? CAIRO_LINE_JOIN_ROUND : CAIRO_LINE_JOIN_MITER);
            paint_coverage(cr, op->b);
            cairo_stroke(cr);
            break;
        }
        default:
            break;
        }
    }
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    cairo_surface_destroy(surface);
    return true;
}
