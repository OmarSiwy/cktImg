//! `Placed` as one JSON document — what the C ABI's `cktimg_json` streams for
//! a consumer that would rather parse one document than walk the accessors.
//! Same shape as cktImg's:
//!
//! ```json
//! { "devices": [ { "name": "m1", "class": "nmos", "value": "nch", "rot": 3, "mirror": false,
//!                  "pos": [x, y], "pins": [ { "term": "d", "net": "out", "xy": [x, y] } ] } ],
//!   "nets": [ "out", … ],
//!   "wires": [ { "net": "out", "segments": [ [ [x, y], [x, y] ] ] } ],
//!   "junctions": [ [x, y] ], "labels": [ { "net": "vb", "at": [x, y], "side": "left" } ],
//!   "no_connects": [ [x, y] ] }
//! ```
//!
//! Integers only; streamed, nothing allocated.

const std = @import("std");
const Writer = std.Io.Writer;
const library = @import("library.zig");
const placed_mod = @import("placed.zig");

const Pt = library.Pt;
const Library = library.Library;
const Placed = placed_mod.Placed;

pub fn write(p: *const Placed, lib: *const Library, w: *Writer) Writer.Error!void {
    try w.writeAll("{\n  \"devices\": [");
    for (0..p.deviceCount()) |d| {
        const class = lib.at(p.dev_class[d]);
        try w.writeAll(if (d == 0) "\n    { \"name\": " else ",\n    { \"name\": ");
        try string(w, p.dev_name[d]);
        try w.writeAll(", \"class\": ");
        try string(w, class.name);
        try w.writeAll(", \"value\": ");
        try string(w, p.dev_value[d]);
        try w.print(", \"rot\": {d}, \"mirror\": {}, \"pos\": ", .{ p.dev_orient[d].rot, p.dev_orient[d].mirror });
        try point(w, p.dev_pos[d]);
        try w.writeAll(", \"pins\": [");
        const lo, const hi = p.pinRange(d);
        for (lo..hi) |pin| {
            const k = pin - lo;
            try w.writeAll(if (pin == lo) "{ \"term\": " else ", { \"term\": ");
            try string(w, if (k < class.terminals.len) class.terminals[k].name else "");
            try w.writeAll(", \"net\": ");
            if (p.pin_net[pin] == placed_mod.no_net) try w.writeAll("null") else try string(w, p.net_name[p.pin_net[pin]]);
            try w.writeAll(", \"xy\": ");
            try point(w, p.pin_xy[pin]);
            try w.writeAll(" }");
        }
        try w.writeAll("] }");
    }
    try w.writeAll("\n  ],\n  \"nets\": [");
    for (p.net_name, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try string(w, n);
    }
    try w.writeAll("],\n  \"wires\": [");
    var first = true;
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        if (it.k == it.end) continue;
        try w.writeAll(if (first) "\n    { \"net\": " else ",\n    { \"net\": ");
        first = false;
        try string(w, p.net_name[n]);
        try w.writeAll(", \"segments\": [");
        var k: usize = 0;
        while (it.next()) |poly| : (k += 1) {
            try w.writeAll(if (k == 0) "[" else ", [");
            for (poly, 0..) |q, i| {
                if (i > 0) try w.writeAll(", ");
                try point(w, q);
            }
            try w.writeAll("]");
        }
        try w.writeAll("] }");
    }
    try w.writeAll("\n  ],\n  \"junctions\": [");
    try points(w, p.junctions);
    try w.writeAll("],\n  \"labels\": [");
    for (p.labels, 0..) |l, i| {
        try w.writeAll(if (i == 0) "{ \"net\": " else ", { \"net\": ");
        try string(w, p.net_name[l.net]);
        try w.writeAll(", \"at\": ");
        try point(w, l.at);
        try w.print(", \"side\": \"{s}\" }}", .{@tagName(l.side)});
    }
    try w.writeAll("],\n  \"no_connects\": [");
    try points(w, p.no_connects);
    try w.writeAll("]\n}\n");
}

fn point(w: *Writer, p: Pt) Writer.Error!void {
    try w.print("[{d}, {d}]", .{ p.x, p.y });
}

fn points(w: *Writer, ps: []const Pt) Writer.Error!void {
    for (ps, 0..) |q, i| {
        if (i > 0) try w.writeAll(", ");
        try point(w, q);
    }
}

/// A JSON string: quotes, backslashes and control bytes escaped.
fn string(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...0x09, 0x0b...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "json: strings are escaped" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try string(&w, "a\"b\\c\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u0001\"", w.buffered());
}
