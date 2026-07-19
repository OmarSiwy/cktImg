/* cktimg C API — SPICE/netlist text in, placed-schematic JSON out.
 *
 * Link against the `cktimg_c` cdylib or staticlib. All returned strings are
 * NUL-terminated, allocated by Rust, and MUST be released with
 * cktimg_string_free() — never free(3).
 */
#ifndef CKTIMG_H
#define CKTIMG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Render NUL-terminated SPICE text to a JSON document (devices, nets, wires,
 * junctions with placed coordinates).
 *
 * Returns a newly allocated JSON string, or NULL if `src` is NULL, is not
 * valid UTF-8, or an internal error occurred. Free with cktimg_string_free().
 */
char *cktimg_run_json(const char *src);

/* Like cktimg_run_json(), additionally writing the parse report to
 * *out_report: one text line per ignored/skipped source line, empty string
 * for a clean netlist. Pass NULL for out_report to skip the report.
 *
 * On failure returns NULL and sets *out_report to NULL (when non-NULL).
 * Free both returned strings with cktimg_string_free().
 */
char *cktimg_run_json_with_report(const char *src, char **out_report);

/* Free a string returned by this library. NULL is a no-op. This is the only
 * valid way to release such strings (Rust allocator, not malloc).
 */
void cktimg_string_free(char *s);

/* ---------------------------------------------------------------------------
 * Opaque-handle accessor API — parse+place once, then walk the resolved
 * schematic to drive your own backend.
 *
 * Lifetime rules:
 *   - const char* returned by accessors is BORROWED from the handle: valid
 *     until cktimg_sch_free(), never pass it to cktimg_string_free()/free().
 *   - Same for the point array from cktimg_wire_segment_points().
 *   - Out-of-range indices and NULL handles are safe: accessors return
 *     NULL / 0 / false and never crash.
 *   - Out-parameters (x, y, xy, out_report) may be NULL to skip that output.
 * ------------------------------------------------------------------------- */

/* Opaque placed-schematic handle. */
typedef struct CktimgSch CktimgSch;

/* Parse and place NUL-terminated SPICE text. Returns a handle, or NULL if
 * src is NULL, not valid UTF-8, or an internal error occurred.
 * Free with cktimg_sch_free().
 */
CktimgSch *cktimg_parse_place(const char *src);

/* Like cktimg_parse_place(), additionally writing the parse report to
 * *out_report (same format and ownership as cktimg_run_json_with_report:
 * free it with cktimg_string_free). On failure returns NULL and sets
 * *out_report to NULL (when non-NULL).
 */
CktimgSch *cktimg_parse_place_with_report(const char *src, char **out_report);

/* Free a schematic handle. NULL is a no-op. Invalidates every borrowed
 * string / point pointer obtained from this handle.
 */
void cktimg_sch_free(CktimgSch *sch);

/* --- Devices ----------------------------------------------------------- */

size_t cktimg_device_count(const CktimgSch *sch);

/* Refdes (e.g. "m1"), class (e.g. "nmos"), value (e.g. "5k", may be empty).
 * BORROWED; NULL on out-of-range index. */
const char *cktimg_device_name(const CktimgSch *sch, size_t d);
const char *cktimg_device_class(const CktimgSch *sch, size_t d);
const char *cktimg_device_value(const CktimgSch *sch, size_t d);

/* Rotation in quarter turns, 0..3 (multiply by 90 degrees). 0 on miss. */
uint8_t cktimg_device_rot(const CktimgSch *sch, size_t d);

/* Whether the device is mirrored. false on miss. */
bool cktimg_device_mirror(const CktimgSch *sch, size_t d);

/* Placed position. Writes *x/*y and returns true when placed; returns false
 * (nothing written) for an unplaced device or a miss. */
bool cktimg_device_pos(const CktimgSch *sch, size_t d, int32_t *x, int32_t *y);

/* --- Pins (per device) ------------------------------------------------- */

size_t cktimg_device_pin_count(const CktimgSch *sch, size_t d);

/* Terminal name (e.g. "g"; may be empty). BORROWED; NULL on miss. */
const char *cktimg_pin_term(const CktimgSch *sch, size_t d, size_t p);

/* Connected net name. BORROWED; NULL on miss OR unconnected pin. */
const char *cktimg_pin_net(const CktimgSch *sch, size_t d, size_t p);

/* Pin coordinates; same convention as cktimg_device_pos(). */
bool cktimg_pin_xy(const CktimgSch *sch, size_t d, size_t p, int32_t *x,
                   int32_t *y);

/* --- Nets -------------------------------------------------------------- */

size_t cktimg_net_count(const CktimgSch *sch);

/* Net name. BORROWED; NULL on miss. */
const char *cktimg_net_name(const CktimgSch *sch, size_t n);

/* --- Wires (routed net geometry) --------------------------------------- */

size_t cktimg_wire_count(const CktimgSch *sch);

/* Net this wire belongs to. BORROWED; NULL on miss. */
const char *cktimg_wire_net(const CktimgSch *sch, size_t w);

/* Number of polyline segments in wire w. 0 on miss. */
size_t cktimg_wire_segment_count(const CktimgSch *sch, size_t w);

/* Points of segment s of wire w. Returns the point count and writes to *xy
 * a BORROWED pointer to a flat array x0,y0,x1,y1,... of 2*count int32
 * values (zero-copy view into the handle). On miss returns 0 and writes
 * NULL. Segments have >= 2 points; zero-length segments are possible.
 */
size_t cktimg_wire_segment_points(const CktimgSch *sch, size_t w, size_t s,
                                  const int32_t **xy);

/* --- Junctions (wire crossing dots) ------------------------------------ */

size_t cktimg_junction_count(const CktimgSch *sch);

/* Junction j's coordinates; same convention as cktimg_device_pos(). */
bool cktimg_junction(const CktimgSch *sch, size_t j, int32_t *x, int32_t *y);

#ifdef __cplusplus
}
#endif

#endif /* CKTIMG_H */
