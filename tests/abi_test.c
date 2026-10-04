/* The C ABI as a C program uses it: register classes, place, walk. */
#include "cktimg.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c)                                                               \
  do {                                                                         \
    if (!(c)) {                                                                \
      fprintf(stderr, "abi_test.c:%d: %s\n", __LINE__, #c);                    \
      failures++;                                                              \
    }                                                                          \
  } while (0)

static const char *cs_stage = "CS stage\n"
                              ".model nch nmos level=1\n"
                              "Vdd vdd 0 1.8\n"
                              "Vin in 0 dc 0.8 ac 1\n"
                              "Rd vdd out 5k\n"
                              "M1 out in 0 0 nch\n";

/* Is (x, y) on some segment of net n's wire? */
static int on_wire(const CktimgSch *s, size_t n, int32_t x, int32_t y) {
  for (size_t k = 0; k < cktimg_wire_segment_count(s, n); k++) {
    const int32_t *xy;
    size_t m = cktimg_wire_segment_points(s, n, k, &xy);
    for (size_t i = 0; i + 1 < m; i++) {
      int32_t x0 = xy[2 * i], y0 = xy[2 * i + 1], x1 = xy[2 * i + 2], y1 = xy[2 * i + 3];
      int32_t lx = x0 < x1 ? x0 : x1, hx = x0 < x1 ? x1 : x0;
      int32_t ly = y0 < y1 ? y0 : y1, hy = y0 < y1 ? y1 : y0;
      if (x >= lx && x <= hx && y >= ly && y <= hy) return 1;
    }
  }
  return 0;
}

int main(void) {
  /* NULL is safe everywhere. */
  CHECK(cktimg_device_count(NULL) == 0);
  CHECK(cktimg_device_name(NULL, 0) == NULL);
  CHECK(cktimg_parse_place(NULL, cs_stage, NULL, NULL) == NULL);
  cktimg_sch_free(NULL);
  cktimg_lib_free(NULL);

  CktimgLib *lib = cktimg_lib_new();
  CHECK(lib != NULL);

  /* Classes by hand: a resistor, a source, an NMOS, and the terminal symbols. */
  CktimgTerminal two[] = {{"a", -20, 0, 0}, {"b", 20, 0, 0}};
  int32_t zig[] = {-10, 0, -8, 6, -4, -6, 0, 6, 4, -6, 8, 6, 10, 0};
  int32_t l1[] = {-20, 0, -10, 0}, l2[] = {10, 0, 20, 0};
  CktimgOp res[] = {{CKTIMG_OP_LINE, l1, 2, 0, NULL, 0},
                    {CKTIMG_OP_LINE, l2, 2, 0, NULL, 0},
                    {CKTIMG_OP_POLYLINE, zig, 7, 0, NULL, 0}};
  size_t r = cktimg_lib_add(lib, "res", CKTIMG_ROLE_NONE, two, 2, res, 3);
  CHECK(r == 0);
  CHECK(cktimg_lib_add(lib, "RES", CKTIMG_ROLE_NONE, two, 2, res, 3) == r); /* idempotent */
  CktimgTerminal moved[] = {{"a", -30, 0, 0}, {"b", 20, 0, 0}};
  CHECK(cktimg_lib_add(lib, "res", CKTIMG_ROLE_NONE, moved, 2, NULL, 0) == SIZE_MAX);
  int32_t c0[] = {0, 0};
  CktimgOp src[] = {{CKTIMG_OP_CIRCLE, c0, 1, 9, NULL, 0}};
  CHECK(cktimg_lib_add(lib, "vsource", CKTIMG_ROLE_NONE, two, 2, src, 1) != SIZE_MAX);
  CktimgTerminal mos[] = {{"d", 20, 0, 0}, {"g", 0, -20, 0}, {"s", -20, 0, 0}};
  CHECK(cktimg_lib_add(lib, "nmos", CKTIMG_ROLE_NONE, mos, 3, NULL, 0) != SIZE_MAX); /* a box */
  CktimgTerminal pin[] = {{"p", 0, 0, 0}};
  int32_t bar[] = {-9, 0, 9, 0};
  CktimgOp rail[] = {{CKTIMG_OP_LINE, bar, 2, 0, NULL, 0}};
  CktimgOp port[] = {{CKTIMG_OP_CIRCLE, c0, 1, 3, NULL, 0}};
  CHECK(cktimg_lib_add(lib, "vdd", CKTIMG_ROLE_POWER_RAIL, pin, 1, rail, 1) != SIZE_MAX);
  CHECK(cktimg_lib_add(lib, "gnd", CKTIMG_ROLE_GROUND_RAIL, pin, 1, rail, 1) != SIZE_MAX);
  CHECK(cktimg_lib_add(lib, "ipin", CKTIMG_ROLE_INPUT_PORT, pin, 1, port, 1) != SIZE_MAX);
  CHECK(cktimg_lib_add(lib, "opin", CKTIMG_ROLE_OUTPUT_PORT, pin, 1, port, 1) != SIZE_MAX);

  char *report = NULL;
  CktimgSch *s = cktimg_parse_place(lib, cs_stage, ".{ .layout = .{ .stack = 0.5 }, .typo = 1 }", &report);
  CHECK(s != NULL);
  CHECK(report != NULL && strstr(report, "typo") != NULL);
  cktimg_string_free(report);
  if (!s) return 1;
  CHECK(strstr(cktimg_report(s), "typo") != NULL);

  /* Four netlist devices, plus terminal symbols. */
  size_t n = cktimg_device_count(s);
  CHECK(n > 4);
  CHECK(strcmp(cktimg_device_name(s, 0), "vdd") == 0 || strcmp(cktimg_device_name(s, 0), "rd") == 0);
  int found_m1 = 0, rails = 0;
  for (size_t d = 0; d < n; d++) {
    if (strcmp(cktimg_device_name(s, d), "m1") == 0) {
      found_m1 = 1;
      CHECK(strcmp(cktimg_device_class(s, d), "nmos") == 0);
      CHECK(cktimg_device_pin_count(s, d) == 4); /* d g s b: the bulk has no terminal */
      CHECK(strcmp(cktimg_pin_term(s, d, 1), "g") == 0);
      CHECK(strcmp(cktimg_pin_net(s, d, 1), "in") == 0);
      /* The drain is on the out wire. */
      int32_t x, y;
      CHECK(cktimg_pin_xy(s, d, 0, &x, &y));
      size_t out = SIZE_MAX;
      for (size_t k = 0; k < cktimg_net_count(s); k++)
        if (strcmp(cktimg_net_name(s, k), "out") == 0) out = k;
      CHECK(out != SIZE_MAX && on_wire(s, out, x, y));
      int32_t a, b;
      CHECK(cktimg_device_refdes_anchor(s, d, &a, &b));
    }
    if (cktimg_device_role(s, d) == CKTIMG_ROLE_POWER_RAIL) rails++;
  }
  CHECK(found_m1);
  CHECK(rails == 2); /* the circuit's and the Vdd island's */
  CHECK(cktimg_device_name(s, n) == NULL);
  CHECK(cktimg_junction_count(s) >= 1);

  /* Placed strokes of the resistor: two points in a line op. */
  for (size_t d = 0; d < n; d++) {
    if (strcmp(cktimg_device_class(s, d), "res") != 0) continue;
    CHECK(cktimg_device_op_count(s, d) == 3);
    CHECK(cktimg_device_op_kind(s, d, 0) == CKTIMG_OP_LINE);
    int32_t pts[4];
    CHECK(cktimg_device_op_points(s, d, 0, pts, 2) == 2);
    CHECK(cktimg_device_op_points(s, d, 2, NULL, 0) == 7);
    CHECK(cktimg_device_op_kind(s, d, 9) == CKTIMG_OP_NONE);
  }

  /* JSON: the two-call idiom. */
  size_t need = cktimg_json(s, NULL, 0);
  CHECK(need > 100);
  char *buf = malloc(need + 1);
  CHECK(cktimg_json(s, buf, need + 1) == need);
  CHECK(strlen(buf) == need && buf[0] == '{' && strstr(buf, "\"nmos\"") != NULL);
  free(buf);
  char small[8];
  cktimg_json(s, small, sizeof small);
  CHECK(strlen(small) == 7);

  /* Lint: nmos is a generated box? No — it was added; the box is its body. */
  size_t errors = 99;
  size_t lint_len = cktimg_lint(s, NULL, 0, &errors);
  CHECK(errors == 0);
  (void)lint_len;

  int32_t x0, y0, x1, y1;
  CHECK(cktimg_bounds(s, &x0, &y0, &x1, &y1) && x0 < x1 && y0 < y1);
  cktimg_sch_free(s);

  /* A netlist the parser rejects: NULL and a reason. */
  char *why = NULL;
  CHECK(cktimg_parse_place(lib, "t\nY1 a b sub\n", NULL, &why) == NULL);
  CHECK(why != NULL && strstr(why, "line 2") != NULL);
  cktimg_string_free(why);

  char *doc = cktimg_run_json(lib, cs_stage, NULL, NULL);
  CHECK(doc != NULL && doc[0] == '{');
  cktimg_string_free(doc);

  cktimg_lib_free(lib);
  if (failures) fprintf(stderr, "%d failure(s)\n", failures);
  return failures != 0;
}
