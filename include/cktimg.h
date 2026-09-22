/* cktimg C API — SPICE netlist in, placed schematic out.
 *
 * Link libcktimg.a. C99; needs only <stdbool.h>, <stddef.h>, <stdint.h>.
 *
 * ===========================================================================
 * THE LIBRARY KNOWS NO DEVICES
 * ===========================================================================
 *
 * You say what each device class looks like — its terminals (anchor points
 * in the canonical frame: origin at the device centre, y DOWN, two-pin
 * symbols with terminals at x = -20 and x = +20) and its body strokes — in a
 * CktimgLib you own, then place netlists with it. A device is looked up by
 * class name: "res", "cap", "ind", "vsource", "isource", "cvsource",
 * "cisource", "ccvs", "cccs", "bsource", "diode", "npn", "pnp", "njfet",
 * "pjfet", "mesfet", "nmos", "pmos", "switch", "tline", "urc". The supply,
 * ground, input and output symbols the layout adds are found by ROLE. A kind
 * with no class is drawn as a generated box ("generic<n>").
 *
 * ===========================================================================
 * THE HANDLE IS A VIEW, NOT A COPY — OWNERSHIP
 * ===========================================================================
 *
 * BORROWED (never free): every const char * an accessor returns, and the
 * points cktimg_wire_segment_points() hands out. Valid until
 * cktimg_sch_free() on that handle — and the CktimgLib it was placed with
 * must outlive the handle (class names and strokes point into it).
 *
 * CALLER-OWNED (free with cktimg_string_free, never free(3)): the return of
 * cktimg_run_json(), and every *out_report.
 *
 * CALLER-SUPPLIED BUFFERS: cktimg_json(), cktimg_lint() and
 * cktimg_device_op_points(): call with NULL to learn the size, then again.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 * A NULL handle or an out-of-range index is safe everywhere: NULL, 0 or
 * false, never a trap. Every out-parameter may be NULL. Coordinates are
 * integers, y increasing DOWNWARDS. Orientation is MIRROR (about the
 * vertical axis) THEN quarter turns CLOCKWISE; the op accessors apply it.
 */
#ifndef CKTIMG_H
#define CKTIMG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CktimgLib CktimgLib;
typedef struct CktimgSch CktimgSch;

/* ---------------------------------------------------------------------------
 * Device classes
 * ------------------------------------------------------------------------- */

/* What a class is placed as. NONE for devices; the others are the terminal
 * symbols the layout adds for supply, ground, input and output nets. */
typedef enum {
  CKTIMG_ROLE_NONE = 0,
  CKTIMG_ROLE_POWER_RAIL = 1,
  CKTIMG_ROLE_GROUND_RAIL = 2,
  CKTIMG_ROLE_INPUT_PORT = 3,
  CKTIMG_ROLE_OUTPUT_PORT = 4
} CktimgRole;

/* Terminal flags. HIDDEN: counts for paths, gets no wire (a MOS bulk drawn
 * on the symbol). GROUND_REF: gets no wire when its net is ground (an
 * op-amp's reference). */
enum { CKTIMG_TERM_HIDDEN = 1, CKTIMG_TERM_GROUND_REF = 2 };

/* One terminal. Terminals are in SPICE node order. */
typedef struct {
  const char *name;
  int32_t x, y;
  uint8_t flags;
} CktimgTerminal;

typedef enum {
  CKTIMG_OP_LINE = 0,     /* xy: x0,y0,x1,y1                        */
  CKTIMG_OP_POLYLINE = 1, /* xy: count points; closed repeats first */
  CKTIMG_OP_CIRCLE = 2,   /* xy: centre; r                          */
  CKTIMG_OP_TEXT = 3,     /* xy: centre; text, size (drawn upright) */
  CKTIMG_OP_NONE = 255
} CktimgOpKind;

/* One body stroke, in the canonical frame. */
typedef struct {
  uint8_t kind;
  const int32_t *xy;
  size_t count;
  int32_t r;
  const char *text;
  uint8_t size;
} CktimgOp;

CktimgLib *cktimg_lib_new(void);
void cktimg_lib_free(CktimgLib *lib);

/* Length of a two-pin symbol, pin end to pin end, in your coordinates
 * (default 40): the unit lint.zon's wire lengths are measured in. */
bool cktimg_lib_set_unit(CktimgLib *lib, int32_t unit);
size_t cktimg_lib_count(const CktimgLib *lib);

/* Add one class. Everything is copied. With no ops, a labelled box is
 * drawn around the terminals. Returns the class index, which never changes
 * meaning, or SIZE_MAX (no terminals, two terminals on one point, a name
 * already added with other terminals, bad arguments, out of memory). An
 * exact repeat returns the existing index. */
size_t cktimg_lib_add(CktimgLib *lib, const char *name, uint8_t role,
                      const CktimgTerminal *terms, size_t n_terms,
                      const CktimgOp *ops, size_t n_ops);

/* Add every class of a .zon symbol file (see tests/symbols.zon). true when
 * all were added; *out_report (optional, caller-owned) lists the rest. */
bool cktimg_lib_load_zon(CktimgLib *lib, const char *text, char **out_report);

/* ---------------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------------- */

/* Place NUL-terminated SPICE text with lib's classes and the lint.zon
 * settings in `zon` (NULL for the defaults). Returns NULL when the parser
 * rejects the netlist (.include, poly sources, an X card with no .subckt
 * are not represented), with the reason in *out_report. A subcircuit
 * instance is one block device (class named after the .subckt, or a
 * generated box), or its body when the definition says `*@ expand`. On success *out_report gets
 * the settings' complaints, "" when clean. out_report may be NULL. */
CktimgSch *cktimg_parse_place(CktimgLib *lib, const char *src, const char *zon,
                              char **out_report);

void cktimg_sch_free(CktimgSch *sch);
void cktimg_string_free(char *s);

/* The settings' complaints, BORROWED; "" when clean. */
const char *cktimg_report(const CktimgSch *sch);

/* The JSON document into YOUR buffer. Returns the length it needs, without
 * the NUL, whatever cap is; writes min(needed, cap - 1) bytes and a NUL. */
size_t cktimg_json(const CktimgSch *sch, char *buf, size_t cap);

/* Place and render to JSON in one call. CALLER-OWNED; NULL on failure. */
char *cktimg_run_json(CktimgLib *lib, const char *src, const char *zon,
                      char **out_report);

/* ---------------------------------------------------------------------------
 * Devices: the netlist's, then the rail and port symbols the layout added
 * (empty name, role != NONE), then those of the driver islands. A source
 * that drives a supply, input or bias net from ground is drawn apart, left
 * of the circuit, between its own terminal symbol and a ground symbol.
 * ------------------------------------------------------------------------- */

size_t cktimg_device_count(const CktimgSch *sch);
const char *cktimg_device_name(const CktimgSch *sch, size_t d);
const char *cktimg_device_class(const CktimgSch *sch, size_t d);
const char *cktimg_device_value(const CktimgSch *sch, size_t d);
uint8_t cktimg_device_role(const CktimgSch *sch, size_t d);
uint8_t cktimg_device_rot(const CktimgSch *sch, size_t d);
bool cktimg_device_mirror(const CktimgSch *sch, size_t d);
bool cktimg_device_pos(const CktimgSch *sch, size_t d, int32_t *x, int32_t *y);

/* Where to write the device's name: left end of the baseline, clear of
 * symbols, wires and the names placed before it. Computed for all devices on
 * the first call and cached in the handle. */
bool cktimg_device_refdes_anchor(CktimgSch *sch, size_t d, int32_t *x,
                                 int32_t *y);

/* ---------------------------------------------------------------------------
 * Pins, in SPICE node order. A card pin the class has no terminal for (a
 * MOSFET's bulk on a three-terminal symbol) sits at the device origin.
 * ------------------------------------------------------------------------- */

size_t cktimg_device_pin_count(const CktimgSch *sch, size_t d);
const char *cktimg_pin_term(const CktimgSch *sch, size_t d, size_t p);
const char *cktimg_pin_net(const CktimgSch *sch, size_t d, size_t p);
bool cktimg_pin_xy(const CktimgSch *sch, size_t d, size_t p, int32_t *x,
                   int32_t *y);

/* ---------------------------------------------------------------------------
 * Nets and wires. WIRE INDEX IS NET INDEX; a net drawn with no wire has 0
 * segments. A segment is a Manhattan polyline of >= 2 points.
 * ------------------------------------------------------------------------- */

size_t cktimg_net_count(const CktimgSch *sch);
const char *cktimg_net_name(const CktimgSch *sch, size_t n);
size_t cktimg_wire_count(const CktimgSch *sch);
const char *cktimg_wire_net(const CktimgSch *sch, size_t w);
size_t cktimg_wire_segment_count(const CktimgSch *sch, size_t w);

/* Points of segment s of wire w, ZERO-COPY: *xy gets a BORROWED flat
 * x0,y0,x1,y1,... array of 2*count values. NULL and 0 on a miss. */
size_t cktimg_wire_segment_points(const CktimgSch *sch, size_t w, size_t s,
                                  const int32_t **xy);

/* ---------------------------------------------------------------------------
 * Junction dots, net labels, no-connect crosses
 * ------------------------------------------------------------------------- */

size_t cktimg_junction_count(const CktimgSch *sch);
bool cktimg_junction(const CktimgSch *sch, size_t j, int32_t *x, int32_t *y);

/* A net's name written at a point where a wire gave way to a name. Draw
 * them, or the drawing loses connectivity. The text runs from the point
 * towards cktimg_label_side(): 0 left, 1 right, 2 up, 3 down. */
size_t cktimg_label_count(const CktimgSch *sch);
const char *cktimg_label_net(const CktimgSch *sch, size_t l);
bool cktimg_label_xy(const CktimgSch *sch, size_t l, int32_t *x, int32_t *y);
uint8_t cktimg_label_side(const CktimgSch *sch, size_t l);

/* A pin alone on its net: draw a small cross on it. */
size_t cktimg_noconnect_count(const CktimgSch *sch);
bool cktimg_noconnect(const CktimgSch *sch, size_t k, int32_t *x, int32_t *y);

/* ---------------------------------------------------------------------------
 * Bounds and symbol strokes, PLACED (oriented and moved already)
 * ------------------------------------------------------------------------- */

bool cktimg_bounds(const CktimgSch *sch, int32_t *min_x, int32_t *min_y,
                   int32_t *max_x, int32_t *max_y);
bool cktimg_device_bounds(const CktimgSch *sch, size_t d, int32_t *min_x,
                          int32_t *min_y, int32_t *max_x, int32_t *max_y);
size_t cktimg_device_op_count(const CktimgSch *sch, size_t d);
uint8_t cktimg_device_op_kind(const CktimgSch *sch, size_t d, size_t o);
size_t cktimg_device_op_points(const CktimgSch *sch, size_t d, size_t o,
                               int32_t *xy, size_t cap);
bool cktimg_device_op_circle(const CktimgSch *sch, size_t d, size_t o,
                             int32_t *cx, int32_t *cy, int32_t *r);
const char *cktimg_device_op_text(const CktimgSch *sch, size_t d, size_t o,
                                  int32_t *x, int32_t *y, uint8_t *size);

/* ---------------------------------------------------------------------------
 * Lint: the .rules of the settings the handle was placed with
 * ------------------------------------------------------------------------- */

/* One finding per line ("lint err duplicate_refdes: device r1 (...)") into
 * YOUR buffer; returns the length needed. *errors (optional) gets the number
 * of findings at "err". */
size_t cktimg_lint(const CktimgSch *sch, char *buf, size_t cap, size_t *errors);

#ifdef __cplusplus
}
#endif

#endif /* CKTIMG_H */
