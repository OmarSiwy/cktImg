//! C ABI over the `cktimg` facade. See `include/cktimg.h` for the C side.
//!
//! Every string handed to the caller comes from [`CString::into_raw`] and must
//! be released with [`cktimg_string_free`] — never `free(3)` or anything else,
//! since Rust's allocator owns it.

#![warn(clippy::undocumented_unsafe_blocks)]

use std::ffi::{CStr, CString, c_char};
use std::fmt::Write as _;
use std::panic::catch_unwind;
use std::ptr;

/// String → caller-owned C string. Null if the text contains an interior NUL
/// (cannot happen for our JSON/report output, but stay total).
fn into_c(s: String) -> *mut c_char {
    CString::new(s).map_or(ptr::null_mut(), CString::into_raw)
}

/// Borrow the caller's NUL-terminated UTF-8 text. `None` on null or bad UTF-8.
///
/// # Safety
///
/// If non-null, `src` must point to a NUL-terminated byte string valid for
/// reads up to and including its terminator.
unsafe fn utf8_in<'a>(src: *const c_char) -> Option<&'a str> {
    if src.is_null() {
        return None;
    }
    // SAFETY: src is non-null; caller guarantees it is NUL-terminated and
    // valid for reads through the terminator.
    unsafe { CStr::from_ptr(src) }.to_str().ok()
}

/// Parse report → one text line per ignored/skipped source line.
fn report_text(report: &cktimg::Report) -> String {
    let mut txt = String::new();
    for (kind, notes) in [("ignored", &report.ignored), ("skipped", &report.skipped)] {
        for n in notes {
            let _ = writeln!(txt, "{kind} line {}: {} ({})", n.line, n.text, n.reason);
        }
    }
    txt
}

/// Render `src` to JSON via `cktimg::run`; panics are caught and become `None`.
fn run_json(src: &str) -> Option<(String, String)> {
    catch_unwind(|| {
        let (json, report) = cktimg::run(src, cktimg::backend::json);
        let txt = report_text(&report);
        (json, txt)
    })
    .ok()
}

/// Render NUL-terminated SPICE text to a JSON document.
///
/// Returns a NUL-terminated, malloc'd-by-Rust JSON string, or null on null
/// input, invalid UTF-8, or internal error. Free the result with
/// [`cktimg_string_free`] only.
///
/// # Safety
///
/// `src` must be null or a pointer to a NUL-terminated byte string that stays
/// valid and unmutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_run_json(src: *const c_char) -> *mut c_char {
    // SAFETY: our caller upholds utf8_in's contract (null or NUL-terminated).
    let Some(src) = (unsafe { utf8_in(src) }) else {
        return ptr::null_mut();
    };
    run_json(src).map_or(ptr::null_mut(), |(json, _)| into_c(json))
}

/// Like [`cktimg_run_json`], additionally writing the parse report (ignored /
/// skipped source lines, one per text line; empty string for a clean netlist)
/// to `*out_report`. Free both strings with [`cktimg_string_free`].
///
/// On failure returns null and, if `out_report` is non-null, sets
/// `*out_report` to null. A null `out_report` just skips the report.
///
/// # Safety
///
/// `src` as in [`cktimg_run_json`]; `out_report` must be null or valid for a
/// single pointer write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_run_json_with_report(
    src: *const c_char,
    out_report: *mut *mut c_char,
) -> *mut c_char {
    let write_report = |p: *mut c_char| {
        if !out_report.is_null() {
            // SAFETY: out_report is non-null and caller guarantees it is
            // valid for a pointer write.
            unsafe { out_report.write(p) };
        }
    };
    // SAFETY: our caller upholds utf8_in's contract (null or NUL-terminated).
    let out = unsafe { utf8_in(src) }.and_then(run_json);
    match out {
        Some((json, report)) => {
            write_report(into_c(report));
            into_c(json)
        }
        None => {
            write_report(ptr::null_mut());
            ptr::null_mut()
        }
    }
}

/// Free a string returned by this library. Null is a no-op. This is the ONLY
/// valid way to release such strings — they are Rust allocations, not
/// `malloc(3)` ones.
///
/// # Safety
///
/// `s` must be null or a pointer previously returned by this library that has
/// not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: s is non-null and, per the caller contract, came from
    // CString::into_raw in this library and is freed at most once.
    drop(unsafe { CString::from_raw(s) });
}

// ---------------------------------------------------------------------------
// Opaque-handle accessor API: parse+place once, then walk the resolved
// schematic from C without ever re-crossing the pipeline. All strings the
// accessors return are BORROWED from the handle (interned as CStrings at
// creation) and stay valid until `cktimg_sch_free` — do not free them.
// ---------------------------------------------------------------------------

struct Pin {
    term: CString,
    net: Option<CString>,
    xy: Option<[i32; 2]>,
}

struct Device {
    name: CString,
    class: CString,
    value: CString,
    rot: u8,
    mirror: bool,
    pos: Option<[i32; 2]>,
    pins: Vec<Pin>,
}

struct Wire {
    net: CString,
    segments: Vec<Vec<[i32; 2]>>,
}

/// The opaque handle behind `CktimgSch*`: [`cktimg::json::Schematic`] with
/// every string re-encoded as a NUL-terminated [`CString`] so accessors are
/// borrow-and-return, and segment points kept as `Vec<[i32; 2]>` for
/// zero-copy flat access.
pub struct CktimgSch {
    devices: Vec<Device>,
    nets: Vec<CString>,
    wires: Vec<Wire>,
    junctions: Vec<[i32; 2]>,
}

/// Interior NUL cannot appear (input came through a `CStr`), but stay total:
/// it would degrade to an empty string, not a panic.
fn cs(s: String) -> CString {
    CString::new(s).unwrap_or_default()
}

impl CktimgSch {
    fn from_json(s: cktimg::json::Schematic) -> Self {
        CktimgSch {
            devices: s
                .devices
                .into_iter()
                .map(|d| Device {
                    name: cs(d.name),
                    class: cs(d.class),
                    value: cs(d.value),
                    rot: d.rot,
                    mirror: d.mirror,
                    pos: d.pos,
                    pins: d
                        .pins
                        .into_iter()
                        .map(|p| Pin {
                            term: cs(p.term),
                            net: p.net.map(cs),
                            xy: p.xy,
                        })
                        .collect(),
                })
                .collect(),
            nets: s.nets.into_iter().map(cs).collect(),
            wires: s
                .wires
                .into_iter()
                .map(|w| Wire {
                    net: cs(w.net),
                    segments: w.segments,
                })
                .collect(),
            junctions: s.junctions,
        }
    }
}

/// Borrow the handle. `None` on null.
///
/// # Safety
///
/// `sch` must be null or a live handle from [`cktimg_parse_place`] /
/// [`cktimg_parse_place_with_report`], not yet freed, with no concurrent
/// mutation (the API never mutates, so shared reads are fine).
unsafe fn handle<'a>(sch: *const CktimgSch) -> Option<&'a CktimgSch> {
    // SAFETY: caller guarantees sch is null or a live, unfreed handle.
    unsafe { sch.as_ref() }
}

/// `devices[d]`, `None` on null handle or out-of-range index.
///
/// # Safety
///
/// As [`handle`].
unsafe fn device<'a>(sch: *const CktimgSch, d: usize) -> Option<&'a Device> {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }.and_then(|h| h.devices.get(d))
}

/// `devices[d].pins[p]`, `None` on any miss.
///
/// # Safety
///
/// As [`handle`].
unsafe fn pin<'a>(sch: *const CktimgSch, d: usize, p: usize) -> Option<&'a Pin> {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.and_then(|dev| dev.pins.get(p))
}

/// Write an optional coordinate pair through nullable out-pointers; the bool
/// tells the caller whether the pair existed.
///
/// # Safety
///
/// `x` and `y` must each be null or valid for an `i32` write.
unsafe fn write_xy(q: Option<[i32; 2]>, x: *mut i32, y: *mut i32) -> bool {
    let Some([qx, qy]) = q else { return false };
    if !x.is_null() {
        // SAFETY: x is non-null and caller guarantees it is writable.
        unsafe { x.write(qx) };
    }
    if !y.is_null() {
        // SAFETY: y is non-null and caller guarantees it is writable.
        unsafe { y.write(qy) };
    }
    true
}

/// Parse and place NUL-terminated SPICE text; returns an opaque schematic
/// handle for the accessor functions, or null on null input, invalid UTF-8,
/// or internal error. Free with [`cktimg_sch_free`].
///
/// # Safety
///
/// `src` must be null or a NUL-terminated byte string that stays valid and
/// unmutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_parse_place(src: *const c_char) -> *mut CktimgSch {
    // SAFETY: forwarded caller contract; null out_report is allowed.
    unsafe { cktimg_parse_place_with_report(src, ptr::null_mut()) }
}

/// Like [`cktimg_parse_place`], additionally writing the parse report string
/// (same format as [`cktimg_run_json_with_report`]) to `*out_report`. The
/// report is a fresh allocation — free it with [`cktimg_string_free`]. On
/// failure returns null and sets `*out_report` to null (when non-null).
///
/// # Safety
///
/// `src` as in [`cktimg_parse_place`]; `out_report` must be null or valid
/// for a single pointer write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_parse_place_with_report(
    src: *const c_char,
    out_report: *mut *mut c_char,
) -> *mut CktimgSch {
    let write_report = |p: *mut c_char| {
        if !out_report.is_null() {
            // SAFETY: out_report is non-null and caller guarantees it is
            // valid for a pointer write.
            unsafe { out_report.write(p) };
        }
    };
    // SAFETY: our caller upholds utf8_in's contract (null or NUL-terminated).
    let built = unsafe { utf8_in(src) }.and_then(|src| {
        catch_unwind(|| {
            let (placed, it, report) = cktimg::place(src);
            let sch = cktimg::json::Schematic::from_ir(placed.ir(), it.pool());
            (CktimgSch::from_json(sch), report_text(&report))
        })
        .ok()
    });
    match built {
        Some((sch, report)) => {
            write_report(into_c(report));
            Box::into_raw(Box::new(sch))
        }
        None => {
            write_report(ptr::null_mut());
            ptr::null_mut()
        }
    }
}

/// Free a schematic handle. Null is a no-op. Invalidates every borrowed
/// string and point pointer previously returned for this handle.
///
/// # Safety
///
/// `sch` must be null or a handle from [`cktimg_parse_place`] /
/// [`cktimg_parse_place_with_report`] that has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_sch_free(sch: *mut CktimgSch) {
    if sch.is_null() {
        return;
    }
    // SAFETY: sch is non-null and, per the caller contract, came from
    // Box::into_raw in this library and is freed at most once.
    drop(unsafe { Box::from_raw(sch) });
}

/// Number of devices. 0 on null handle.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_count(sch: *const CktimgSch) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }.map_or(0, |h| h.devices.len())
}

/// Device refdes (e.g. `"m1"`). BORROWED — valid until [`cktimg_sch_free`];
/// do not free. Null on null handle or out-of-range index.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_name(sch: *const CktimgSch, d: usize) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.map_or(ptr::null(), |dev| dev.name.as_ptr())
}

/// Device class (e.g. `"nmos"`). BORROWED, same lifetime as
/// [`cktimg_device_name`]. Null on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_class(sch: *const CktimgSch, d: usize) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.map_or(ptr::null(), |dev| dev.class.as_ptr())
}

/// Device value (e.g. `"5k"`, may be empty). BORROWED, same lifetime as
/// [`cktimg_device_name`]. Null on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_value(sch: *const CktimgSch, d: usize) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.map_or(ptr::null(), |dev| dev.value.as_ptr())
}

/// Device rotation in quarter turns, 0..=3 (multiply by 90°). 0 on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_rot(sch: *const CktimgSch, d: usize) -> u8 {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.map_or(0, |dev| dev.rot)
}

/// Whether the device is mirrored. False on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_mirror(sch: *const CktimgSch, d: usize) -> bool {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.is_some_and(|dev| dev.mirror)
}

/// Device position. Writes `*x`/`*y` (each may be null to skip) and returns
/// true when placed; false (nothing written) on miss or unplaced device.
///
/// # Safety
///
/// `sch` must be null or a live handle; `x`/`y` each null or valid for an
/// `i32` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_pos(
    sch: *const CktimgSch,
    d: usize,
    x: *mut i32,
    y: *mut i32,
) -> bool {
    // SAFETY: forwarded caller contracts (handle read, then x/y writes).
    unsafe { write_xy(device(sch, d).and_then(|dev| dev.pos), x, y) }
}

/// Number of pins on device `d`. 0 on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_device_pin_count(sch: *const CktimgSch, d: usize) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { device(sch, d) }.map_or(0, |dev| dev.pins.len())
}

/// Terminal name of pin `p` (e.g. `"g"`, may be empty). BORROWED, valid until
/// [`cktimg_sch_free`]. Null on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_pin_term(
    sch: *const CktimgSch,
    d: usize,
    p: usize,
) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { pin(sch, d, p) }.map_or(ptr::null(), |pin| pin.term.as_ptr())
}

/// Net the pin connects to. BORROWED, valid until [`cktimg_sch_free`]. Null
/// on miss OR when the pin is unconnected.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_pin_net(
    sch: *const CktimgSch,
    d: usize,
    p: usize,
) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { pin(sch, d, p) }
        .and_then(|pin| pin.net.as_ref())
        .map_or(ptr::null(), |net| net.as_ptr())
}

/// Pin coordinates; same out-parameter convention as [`cktimg_device_pos`].
///
/// # Safety
///
/// `sch` must be null or a live handle; `x`/`y` each null or valid for an
/// `i32` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_pin_xy(
    sch: *const CktimgSch,
    d: usize,
    p: usize,
    x: *mut i32,
    y: *mut i32,
) -> bool {
    // SAFETY: forwarded caller contracts (handle read, then x/y writes).
    unsafe { write_xy(pin(sch, d, p).and_then(|pin| pin.xy), x, y) }
}

/// Number of nets. 0 on null handle.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_net_count(sch: *const CktimgSch) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }.map_or(0, |h| h.nets.len())
}

/// Net name. BORROWED, valid until [`cktimg_sch_free`]. Null on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_net_name(sch: *const CktimgSch, n: usize) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }
        .and_then(|h| h.nets.get(n))
        .map_or(ptr::null(), |net| net.as_ptr())
}

/// Number of routed wires (nets that carry geometry). 0 on null handle.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_wire_count(sch: *const CktimgSch) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }.map_or(0, |h| h.wires.len())
}

/// Net name of wire `w`. BORROWED, valid until [`cktimg_sch_free`]. Null on
/// miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_wire_net(sch: *const CktimgSch, w: usize) -> *const c_char {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }
        .and_then(|h| h.wires.get(w))
        .map_or(ptr::null(), |wire| wire.net.as_ptr())
}

/// Number of polyline segments in wire `w`. 0 on miss.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_wire_segment_count(sch: *const CktimgSch, w: usize) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }
        .and_then(|h| h.wires.get(w))
        .map_or(0, |wire| wire.segments.len())
}

/// Points of segment `s` of wire `w`. Returns the point count and, when `xy`
/// is non-null, writes a BORROWED pointer to a flat `x0,y0,x1,y1,…` array of
/// `2 * count` int32 values (valid until [`cktimg_sch_free`]; do not free).
/// On miss returns 0 and writes null.
///
/// # Safety
///
/// `sch` must be null or a live handle; `xy` null or valid for a pointer
/// write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_wire_segment_points(
    sch: *const CktimgSch,
    w: usize,
    s: usize,
    xy: *mut *const i32,
) -> usize {
    // SAFETY: forwarded caller contract.
    let seg = unsafe { handle(sch) }
        .and_then(|h| h.wires.get(w))
        .and_then(|wire| wire.segments.get(s));
    if !xy.is_null() {
        // SAFETY (write): xy is non-null and caller guarantees it is valid
        // for a pointer write.
        // SAFETY (cast): [i32; 2] is layout-identical to two consecutive
        // i32s with no padding, so a Vec<[i32; 2]> of len n reads as a flat
        // i32 array of len 2n — zero-copy.
        unsafe { xy.write(seg.map_or(ptr::null(), |p| p.as_ptr().cast::<i32>())) };
    }
    seg.map_or(0, Vec::len)
}

/// Number of wire junction dots. 0 on null handle.
///
/// # Safety
///
/// `sch` must be null or a live handle (see [`cktimg_parse_place`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_junction_count(sch: *const CktimgSch) -> usize {
    // SAFETY: forwarded caller contract.
    unsafe { handle(sch) }.map_or(0, |h| h.junctions.len())
}

/// Junction coordinates; same out-parameter convention as
/// [`cktimg_device_pos`].
///
/// # Safety
///
/// `sch` must be null or a live handle; `x`/`y` each null or valid for an
/// `i32` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cktimg_junction(
    sch: *const CktimgSch,
    j: usize,
    x: *mut i32,
    y: *mut i32,
) -> bool {
    // SAFETY: forwarded caller contracts (handle read, then x/y writes).
    unsafe { write_xy(handle(sch).and_then(|h| h.junctions.get(j).copied()), x, y) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_json_roundtrip() {
        let src = CString::new("R1 vdd out 5k\nM1 out in gnd nmos\n").unwrap();
        // SAFETY: src is a valid NUL-terminated string alive for the call.
        let out = unsafe { cktimg_run_json(src.as_ptr()) };
        assert!(!out.is_null());
        // SAFETY: out is the non-null NUL-terminated string we just got back.
        let json = unsafe { CStr::from_ptr(out) }.to_str().unwrap();
        assert!(json.trim_start().starts_with('{'), "not JSON:\n{json}");
        assert!(json.contains("\"devices\""), "missing devices:\n{json}");
        // SAFETY: out came from cktimg_run_json and is freed exactly once.
        unsafe { cktimg_string_free(out) };
    }

    #[test]
    fn report_is_written() {
        let src = CString::new(".tran 1n 1u\nR1 a b 1k\n").unwrap();
        let mut report = ptr::null_mut();
        // SAFETY: valid src string; report is a live local, writable.
        let out = unsafe { cktimg_run_json_with_report(src.as_ptr(), &mut report) };
        assert!(!out.is_null() && !report.is_null());
        // SAFETY: report is the non-null NUL-terminated string just returned.
        let txt = unsafe { CStr::from_ptr(report) }.to_str().unwrap();
        assert!(txt.contains("ignored line 1"), "report was:\n{txt}");
        // SAFETY: both pointers came from this library, freed once each.
        unsafe {
            cktimg_string_free(out);
            cktimg_string_free(report);
        }
    }

    #[test]
    fn null_in_null_out() {
        // SAFETY: null is explicitly allowed for every pointer argument.
        unsafe {
            assert!(cktimg_run_json(ptr::null()).is_null());
            let mut report = ptr::null_mut();
            assert!(cktimg_run_json_with_report(ptr::null(), &mut report).is_null());
            assert!(report.is_null());
            cktimg_string_free(ptr::null_mut()); // no-op
        }
    }

    /// Borrowed C string → &str, for assertions.
    ///
    /// # Safety
    ///
    /// `p` must be a valid NUL-terminated UTF-8 string.
    unsafe fn s<'a>(p: *const c_char) -> &'a str {
        assert!(!p.is_null());
        // SAFETY: forwarded caller contract.
        unsafe { CStr::from_ptr(p) }.to_str().unwrap()
    }

    // SAFETY throughout the handle tests: src CStrings outlive the calls,
    // sch is the live handle just created (freed once at the end), and all
    // out-pointers are live locals.
    #[test]
    fn handle_walk() {
        let src = CString::new("R1 vdd out 5k\nM1 out in gnd nmos\n").unwrap();
        let mut report = ptr::null_mut();
        let sch = unsafe { cktimg_parse_place_with_report(src.as_ptr(), &mut report) };
        assert!(!sch.is_null() && !report.is_null());
        unsafe { cktimg_string_free(report) };

        unsafe {
            // Devices: r1, m1, plus auto-inserted rails.
            let nd = cktimg_device_count(sch);
            assert!(nd >= 4, "expected >= 4 devices, got {nd}");
            let names: Vec<&str> = (0..nd).map(|d| s(cktimg_device_name(sch, d))).collect();
            assert!(names.contains(&"r1") && names.contains(&"m1"), "{names:?}");
            let r1 = names.iter().position(|n| *n == "r1").unwrap();
            assert_eq!(s(cktimg_device_class(sch, r1)), "res");
            assert_eq!(s(cktimg_device_value(sch, r1)), "5k");
            assert!(cktimg_device_rot(sch, r1) <= 3);
            let _ = cktimg_device_mirror(sch, r1);
            let (mut x, mut y) = (i32::MIN, i32::MIN);
            assert!(cktimg_device_pos(sch, r1, &mut x, &mut y));
            assert!(x != i32::MIN && y != i32::MIN);

            // Pins of r1: two terminals, both connected and placed.
            assert_eq!(cktimg_device_pin_count(sch, r1), 2);
            let nets: Vec<&str> = (0..2).map(|p| s(cktimg_pin_net(sch, r1, p))).collect();
            assert!(nets.contains(&"vdd") && nets.contains(&"out"), "{nets:?}");
            assert!(!s(cktimg_pin_term(sch, r1, 0)).is_empty());
            assert!(cktimg_pin_xy(sch, r1, 0, &mut x, &mut y));

            // Nets.
            let nn = cktimg_net_count(sch);
            let net_names: Vec<&str> = (0..nn).map(|n| s(cktimg_net_name(sch, n))).collect();
            assert!(net_names.contains(&"out"), "{net_names:?}");

            // Wires: at least one, with a >= 2-point polyline read flat.
            let nw = cktimg_wire_count(sch);
            assert!(nw >= 1);
            assert!(net_names.contains(&s(cktimg_wire_net(sch, 0))));
            let ns = cktimg_wire_segment_count(sch, 0);
            assert!(ns >= 1);
            let mut flat: *const i32 = ptr::null();
            let npts = cktimg_wire_segment_points(sch, 0, 0, &mut flat);
            assert!(npts >= 2 && !flat.is_null());
            // Some segment somewhere must have real extent (zero-length stub
            // segments are legal, so scan them all).
            let has_extent = (0..nw).any(|w| {
                (0..cktimg_wire_segment_count(sch, w)).any(|seg| {
                    let mut p: *const i32 = ptr::null();
                    let n = cktimg_wire_segment_points(sch, w, seg, &mut p);
                    // SAFETY: p points at n [i32;2] pairs owned by the handle.
                    let pts = std::slice::from_raw_parts(p, 2 * n);
                    pts.chunks(2).any(|q| q != &pts[..2])
                })
            });
            assert!(has_extent, "every wire segment is a point");

            // Junctions: count is walkable; each index yields coordinates.
            let nj = cktimg_junction_count(sch);
            for j in 0..nj {
                assert!(cktimg_junction(sch, j, &mut x, &mut y));
            }

            // Out-of-range: null/0/false, never a panic.
            assert!(cktimg_device_name(sch, nd).is_null());
            assert!(cktimg_device_class(sch, nd).is_null());
            assert!(cktimg_device_value(sch, nd).is_null());
            assert_eq!(cktimg_device_rot(sch, nd), 0);
            assert!(!cktimg_device_mirror(sch, nd));
            assert!(!cktimg_device_pos(sch, nd, &mut x, &mut y));
            assert_eq!(cktimg_device_pin_count(sch, nd), 0);
            assert!(cktimg_pin_term(sch, r1, 99).is_null());
            assert!(cktimg_pin_net(sch, r1, 99).is_null());
            assert!(!cktimg_pin_xy(sch, r1, 99, &mut x, &mut y));
            assert!(cktimg_net_name(sch, nn).is_null());
            assert!(cktimg_wire_net(sch, nw).is_null());
            assert_eq!(cktimg_wire_segment_count(sch, nw), 0);
            flat = &raw const x; // poison; must be overwritten with null
            assert_eq!(cktimg_wire_segment_points(sch, 0, 999, &mut flat), 0);
            assert!(flat.is_null());
            assert!(!cktimg_junction(sch, nj, &mut x, &mut y));

            cktimg_sch_free(sch);
        }
    }

    #[test]
    fn handle_null_safe() {
        // SAFETY: null handle is explicitly allowed everywhere.
        unsafe {
            let mut report = ptr::null_mut();
            assert!(cktimg_parse_place(ptr::null()).is_null());
            assert!(cktimg_parse_place_with_report(ptr::null(), &mut report).is_null());
            assert!(report.is_null());
            let null = ptr::null();
            let (mut x, mut y) = (0i32, 0i32);
            assert_eq!(cktimg_device_count(null), 0);
            assert!(cktimg_device_name(null, 0).is_null());
            assert!(!cktimg_device_pos(null, 0, &mut x, &mut y));
            assert_eq!(cktimg_device_pin_count(null, 0), 0);
            assert!(cktimg_pin_net(null, 0, 0).is_null());
            assert!(!cktimg_pin_xy(null, 0, 0, &mut x, &mut y));
            assert_eq!(cktimg_net_count(null), 0);
            assert!(cktimg_net_name(null, 0).is_null());
            assert_eq!(cktimg_wire_count(null), 0);
            let mut flat = ptr::null();
            assert_eq!(cktimg_wire_segment_points(null, 0, 0, &mut flat), 0);
            assert_eq!(cktimg_junction_count(null), 0);
            assert!(!cktimg_junction(null, 0, &mut x, &mut y));
            cktimg_sch_free(ptr::null_mut()); // no-op
        }
    }
}
