//! The HTML index for the dev gallery. **Not** part of the library.
//!
//! One self-contained `index.html` that embeds every rendered fixture by `<img>`
//! reference and shows, per fixture, the numbers that make a regression obvious at a
//! glance: device count, net count, and — first, because it is the first term of the
//! selection key — how many nets fell back to a label.
//!
//! ## Why a page and not a diff
//!
//! Golden JSON comparison (ARCHITECTURE.md §Verification) catches *any* change,
//! including the ones that are fine. This page catches the other class of problem: the
//! output that is byte-stable and still wrong, where the router is individually
//! correct at every function and the drawing is unreadable. Nothing but looking at all
//! twenty-one fixtures side by side finds that, and nobody looks at twenty-one files
//! one at a time.
//!
//! ## Public API only
//!
//! Like `svg.zig`, this consumes exactly `@import("cktimg")` and nothing privileged.
//! Every count on the page comes from an accessor a third-party consumer also has. If
//! a statistic worth showing cannot be obtained that way, the missing accessor is an
//! **API bug** to fix in `src/` — the gallery does not get a private back channel,
//! because the gallery being an ordinary consumer is the entire thing it proves.
//!
//! ## No template engine, no assets
//!
//! The page is emitted by `print` calls into a `*std.Io.Writer`, with CSS inlined in a
//! single `<style>` block. A dev tool that needs a build step, a dependency, or a
//! sidecar directory of assets is a dev tool that stops working in six months.

const std = @import("std");
const ckt = @import("cktimg");

const Writer = std.Io.Writer;

/// One rendered fixture, as the index needs to describe it.
///
/// Every field is either a borrowed slice owned by the caller (valid for the duration
/// of the `writeIndex` call) or a plain count. Nothing here is owned by this module.
pub const Entry = struct {
    /// Fixture name, without directory or extension. Used as the card heading.
    /// Borrowed from the caller's directory walk.
    name: []const u8,
    /// Path to the emitted SVG, relative to the index file, for the `<img src>`.
    /// Borrowed.
    svg_path: []const u8,
    /// Content bounds in host grid units, so the page can size a thumbnail without
    /// parsing the SVG back.
    width: i32,
    height: i32,
    /// Devices placed.
    devices: usize,
    /// Nets in the schematic.
    nets: usize,
    /// Wire segments the router drew. Read next to `labels`: segments present with
    /// labels absent is the shape of a fixture that actually routed.
    wires: usize,
    /// Nets that routing could not connect and dropped to a name label. Shown first
    /// and highlighted: it is the first term of the selection key, so any nonzero
    /// value is the most interesting fact about the drawing.
    labels: usize,
    /// Cards the front end declined to represent. Split the way `Report` splits them,
    /// because "ignored by design" and "skipped as a limitation" mean different things
    /// to whoever is reading the page.
    ignored: usize,
    skipped: usize,
};

/// Emit the complete `index.html` for `entries`.
///
/// `entries` is rendered in the order given — the caller's directory walk is already
/// sorted, and re-sorting here would put the page's order out of step with the
/// filesystem's for no gain. Borrowed; not retained past the call.
///
/// Writes an entire document: doctype, inline `<style>`, a summary header with the
/// totals across all fixtures, then one card per entry. Streams to `w`, allocating
/// nothing.
///
/// An empty `entries` produces a valid page saying so, rather than an empty file —
/// "the fixture directory was empty" and "the renderer crashed" should not look the
/// same to whoever opens the result.
///
/// Errors: `std.Io.Writer.Error` only, propagated from `w`.
pub fn writeIndex(entries: []const Entry, w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<title>cktImg gallery</title>
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\
    );
    try writeStyle(w);
    try w.writeAll("</head><body>\n");
    try writeSummary(entries, w);
    if (entries.len == 0) {
        // "Nothing to draw" and "the renderer crashed" must not look the same.
        try w.writeAll("<p class=\"empty\">No fixtures found.</p>\n");
    } else {
        try w.writeAll("<main>\n");
        for (entries) |e| try writeCard(e, w);
        try w.writeAll("</main>\n");
    }
    try w.writeAll("</body></html>\n");
}

/// Emit the inline `<style>` block.
///
/// A dark-background grid of cards, because schematics are drawn in dark strokes and a
/// light page hides a stroke-color regression. Split out only so `writeIndex` reads as
/// structure rather than as a wall of CSS.
pub fn writeStyle(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\<style>
        \\:root{color-scheme:dark}
        \\body{background:#15181c;color:#dfe3e8;font:14px/1.5 system-ui,sans-serif;margin:2rem}
        \\h1{font-size:1.4rem;margin:0 0 .25rem}
        \\.totals{color:#9aa4b1;margin:0 0 1.5rem}
        \\.totals b{color:#dfe3e8}
        \\.empty{color:#9aa4b1}
        \\main{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:1.25rem}
        \\figure{margin:0;background:#1e2228;border:1px solid #2c323a;border-radius:8px;padding:.75rem}
        \\figure h2{font-size:1rem;margin:0 0 .5rem;font-weight:600}
        \\a.thumb{display:block;background:#fff;border-radius:4px;overflow:hidden}
        \\img{display:block;width:100%;height:auto}
        \\dl{display:flex;flex-wrap:wrap;gap:.25rem .9rem;margin:.6rem 0 0;color:#9aa4b1;font-size:12px}
        \\dt{display:inline}
        \\dd{display:inline;margin:0 0 0 .25rem;color:#dfe3e8}
        \\.bad dd,.bad dt{color:#ff8a80}
        \\</style>
        \\
    );
}

/// Emit the header: fixture count and the summed device, net and label totals.
///
/// The total label count is the single number worth watching between runs; a change
/// there means the placer's first-priority objective moved.
pub fn writeSummary(entries: []const Entry, w: *Writer) Writer.Error!void {
    var devices: usize = 0;
    var nets: usize = 0;
    var labels: usize = 0;
    var ignored: usize = 0;
    var skipped: usize = 0;
    for (entries) |e| {
        devices += e.devices;
        nets += e.nets;
        labels += e.labels;
        ignored += e.ignored;
        skipped += e.skipped;
    }
    try w.print("<h1>cktImg gallery — {d} circuits</h1>\n", .{entries.len});
    try w.print(
        "<p class=\"totals\"><b>{d}</b> devices &middot; <b>{d}</b> nets &middot; " ++
            "<b>{d}</b> labels &middot; <b>{d}</b> ignored &middot; <b>{d}</b> skipped</p>\n",
        .{ devices, nets, labels, ignored, skipped },
    );
}

/// Emit one fixture card: heading, `<img>`, and the statistic row.
///
/// The image is referenced rather than inlined so that a browser caches it and a
/// single fixture can be reloaded on its own during a debugging loop; inlining
/// twenty-one SVGs also produces a document large enough to be slow to open.
pub fn writeCard(entry: Entry, w: *Writer) Writer.Error!void {
    try w.writeAll("<figure><h2>");
    try writeEscaped(entry.name, w);
    try w.writeAll("</h2><a class=\"thumb\" href=\"");
    try writeEscaped(entry.svg_path, w);
    try w.writeAll("\"><img loading=\"lazy\" src=\"");
    try writeEscaped(entry.svg_path, w);
    try w.print("\" width=\"{d}\" height=\"{d}\" alt=\"", .{ entry.width, entry.height });
    try writeEscaped(entry.name, w);
    try w.writeAll("\"></a>\n<dl>");
    // Labels first and highlighted: the first term of the selection key, so any nonzero
    // value is the most interesting fact on the card.
    try w.print("<div{s}><dt>labels</dt><dd>{d}</dd></div>", .{
        if (entry.labels > 0) " class=\"bad\"" else "",
        entry.labels,
    });
    try w.print("<div><dt>devices</dt><dd>{d}</dd></div>", .{entry.devices});
    try w.print("<div><dt>nets</dt><dd>{d}</dd></div>", .{entry.nets});
    try w.print("<div><dt>wires</dt><dd>{d}</dd></div>", .{entry.wires});
    try w.print("<div><dt>ignored</dt><dd>{d}</dd></div>", .{entry.ignored});
    try w.print("<div{s}><dt>skipped</dt><dd>{d}</dd></div>", .{
        if (entry.skipped > 0) " class=\"bad\"" else "",
        entry.skipped,
    });
    try w.writeAll("</dl></figure>\n");
}

/// Write `s` with the five XML metacharacters replaced by entities.
///
/// Fixture names reach the page from filenames, so they are escaped unconditionally
/// for the same reason net names are in `svg.zig`. Duplicated rather than shared
/// between the two files on purpose: they are two independent example programs, and a
/// shared "gallery utils" module would be the first step toward the private renderer
/// support layer this example exists to prove is unnecessary.
pub fn writeEscaped(s: []const u8, w: *Writer) Writer.Error!void {
    var flushed: usize = 0;
    for (s, 0..) |c, i| {
        const entity = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => continue,
        };
        try w.writeAll(s[flushed..i]);
        try w.writeAll(entity);
        flushed = i + 1;
    }
    try w.writeAll(s[flushed..]);
}
