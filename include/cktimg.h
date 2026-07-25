/* cktimg C API — SPICE/netlist text in, placed schematic out.
 *
 * Link against libcktimg.a (or the shared build). C99, no dependencies beyond
 * <stdbool.h>, <stddef.h> and <stdint.h>.
 *
 * ===========================================================================
 * THE HANDLE IS A VIEW, NOT A COPY
 * ===========================================================================
 *
 * cktimg_parse_place() runs the pipeline once and returns a handle onto the
 * placed schematic itself. The accessors below read the router's own arrays:
 * a name comes back as a pointer into the interned string pool, and a wire's
 * points come back as a pointer into the packed point array. Nothing is
 * duplicated, reshaped or re-encoded on the way out, so walking a schematic
 * from C costs the same as walking it from inside the library.
 *
 * ===========================================================================
 * OWNERSHIP — read this once and the whole API follows
 * ===========================================================================
 *
 * BORROWED (do NOT free, do NOT pass to cktimg_string_free or free(3)):
 *   - every `const char *` returned by an accessor;
 *   - the `const int32_t *` written by cktimg_wire_segment_points().
 *   Valid until cktimg_sch_free() on the handle they came from. After that
 *   call, every one of them dangles.
 *
 * CALLER-OWNED (release with cktimg_string_free, never free(3) — these are not
 * malloc allocations):
 *   - the return of cktimg_run_json();
 *   - the return of cktimg_run_json_with_report() and its *out_report;
 *   - the *out_report of cktimg_parse_place_with_report().
 *   That is the complete list.
 *
 * CALLER-SUPPLIED BUFFERS (this library allocates nothing):
 *   - cktimg_json(), cktimg_device_op_points(). Both use the two-call idiom:
 *     call with a NULL buffer to learn the size, then call again.
 *
 * ===========================================================================
 * SAFETY
 * ===========================================================================
 *
 *   - A NULL handle and an out-of-range index are SAFE everywhere. Accessors
 *     return NULL / 0 / false and never trap. This is a trust boundary and it
 *     is fully checked.
 *   - Every out-parameter (x, y, xy, size, out_report, …) may be NULL to skip
 *     that output.
 *   - Coordinates are integer grid units with y increasing DOWNWARDS. A
 *     renderer whose canvas is y-up negates y.
 *   - Symbol orientation is MIRROR (about the vertical axis) THEN ROTATION.
 *     Reverse the order and mirrored symbols land in the wrong place. Use the
 *     cktimg_device_op_* accessors and the transform is already applied.
 */
#ifndef CKTIMG_H
#define CKTIMG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque placed-schematic handle. */
typedef struct CktimgSch CktimgSch;

/* ---------------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------------- */

/* Parse and place NUL-terminated SPICE text.
 *
 * Returns a handle, or NULL if `src` is NULL or memory ran out. A netlist the
 * front end could not fully represent is NOT a failure: you get a handle plus
 * a non-empty report, because a partial drawing beats a refusal.
 *
 * Free with cktimg_sch_free().
 */
CktimgSch *cktimg_parse_place(const char *src);

/* As cktimg_parse_place(), additionally writing the parse report to
 * *out_report: one text line per ignored/skipped source line, empty string for
 * a clean netlist. Pass NULL for out_report to skip it.
 *
 * *out_report is CALLER-OWNED — free it with cktimg_string_free(). For a
 * borrowed copy you do not have to manage, use cktimg_report() instead.
 *
 * On failure returns NULL and sets *out_report to NULL (when non-NULL).
 */
CktimgSch *cktimg_parse_place_with_report(const char *src, char **out_report);

/* Free a schematic handle. NULL is a no-op. Invalidates EVERY borrowed string
 * and point pointer obtained from this handle. */
void cktimg_sch_free(CktimgSch *sch);

/* Parse, place and render to a JSON document in one call.
 *
 * Returns a newly allocated NUL-terminated JSON string, or NULL if `src` is
 * NULL or memory ran out. CALLER-OWNED: free with cktimg_string_free().
 *
 * If you are going to walk the schematic anyway, prefer cktimg_parse_place()
 * plus cktimg_json(), which streams into your own buffer and allocates
 * nothing.
 */
char *cktimg_run_json(const char *src);

/* As cktimg_run_json(), additionally writing the parse report to *out_report.
 * Both strings are CALLER-OWNED; free both with cktimg_string_free(). Pass
 * NULL for out_report to skip it. On failure returns NULL and sets
 * *out_report to NULL (when non-NULL). */
char *cktimg_run_json_with_report(const char *src, char **out_report);

/* Free a string this library allocated. NULL is a no-op.
 *
 * Valid ONLY for the three caller-owned strings listed in the header comment.
 * Passing an accessor's borrowed pointer here corrupts the handle. */
void cktimg_string_free(char *s);

/* The parse report, BORROWED from the handle and valid until
 * cktimg_sch_free(). Never NULL for a live handle — a clean netlist reports
 * the empty string. NULL only for a NULL handle. */
const char *cktimg_report(const CktimgSch *sch);

/* Render the handle's schematic to JSON in YOUR buffer.
 *
 * Returns the byte length the document needs, EXCLUDING the NUL terminator,
 * always, whatever `cap` is. When `buf` is non-NULL and `cap > 0`, writes
 * min(needed, cap - 1) bytes plus a NUL, so `buf` is always a valid C string.
 * Returns 0 for a NULL handle and writes nothing.
 *
 *   size_t n = cktimg_json(sch, NULL, 0);
 *   char  *b = malloc(n + 1);
 *   cktimg_json(sch, b, n + 1);
 *
 * Truncation happened exactly when the return value is >= cap.
 */
size_t cktimg_json(const CktimgSch *sch, char *buf, size_t cap);

/* ---------------------------------------------------------------------------
 * Devices
 * ------------------------------------------------------------------------- */

/* Number of devices. 0 on a NULL handle. */
size_t cktimg_device_count(const CktimgSch *sch);

/* Refdes (e.g. "m1"), class (e.g. "nmos"), value (e.g. "5k", may be the empty
 * string — which is not the same as NULL).
 * BORROWED; valid until cktimg_sch_free(). NULL on a NULL handle or an
 * out-of-range index. */
const char *cktimg_device_name(const CktimgSch *sch, size_t d);
const char *cktimg_device_class(const CktimgSch *sch, size_t d);
const char *cktimg_device_value(const CktimgSch *sch, size_t d);

/* Rotation in quarter turns clockwise, 0..3 (multiply by 90 degrees). 0 on a
 * miss, which is indistinguishable from an unrotated device — check
 * cktimg_device_count() first if that matters. */
uint8_t cktimg_device_rot(const CktimgSch *sch, size_t d);

/* Whether the device is mirrored about the vertical axis, applied BEFORE
 * rotation. false on a miss. */
bool cktimg_device_mirror(const CktimgSch *sch, size_t d);

/* Placed device origin. Writes through x and y (either may be NULL) and
 * returns true; returns false and writes nothing on a miss. */
bool cktimg_device_pos(const CktimgSch *sch, size_t d, int32_t *x, int32_t *y);

/* Collision-avoided anchor for the device's refdes label: LEFT EDGE ON THE
 * BASELINE. Draw the text at this point and add nothing — this is the same
 * answer the bundled renderers use, so your output matches theirs.
 *
 * Anchors for all devices are computed on the first call and cached in the
 * handle, because each label dodges the ones already placed and there is no
 * per-device answer to give. Same convention as cktimg_device_pos(); false on
 * a miss or if the one-time computation ran out of memory. */
bool cktimg_device_refdes_anchor(const CktimgSch *sch, size_t d, int32_t *x,
                                 int32_t *y);

/* ---------------------------------------------------------------------------
 * Pins (per device, in SPICE node order)
 * ------------------------------------------------------------------------- */

size_t cktimg_device_pin_count(const CktimgSch *sch, size_t d);

/* Terminal name (e.g. "g"; may be empty). BORROWED; NULL on a miss. */
const char *cktimg_pin_term(const CktimgSch *sch, size_t d, size_t p);

/* Connected net name. BORROWED; NULL on a miss OR on an unconnected pin —
 * those two are deliberately not distinguished. */
const char *cktimg_pin_net(const CktimgSch *sch, size_t d, size_t p);

/* Absolute pin coordinates; same convention as cktimg_device_pos(). */
bool cktimg_pin_xy(const CktimgSch *sch, size_t d, size_t p, int32_t *x,
                   int32_t *y);

/* ---------------------------------------------------------------------------
 * Nets
 * ------------------------------------------------------------------------- */

size_t cktimg_net_count(const CktimgSch *sch);

/* Net name. BORROWED; NULL on a miss. */
const char *cktimg_net_name(const CktimgSch *sch, size_t n);

/* ---------------------------------------------------------------------------
 * Wires (routed net geometry)
 *
 * WIRE INDEX IS NET INDEX: cktimg_wire_count() == cktimg_net_count(), and a
 * net the router did not draw reports 0 segments rather than being omitted.
 * Filtering would need a shadow index; skipping a zero-segment wire costs you
 * one comparison.
 * ------------------------------------------------------------------------- */

size_t cktimg_wire_count(const CktimgSch *sch);

/* Net this wire belongs to — identical to cktimg_net_name(sch, w).
 * BORROWED; NULL on a miss. */
const char *cktimg_wire_net(const CktimgSch *sch, size_t w);

/* Number of polyline segments in wire w. 0 on a miss or an unrouted net. */
size_t cktimg_wire_segment_count(const CktimgSch *sch, size_t w);

/* Points of segment s of wire w, ZERO-COPY.
 *
 * Returns the point count and, when `xy` is non-NULL, writes a BORROWED
 * pointer to a flat x0,y0,x1,y1,... array of 2*count int32 values aimed
 * straight at the router's own point array. Valid until cktimg_sch_free();
 * do not free it.
 *
 * On a miss returns 0 and writes NULL — the write happens even on a miss, so
 * an uninitialized variable still ends up defined.
 *
 * A real segment has >= 2 points and is Manhattan: consecutive points always
 * share an x or a y.
 */
size_t cktimg_wire_segment_points(const CktimgSch *sch, size_t w, size_t s,
                                  const int32_t **xy);

/* ---------------------------------------------------------------------------
 * Junctions (connection dots)
 * ------------------------------------------------------------------------- */

/* Points where three or more same-net arms meet. A two-arm corner is not a
 * junction and gets no dot. 0 on a NULL handle. */
size_t cktimg_junction_count(const CktimgSch *sch);

/* Junction j's coordinates; same convention as cktimg_device_pos(). */
bool cktimg_junction(const CktimgSch *sch, size_t j, int32_t *x, int32_t *y);

/* ---------------------------------------------------------------------------
 * Labels (nets the router could not draw)
 *
 * A label is emitted only after the lattice search has PROVEN no tree exists,
 * so it is a real guarantee and not a shape gap. Draw them, or your rendering
 * silently omits connectivity the schematic actually has.
 * ------------------------------------------------------------------------- */

size_t cktimg_label_count(const CktimgSch *sch);

/* Name of the net this label stands in for. BORROWED; NULL on a miss. */
const char *cktimg_label_net(const CktimgSch *sch, size_t l);

/* Label anchor — left edge on the baseline, as with the refdes anchor. Same
 * convention as cktimg_device_pos(). */
bool cktimg_label_xy(const CktimgSch *sch, size_t l, int32_t *x, int32_t *y);

/* ---------------------------------------------------------------------------
 * Drawing: bounds and symbol geometry
 *
 * Everything here comes back PLACED — oriented by the device's mirror and
 * rotation, then translated to its position. You never apply a transform, and
 * therefore never apply the wrong one.
 * ------------------------------------------------------------------------- */

/* Bounding box over device bodies, wire vertices, junctions and labels.
 *
 * Writes the two corners (each pointer may be NULL) and returns true; returns
 * false and writes nothing for a NULL handle or an empty layout.
 *
 * EXCLUDES render padding (add your own) and excludes refdes / group label
 * text. `min` is top-left: y increases downwards. */
bool cktimg_bounds(const CktimgSch *sch, int32_t *min_x, int32_t *min_y,
                   int32_t *max_x, int32_t *max_y);

/* Placed bounding box of one device's symbol — the exact box the router
 * blocked against. Same convention as cktimg_bounds(). */
bool cktimg_device_bounds(const CktimgSch *sch, size_t d, int32_t *min_x,
                          int32_t *min_y, int32_t *max_x, int32_t *max_y);

/* Which primitive a draw op is. CKTIMG_OP_NONE is returned for a miss, so a
 * switch has a defined arm instead of mistaking a miss for a line. */
typedef enum {
  CKTIMG_OP_LINE = 0,
  CKTIMG_OP_POLYLINE = 1,
  CKTIMG_OP_CIRCLE = 2,
  CKTIMG_OP_TEXT = 3,
  CKTIMG_OP_NONE = 255
} CktimgOpKind;

/* Number of draw primitives in device d's symbol body, 0 on a miss. Ops are
 * in stroke order: emit them in sequence and you reproduce our output. */
size_t cktimg_device_op_count(const CktimgSch *sch, size_t d);

/* Kind of op o of device d, as a CktimgOpKind. CKTIMG_OP_NONE on a miss. */
uint8_t cktimg_device_op_kind(const CktimgSch *sch, size_t d, size_t o);

/* Placed points of a LINE or POLYLINE op, written into YOUR buffer.
 *
 * Returns the op's point count (2 for a line) always, whatever `cap` is, so
 * the two-call sizing idiom works. When `xy` is non-NULL, writes
 * min(count, cap) points as a flat x0,y0,x1,y1,... array of 2*n int32 values.
 *
 * These are the only points in this API that are copied rather than borrowed:
 * a transformed point does not exist anywhere in memory to point at.
 *
 * Returns 0 on a miss or on a circle/text op — use the extractors below.
 */
size_t cktimg_device_op_points(const CktimgSch *sch, size_t d, size_t o,
                               int32_t *xy, size_t cap);

/* Placed centre and radius of a CIRCLE op. The centre is transformed; the
 * radius is not, because rotation and mirroring preserve it and there is no
 * scaling in this coordinate system. Any out-pointer may be NULL.
 * false on a miss or a non-circle op. */
bool cktimg_device_op_circle(const CktimgSch *sch, size_t d, size_t o,
                             int32_t *cx, int32_t *cy, int32_t *r);

/* Text of a TEXT op (pin label or block title), BORROWED and valid until
 * cktimg_sch_free(). NULL on a miss or a non-text op.
 *
 * x and y receive the glyph CENTRE, placed; size receives the font size in
 * grid units. Any out-pointer may be NULL.
 *
 * DRAW SYMBOL TEXT UPRIGHT regardless of cktimg_device_rot(): orientation
 * moves where it sits, never how it reads, or a mirrored flip-flop renders
 * "KLC". Force the glyph box to 0.6 * size per character and it matches the
 * box the placer collided against.
 */
const char *cktimg_device_op_text(const CktimgSch *sch, size_t d, size_t o,
                                  int32_t *x, int32_t *y, uint8_t *size);

/* ---------------------------------------------------------------------------
 * Host symbol registration
 *
 * Register a symbol whose pins and geometry are only known at run time: an
 * editor's project symbols, a testbench DUT. Instances resolve by name
 * wherever a builtin would, so `XDUT in out vdd gnd my_opamp` places
 * my_opamp instead of flattening or skipping it.
 *
 *   cktimg_class_begin("my_opamp");
 *   cktimg_class_pin("in",  CKTIMG_ROLE_PASSIVE, -20,   0);
 *   cktimg_class_pin("out", CKTIMG_ROLE_PASSIVE,  20,   0);
 *   cktimg_class_pin("vdd", CKTIMG_ROLE_PASSIVE, -20, -12);
 *   size_t idx = cktimg_class_register();
 *
 * Supply no geometry and the symbol is drawn as a labelled box — outline, pin
 * names, class name as the title — the same body the builtin flip-flops use.
 * Supply geometry and it is used verbatim, so the output matches the editor's
 * own canvas.
 *
 * Coordinates are in the canonical device frame: origin at the device centre,
 * y downwards, bipole terminals conventionally at x = -20 and x = +20.
 *
 * begin/pin/.../register is ONE TRANSACTION on ONE process-global builder.
 * Calls are serialized internally, but two threads interleaving DIFFERENT
 * classes will interleave their pins into one class. Build a class from one
 * thread; registering everything before you place anything is the pattern
 * that needs no synchronization at all.
 *
 * Every function returns false on a NULL string, an unknown role, or no class
 * in progress.
 * ------------------------------------------------------------------------- */

/* Terminal role. Drives PLACEMENT, not rendering: control terminals attract
 * driving nets, conducting ones join the spine walk. Use PASSIVE when in
 * doubt. */
typedef enum {
  CKTIMG_ROLE_PASSIVE = 0,
  CKTIMG_ROLE_DRAIN = 1,
  CKTIMG_ROLE_SOURCE = 2,
  CKTIMG_ROLE_GATE = 3,
  CKTIMG_ROLE_BULK = 4,
  CKTIMG_ROLE_COLLECTOR = 5,
  CKTIMG_ROLE_BASE = 6,
  CKTIMG_ROLE_EMITTER = 7,
  CKTIMG_ROLE_ANODE = 8,
  CKTIMG_ROLE_CATHODE = 9
} CktimgRole;

/* Begin a class, discarding any unfinished one. The name is copied and folded
 * to lowercase, so instances resolve case-insensitively. */
bool cktimg_class_begin(const char *name);

/* Append a terminal. PIN ORDER IS THE NODE ORDER instances are read in. */
bool cktimg_class_pin(const char *name, uint8_t role, int32_t x, int32_t y);

/* Optional body geometry. Omit all of these to get the generated box. */
bool cktimg_class_line(int32_t x0, int32_t y0, int32_t x1, int32_t y1);
bool cktimg_class_circle(int32_t cx, int32_t cy, int32_t r);

/* Polyline from a flat x0,y0,x1,y1,... array of 2*count int32 values. The
 * points are COPIED; you keep ownership of xy and may free it immediately.
 * A closed shape repeats its first point as its last.
 * false on a NULL xy, count < 2, or no class in progress. */
bool cktimg_class_polyline(const int32_t *xy, size_t count);

/* Upright text centred on (x, y): a pin label or a block title. The string is
 * copied. Orientation moves where it sits, never how it reads. */
bool cktimg_class_text(const char *s, int32_t x, int32_t y, uint8_t size);

/* Register the class under construction; returns its index, or SIZE_MAX on
 * error (nothing begun, no pins, a name that shadows a builtin, a name
 * already registered with DIFFERENT terminals, or out of memory).
 *
 * An exact repeat — same name, same terminals in the same order — is
 * idempotent and returns the existing index without allocating, so a host may
 * re-scan its symbol library on every parse.
 *
 * A returned index NEVER changes meaning: registration is append-only, with
 * no removal and no re-sorting, because a schematic placed earlier may still
 * hold it.
 *
 * Consumes the in-progress class either way; a failed registration leaves
 * nothing for the next call to inherit. */
size_t cktimg_class_register(void);

#ifdef __cplusplus
}
#endif

#endif /* CKTIMG_H */
