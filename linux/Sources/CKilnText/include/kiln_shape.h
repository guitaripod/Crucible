#ifndef KILN_SHAPE_H
#define KILN_SHAPE_H

#include <stdbool.h>
#include <stdint.h>

/** One step of a shape: path building (move, line, arc, curve, close) or painting the path built so far (fill, stroke),
 * which also clears it. Coordinates are in points; the renderer scales them to pixels. */
typedef enum {
    KILN_SHAPE_MOVE,
    KILN_SHAPE_LINE,
    /** a = centre x, b = centre y, c = radius, d = start angle, e = end angle (radians, clockwise on screen). */
    KILN_SHAPE_ARC,
    /** As KILN_SHAPE_ARC, counter-clockwise on screen. */
    KILN_SHAPE_ARC_NEGATIVE,
    /** a, b = first control point; c, d = second; e, f = end. */
    KILN_SHAPE_CURVE,
    KILN_SHAPE_CLOSE,
    /** a = coverage (0 to 1). */
    KILN_SHAPE_FILL,
    /** a = coverage from b (y in points) to coverage c at d: a vertical wash. */
    KILN_SHAPE_FILL_VERTICAL_RAMP,
    /** a = line width in points, b = coverage, c = 1 for round caps and joins. */
    KILN_SHAPE_STROKE,
} kiln_shape_verb;

typedef struct {
    int verb;
    double a, b, c, d, e, f;
} kiln_shape_op;

/** Rasterises `ops` as 8-bit coverage into `alpha` (`stride` bytes per row) at `scale` pixels per point, antialiased. */
bool kiln_shape_render(const kiln_shape_op *ops, int count, double scale, uint8_t *alpha, int width, int height, int stride);

#endif
