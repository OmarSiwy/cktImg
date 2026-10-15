//! Safe wrapper over cktImg's C ABI (`plugins/cktimg/vendor/include/cktimg.h`), one method per C
//! function. [`Lib`] owns a `CktimgLib` (device classes), [`Sch`] owns a `CktimgSch` (one
//! placed netlist); both free their handle on drop. Accessors return plain values, and
//! names and wire points are borrowed from the handle, never copied.
//!
//! Left out on purpose: `cktimg_wire_count`/`cktimg_wire_net` (the wire index is the net
//! index: use [`Sch::net_count`]/[`Sch::net_name`]), `cktimg_run_json` (it is
//! [`Lib::place`] then [`Sch::json`]) and `cktimg_device_value` (the importer keeps each
//! card's text in its own deck).
//!
//! Ownership, as the header states it: strings and points an accessor returns are borrowed
//! from the `Sch` (valid until it drops, which the borrow checker enforces), and a `Sch`
//! borrows the `Lib` it was placed with mutably, because class names and strokes point
//! into the library and placing may register generated classes in it. Reports that the C
//! side allocates for the caller are copied into a `String` and freed with
//! `cktimg_string_free` before the call returns.
//!
//! Coordinates are the library's integers, y down. An orientation is a mirror about the
//! vertical axis, then `rot` quarter turns clockwise.
//!
//! # Examples
//!
//! ```
//! use cktimg::ffi::{Lib, Op, Role, Terminal};
//!
//! let mut lib = Lib::new();
//! let ab = [Terminal { name: "a", x: -20, y: 0, flags: 0 }, Terminal { name: "b", x: 20, y: 0, flags: 0 }];
//! assert_eq!(lib.add("res", Role::None, &ab, &[Op::Line([-20, 0, 20, 0])]), Some(0));
//! let sch = lib.place("* divider\nR1 in out 1k\nR2 out 0 1k\n", None).unwrap();
//! assert_eq!(sch.device_name(0), "r1");
//! assert_eq!(sch.pin_net(1, 1), Some("0"));
//! ```

#![allow(unsafe_code)] // the FFI boundary: every block states its obligation

use std::ffi::{CStr, CString, c_char};
use std::marker::PhantomData;
use std::ptr::{self, NonNull};

#[repr(C)]
struct RawLib {
    _opaque: [u8; 0],
}

#[repr(C)]
struct RawSch {
    _opaque: [u8; 0],
}

#[repr(C)]
struct RawTerminal {
    name: *const c_char,
    x: i32,
    y: i32,
    flags: u8,
}

#[repr(C)]
struct RawOp {
    kind: u8,
    xy: *const i32,
    count: usize,
    r: i32,
    text: *const c_char,
    size: u8,
}

// Every function is safe for a null handle or an out-of-range index (the header's SAFETY
// section); the obligation left to Rust is that a non-null handle is live.
unsafe extern "C" {
    fn cktimg_lib_new() -> *mut RawLib;
    fn cktimg_lib_free(lib: *mut RawLib);
    fn cktimg_lib_set_unit(lib: *mut RawLib, unit: i32) -> bool;
    fn cktimg_lib_count(lib: *const RawLib) -> usize;
    fn cktimg_lib_add(
        lib: *mut RawLib,
        name: *const c_char,
        role: u8,
        terms: *const RawTerminal,
        n_terms: usize,
        ops: *const RawOp,
        n_ops: usize,
    ) -> usize;
    fn cktimg_lib_load_zon(
        lib: *mut RawLib,
        text: *const c_char,
        out_report: *mut *mut c_char,
    ) -> bool;
    fn cktimg_parse_place(
        lib: *mut RawLib,
        src: *const c_char,
        zon: *const c_char,
        out_report: *mut *mut c_char,
    ) -> *mut RawSch;
    fn cktimg_sch_free(sch: *mut RawSch);
    fn cktimg_string_free(s: *mut c_char);
    fn cktimg_report(sch: *const RawSch) -> *const c_char;
    fn cktimg_json(sch: *const RawSch, buf: *mut c_char, cap: usize) -> usize;
    fn cktimg_device_count(sch: *const RawSch) -> usize;
    fn cktimg_device_name(sch: *const RawSch, d: usize) -> *const c_char;
    fn cktimg_device_class(sch: *const RawSch, d: usize) -> *const c_char;
    fn cktimg_device_role(sch: *const RawSch, d: usize) -> u8;
    fn cktimg_device_rot(sch: *const RawSch, d: usize) -> u8;
    fn cktimg_device_mirror(sch: *const RawSch, d: usize) -> bool;
    fn cktimg_device_pos(sch: *const RawSch, d: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_device_refdes_anchor(sch: *mut RawSch, d: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_device_pin_count(sch: *const RawSch, d: usize) -> usize;
    fn cktimg_pin_term(sch: *const RawSch, d: usize, p: usize) -> *const c_char;
    fn cktimg_pin_net(sch: *const RawSch, d: usize, p: usize) -> *const c_char;
    fn cktimg_pin_xy(sch: *const RawSch, d: usize, p: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_net_count(sch: *const RawSch) -> usize;
    fn cktimg_net_name(sch: *const RawSch, n: usize) -> *const c_char;
    fn cktimg_wire_segment_count(sch: *const RawSch, w: usize) -> usize;
    fn cktimg_wire_segment_points(
        sch: *const RawSch,
        w: usize,
        s: usize,
        xy: *mut *const i32,
    ) -> usize;
    fn cktimg_junction_count(sch: *const RawSch) -> usize;
    fn cktimg_junction(sch: *const RawSch, j: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_label_count(sch: *const RawSch) -> usize;
    fn cktimg_label_net(sch: *const RawSch, l: usize) -> *const c_char;
    fn cktimg_label_xy(sch: *const RawSch, l: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_label_side(sch: *const RawSch, l: usize) -> u8;
    fn cktimg_noconnect_count(sch: *const RawSch) -> usize;
    fn cktimg_noconnect(sch: *const RawSch, k: usize, x: *mut i32, y: *mut i32) -> bool;
    fn cktimg_bounds(
        sch: *const RawSch,
        x0: *mut i32,
        y0: *mut i32,
        x1: *mut i32,
        y1: *mut i32,
    ) -> bool;
    fn cktimg_device_bounds(
        sch: *const RawSch,
        d: usize,
        x0: *mut i32,
        y0: *mut i32,
        x1: *mut i32,
        y1: *mut i32,
    ) -> bool;
    fn cktimg_device_op_count(sch: *const RawSch, d: usize) -> usize;
    fn cktimg_device_op_kind(sch: *const RawSch, d: usize, o: usize) -> u8;
    fn cktimg_device_op_points(
        sch: *const RawSch,
        d: usize,
        o: usize,
        xy: *mut i32,
        cap: usize,
    ) -> usize;
    fn cktimg_device_op_circle(
        sch: *const RawSch,
        d: usize,
        o: usize,
        cx: *mut i32,
        cy: *mut i32,
        r: *mut i32,
    ) -> bool;
    fn cktimg_device_op_text(
        sch: *const RawSch,
        d: usize,
        o: usize,
        x: *mut i32,
        y: *mut i32,
        size: *mut u8,
    ) -> *const c_char;
    fn cktimg_lint(sch: *const RawSch, buf: *mut c_char, cap: usize, errors: *mut usize) -> usize;
}

/// What a class is placed as (`CktimgRole`): a device, or one of the terminal symbols the
/// layout adds for supply, ground, input and output nets (found by role, not by name).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Role {
    /// A device.
    None = 0,
    /// The supply symbol.
    PowerRail = 1,
    /// The ground symbol.
    GroundRail = 2,
    /// An input port symbol.
    InputPort = 3,
    /// An output port symbol.
    OutputPort = 4,
}

/// Terminal flag: counts for paths but gets no wire (a MOS bulk drawn on the symbol).
pub const TERM_HIDDEN: u8 = 1;
/// Terminal flag: gets no wire when its net is ground (an op-amp's reference).
pub const TERM_GROUND_REF: u8 = 2;

/// One terminal of a class, in SPICE node order, at its anchor in the canonical frame
/// (origin at the device centre, y down, principal terminals on the x axis).
#[derive(Clone, Copy, Debug)]
pub struct Terminal<'a> {
    /// Terminal name; must not contain NUL.
    pub name: &'a str,
    /// Anchor x.
    pub x: i32,
    /// Anchor y.
    pub y: i32,
    /// [`TERM_HIDDEN`] | [`TERM_GROUND_REF`].
    pub flags: u8,
}

/// One body stroke of a class, in the canonical frame.
#[derive(Clone, Copy, Debug)]
pub enum Op<'a> {
    /// `x0, y0, x1, y1`.
    Line([i32; 4]),
    /// At least two points; closed when the last repeats the first.
    Polyline(&'a [[i32; 2]]),
    /// Centre and radius.
    Circle([i32; 2], i32),
    /// Text centred at a point (drawn upright), with a size; must not contain NUL.
    Text([i32; 2], &'a str, u8),
}

/// Kind of a placed body stroke ([`Sch::device_op_kind`]), the header's `CktimgOpKind`.
pub const OP_LINE: u8 = 0;
/// See [`OP_LINE`].
pub const OP_POLYLINE: u8 = 1;
/// See [`OP_LINE`].
pub const OP_CIRCLE: u8 = 2;
/// See [`OP_LINE`].
pub const OP_TEXT: u8 = 3;

/// A device-class library (`CktimgLib`): what each class looks like. The library knows no
/// device until classes are added; a device is drawn as the class of its vocabulary name
/// (`res`, `nmos`, …, see the header), a subcircuit instance as the class named after its
/// `.subckt`, and anything else as a generated box.
#[derive(Debug)]
pub struct Lib {
    raw: NonNull<RawLib>,
}

impl Default for Lib {
    fn default() -> Lib {
        Lib::new()
    }
}

impl Lib {
    /// Creates an empty library (pin-to-pin unit 40).
    ///
    /// # Panics
    ///
    /// Panics if cktImg is out of memory.
    pub fn new() -> Lib {
        // SAFETY: no arguments; the result is checked for null.
        let raw = unsafe { cktimg_lib_new() };
        Lib {
            raw: NonNull::new(raw).expect("cktimg_lib_new: out of memory"),
        }
    }

    /// Sets the length of a two-pin symbol, pin end to pin end, in the library's
    /// coordinates: the unit the layout's wire lengths are measured in. `false` (and no
    /// change) unless `unit > 0`.
    pub fn set_unit(&mut self, unit: i32) -> bool {
        // SAFETY: `raw` is live (owned by `self`).
        unsafe { cktimg_lib_set_unit(self.raw.as_ptr(), unit) }
    }

    /// Number of classes, including generated ones placing has registered.
    pub fn len(&self) -> usize {
        // SAFETY: `raw` is live.
        unsafe { cktimg_lib_count(self.raw.as_ptr()) }
    }

    /// True when no class is registered.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Adds a class (everything is copied) and returns its index, which never changes
    /// meaning. An exact repeat returns the existing index. `None` for no terminals, two
    /// terminals on one point, a name already added with other terminals, a NUL in a
    /// string, a polyline of fewer than two points, or out of memory. With no `ops` a
    /// labelled box is drawn around the terminals.
    ///
    /// Cost: one allocation per string and one per call for the C arrays.
    pub fn add(&mut self, name: &str, role: Role, terms: &[Terminal], ops: &[Op]) -> Option<usize> {
        let name = CString::new(name).ok()?;
        let names: Vec<CString> = terms
            .iter()
            .map(|t| CString::new(t.name))
            .collect::<Result<_, _>>()
            .ok()?;
        let texts: Vec<CString> = ops
            .iter()
            .map(|o| CString::new(if let Op::Text(_, s, _) = o { *s } else { "" }))
            .collect::<Result<_, _>>()
            .ok()?;
        let raw_terms: Vec<RawTerminal> = terms
            .iter()
            .zip(&names)
            .map(|(t, n)| RawTerminal {
                name: n.as_ptr(),
                x: t.x,
                y: t.y,
                flags: t.flags,
            })
            .collect();
        let raw_ops: Vec<RawOp> = ops
            .iter()
            .zip(&texts)
            .map(|(o, text)| {
                let (kind, xy, count, r, size): (u8, *const i32, usize, i32, u8) = match o {
                    Op::Line(v) => (OP_LINE, v.as_ptr(), 2, 0, 0),
                    Op::Polyline(ps) => (OP_POLYLINE, ps.as_ptr().cast(), ps.len(), 0, 0),
                    Op::Circle(c, r) => (OP_CIRCLE, c.as_ptr(), 1, *r, 0),
                    Op::Text(at, _, size) => (OP_TEXT, at.as_ptr(), 1, 0, *size),
                };
                RawOp {
                    kind,
                    xy,
                    count,
                    r,
                    text: text.as_ptr(),
                    size,
                }
            })
            .collect();
        // SAFETY: `raw` is live; every pointer points into `name`, `names`, `texts`,
        // `raw_terms`, `raw_ops` or `ops`, all alive until the call returns, with the
        // lengths passed; cktImg copies everything it keeps.
        let id = unsafe {
            cktimg_lib_add(
                self.raw.as_ptr(),
                name.as_ptr(),
                role as u8,
                raw_terms.as_ptr(),
                raw_terms.len(),
                raw_ops.as_ptr(),
                raw_ops.len(),
            )
        };
        (id != usize::MAX).then_some(id)
    }

    /// Adds every class of a `.zon` symbol file (`plugins/cktimg/vendor/tests/symbols.zon` shows
    /// the shape); also sets the unit. `Err` lists the classes refused (each refused class
    /// is skipped, the rest are added) or says the text has a NUL.
    pub fn load_zon(&mut self, text: &str) -> Result<(), String> {
        let text = CString::new(text).map_err(|_| "NUL in symbol text".to_owned())?;
        let mut report: *mut c_char = ptr::null_mut();
        // SAFETY: `raw` is live, `text` is NUL-terminated and outlives the call, `report`
        // is a valid out-pointer.
        let ok = unsafe { cktimg_lib_load_zon(self.raw.as_ptr(), text.as_ptr(), &mut report) };
        let report = take_string(report);
        if ok { Ok(()) } else { Err(report) }
    }

    /// Parses SPICE text `src` (its first line is the title) and places it with this
    /// library's classes and the `lint.zon` settings `zon` (`None`: the defaults).
    ///
    /// Invalidation: the returned [`Sch`] borrows `self` mutably until it drops, since its
    /// class names point into the library and placing may register generated classes.
    ///
    /// # Errors
    ///
    /// The parser's reason (`line N: Error near 'token'`) when it rejects the netlist
    /// (`.include`/`.lib`, `poly(n)` sources, A/N/P/Y cards, an analysis naming an unknown
    /// node, a duplicate device, …), or a note that `src`/`zon` holds a NUL.
    pub fn place(&mut self, src: &str, zon: Option<&str>) -> Result<Sch<'_>, String> {
        let src = CString::new(src).map_err(|_| "NUL in netlist text".to_owned())?;
        let zon = zon
            .map(CString::new)
            .transpose()
            .map_err(|_| "NUL in settings text".to_owned())?;
        let mut report: *mut c_char = ptr::null_mut();
        // SAFETY: `raw` is live; `src` and `zon` are NUL-terminated and outlive the call
        // (cktImg copies what it keeps); `report` is a valid out-pointer.
        let raw = unsafe {
            cktimg_parse_place(
                self.raw.as_ptr(),
                src.as_ptr(),
                zon.as_ref().map_or(ptr::null(), |z| z.as_ptr()),
                &mut report,
            )
        };
        let report = take_string(report);
        match NonNull::new(raw) {
            Some(raw) => Ok(Sch {
                raw,
                _lib: PhantomData,
            }),
            None if report.is_empty() => {
                Err("cktimg_parse_place failed (out of memory)".to_owned())
            }
            None => Err(report),
        }
    }
}

impl Drop for Lib {
    fn drop(&mut self) {
        // SAFETY: `raw` came from `cktimg_lib_new` and is freed once; no `Sch` borrows it
        // (the borrow checker ends every `Sch` before `self` drops).
        unsafe { cktimg_lib_free(self.raw.as_ptr()) }
    }
}

/// Copies a caller-owned C string into a `String` and frees it; `""` for null.
fn take_string(s: *mut c_char) -> String {
    if s.is_null() {
        return String::new();
    }
    // SAFETY: cktImg handed out `s` NUL-terminated and caller-owned; it is read once and
    // freed with the matching `cktimg_string_free`, never used after.
    unsafe {
        let text = CStr::from_ptr(s).to_string_lossy().into_owned();
        cktimg_string_free(s);
        text
    }
}

/// One placed netlist (`CktimgSch`): devices at integer points with an orientation, every
/// pin's point, wires per net, junctions, labels and no-connect marks. Devices come in
/// netlist order, then the rail and port symbols the layout added (empty name,
/// [`Role`] other than `None`, one pin on their net). The index preconditions below are
/// asserted.
#[derive(Debug)]
pub struct Sch<'lib> {
    raw: NonNull<RawSch>,
    _lib: PhantomData<&'lib mut Lib>,
}

impl Drop for Sch<'_> {
    fn drop(&mut self) {
        // SAFETY: `raw` came from `cktimg_parse_place` and is freed once.
        unsafe { cktimg_sch_free(self.raw.as_ptr()) }
    }
}

/// A borrowed C string as `&str` (cktImg hands out ASCII-lowercased netlist text and the
/// class names it was given, so it is UTF-8 whenever the input was).
///
/// # Safety
///
/// `p` is null or NUL-terminated and lives at least as long as `'a`.
unsafe fn borrowed<'a>(p: *const c_char) -> Option<&'a str> {
    // SAFETY: the caller's contract.
    (!p.is_null()).then(|| {
        unsafe { CStr::from_ptr(p) }
            .to_str()
            .expect("cktImg strings are UTF-8")
    })
}

impl Sch<'_> {
    fn ptr(&self) -> *const RawSch {
        self.raw.as_ptr()
    }

    /// Reads a point through a C accessor, asserting it answered (index in range).
    fn point(&self, what: &str, f: impl FnOnce(*mut i32, *mut i32) -> bool) -> [i32; 2] {
        let (mut x, mut y) = (0, 0);
        assert!(f(&mut x, &mut y), "{what}: index out of range");
        [x, y]
    }

    /// The settings' complaints, one per line; `""` when clean.
    pub fn report(&self) -> &str {
        // SAFETY: `ptr` is live; the string lives as long as the handle (`&self`).
        unsafe { borrowed(cktimg_report(self.ptr())) }.unwrap_or("")
    }

    /// The placed schematic as cktImg's JSON document.
    ///
    /// Cost: renders twice (size, then text) and allocates the result.
    pub fn json(&self) -> String {
        // SAFETY: a null buffer with cap 0 only asks for the length.
        let need = unsafe { cktimg_json(self.ptr(), ptr::null_mut(), 0) };
        let mut buf = vec![0u8; need + 1];
        // SAFETY: `buf` holds `need + 1` writable bytes; cktImg writes at most `cap`.
        let got = unsafe { cktimg_json(self.ptr(), buf.as_mut_ptr().cast(), buf.len()) };
        assert_eq!(got, need, "the document changed between two renders");
        buf.truncate(need);
        String::from_utf8(buf).expect("cktImg JSON is UTF-8")
    }

    /// The lint findings for the settings' `.rules`, one per line, and how many are at
    /// severity `err`.
    ///
    /// Cost: runs every rule twice (size, then text).
    pub fn lint(&self) -> (String, usize) {
        let mut errors = 0usize;
        // SAFETY: a null buffer with cap 0 only asks for the length.
        let need = unsafe { cktimg_lint(self.ptr(), ptr::null_mut(), 0, &mut errors) };
        let mut buf = vec![0u8; need + 1];
        // SAFETY: `buf` holds `need + 1` writable bytes; cktImg writes at most `cap`.
        let got = unsafe {
            cktimg_lint(
                self.ptr(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                ptr::null_mut(),
            )
        };
        assert_eq!(got, need, "the findings changed between two runs");
        buf.truncate(need);
        (
            String::from_utf8(buf).expect("cktImg lint text is UTF-8"),
            errors,
        )
    }

    /// Devices: the netlist's, then the symbols the layout added.
    pub fn device_count(&self) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_device_count(self.ptr()) }
    }

    /// Device `d`'s name, lowercase; `""` for a symbol the layout added. `d < device_count()`.
    pub fn device_name(&self, d: usize) -> &str {
        // SAFETY: `ptr` is live; the name lives as long as the handle.
        unsafe { borrowed(cktimg_device_name(self.ptr(), d)) }.expect("device index out of range")
    }

    /// Device `d`'s class name (`res`, `nmos`, `block:opamp`, `generic3`, …).
    pub fn device_class(&self, d: usize) -> &str {
        // SAFETY: `ptr` is live; the name lives in the library, which outlives `self`.
        unsafe { borrowed(cktimg_device_class(self.ptr(), d)) }.expect("device index out of range")
    }

    /// Role of device `d`'s class. `d < device_count()`.
    pub fn device_role(&self, d: usize) -> Role {
        assert!(d < self.device_count(), "device index out of range");
        // SAFETY: `ptr` is live.
        match unsafe { cktimg_device_role(self.ptr(), d) } {
            0 => Role::None,
            1 => Role::PowerRail,
            2 => Role::GroundRail,
            3 => Role::InputPort,
            4 => Role::OutputPort,
            r => unreachable!("role {r} is not in the header"),
        }
    }

    /// Device `d`'s orientation: (`rot` clockwise quarter turns, applied after `mirror`).
    pub fn device_orient(&self, d: usize) -> (u8, bool) {
        assert!(d < self.device_count(), "device index out of range");
        // SAFETY: `ptr` is live; `d` is in range.
        unsafe {
            (
                cktimg_device_rot(self.ptr(), d),
                cktimg_device_mirror(self.ptr(), d),
            )
        }
    }

    /// Device `d`'s origin.
    pub fn device_pos(&self, d: usize) -> [i32; 2] {
        // SAFETY: `ptr` is live; `x`, `y` are valid out-pointers.
        self.point("device", |x, y| unsafe {
            cktimg_device_pos(self.ptr(), d, x, y)
        })
    }

    /// Where to write device `d`'s name: the left end of the baseline, clear of symbols,
    /// wires and earlier names.
    ///
    /// Cost: the first call computes every device's anchor and caches them in the handle.
    pub fn device_refdes_anchor(&mut self, d: usize) -> [i32; 2] {
        let raw = self.raw.as_ptr();
        // SAFETY: `raw` is live and `&mut self` excludes other borrows during the cache fill.
        self.point("device", |x, y| unsafe {
            cktimg_device_refdes_anchor(raw, d, x, y)
        })
    }

    /// Pins of device `d`, in SPICE node order. `d < device_count()`.
    pub fn pin_count(&self, d: usize) -> usize {
        assert!(d < self.device_count(), "device index out of range");
        // SAFETY: `ptr` is live.
        unsafe { cktimg_device_pin_count(self.ptr(), d) }
    }

    /// The class terminal pin `p` of device `d` sits on; `""` past the class's terminals
    /// (such a pin sits at the device origin).
    pub fn pin_term(&self, d: usize, p: usize) -> &str {
        // SAFETY: `ptr` is live; the name lives in the library, which outlives `self`.
        unsafe { borrowed(cktimg_pin_term(self.ptr(), d, p)) }.expect("pin index out of range")
    }

    /// The net of pin `p` of device `d`; `None` when it has none.
    pub fn pin_net(&self, d: usize, p: usize) -> Option<&str> {
        assert!(p < self.pin_count(d), "pin index out of range");
        // SAFETY: `ptr` is live; the name lives as long as the handle.
        unsafe { borrowed(cktimg_pin_net(self.ptr(), d, p)) }
    }

    /// The point of pin `p` of device `d`.
    pub fn pin_xy(&self, d: usize, p: usize) -> [i32; 2] {
        // SAFETY: `ptr` is live; `x`, `y` are valid out-pointers.
        self.point("pin", |x, y| unsafe {
            cktimg_pin_xy(self.ptr(), d, p, x, y)
        })
    }

    /// Nets; a net's index is also its wire's index.
    pub fn net_count(&self) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_net_count(self.ptr()) }
    }

    /// Net `n`'s name, lowercase (ground is `0`). `n < net_count()`.
    pub fn net_name(&self, n: usize) -> &str {
        // SAFETY: `ptr` is live; the name lives as long as the handle.
        unsafe { borrowed(cktimg_net_name(self.ptr(), n)) }.expect("net index out of range")
    }

    /// Polylines drawn for net `n`; 0 when the net has no wire.
    pub fn wire_segment_count(&self, n: usize) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_wire_segment_count(self.ptr(), n) }
    }

    /// Points of polyline `s` of net `n`: a Manhattan path of at least two points,
    /// borrowed from the handle (zero-copy). `s < wire_segment_count(n)`.
    pub fn wire_segment(&self, n: usize, s: usize) -> &[[i32; 2]] {
        let mut xy: *const i32 = ptr::null();
        // SAFETY: `ptr` is live; `xy` is a valid out-pointer.
        let count = unsafe { cktimg_wire_segment_points(self.ptr(), n, s, &mut xy) };
        assert!(!xy.is_null() && count >= 2, "segment index out of range");
        // SAFETY: cktImg points `xy` at `2 * count` i32 values (x0, y0, x1, y1, …) it owns
        // until the handle drops, which outlives the returned borrow; `[i32; 2]` has the
        // layout of two consecutive i32.
        unsafe { std::slice::from_raw_parts(xy.cast::<[i32; 2]>(), count) }
    }

    /// Junction dots.
    pub fn junction_count(&self) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_junction_count(self.ptr()) }
    }

    /// Junction dot `j`.
    pub fn junction(&self, j: usize) -> [i32; 2] {
        // SAFETY: `ptr` is live; `x`, `y` are valid out-pointers.
        self.point("junction", |x, y| unsafe {
            cktimg_junction(self.ptr(), j, x, y)
        })
    }

    /// Net labels: where a wire gave way to a name. Dropping one loses connectivity.
    pub fn label_count(&self) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_label_count(self.ptr()) }
    }

    /// The net label `l` names.
    pub fn label_net(&self, l: usize) -> &str {
        // SAFETY: `ptr` is live; the name lives as long as the handle.
        unsafe { borrowed(cktimg_label_net(self.ptr(), l)) }.expect("label index out of range")
    }

    /// Label `l`'s point.
    pub fn label_xy(&self, l: usize) -> [i32; 2] {
        // SAFETY: `ptr` is live; `x`, `y` are valid out-pointers.
        self.point("label", |x, y| unsafe {
            cktimg_label_xy(self.ptr(), l, x, y)
        })
    }

    /// Which way label `l`'s text runs from its point: 0 left, 1 right, 2 up, 3 down.
    pub fn label_side(&self, l: usize) -> u8 {
        // SAFETY: `ptr` is live.
        let side = unsafe { cktimg_label_side(self.ptr(), l) };
        assert!(side < 4, "label index out of range");
        side
    }

    /// No-connect marks: pins alone on their net.
    pub fn noconnect_count(&self) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_noconnect_count(self.ptr()) }
    }

    /// No-connect mark `k`.
    pub fn noconnect(&self, k: usize) -> [i32; 2] {
        // SAFETY: `ptr` is live; `x`, `y` are valid out-pointers.
        self.point("no-connect", |x, y| unsafe {
            cktimg_noconnect(self.ptr(), k, x, y)
        })
    }

    /// The drawing's bounds `[min_x, min_y, max_x, max_y]`; `None` when it is empty.
    pub fn bounds(&self) -> Option<[i32; 4]> {
        let mut b = [0i32; 4];
        let [x0, y0, x1, y1] = &mut b;
        // SAFETY: `ptr` is live; the four out-pointers are valid.
        let ok = unsafe { cktimg_bounds(self.ptr(), x0, y0, x1, y1) };
        ok.then_some(b)
    }

    /// Device `d`'s placed bounds `[min_x, min_y, max_x, max_y]`.
    pub fn device_bounds(&self, d: usize) -> [i32; 4] {
        let mut b = [0i32; 4];
        let [x0, y0, x1, y1] = &mut b;
        // SAFETY: `ptr` is live; the four out-pointers are valid.
        let ok = unsafe { cktimg_device_bounds(self.ptr(), d, x0, y0, x1, y1) };
        assert!(ok, "device index out of range");
        b
    }

    /// Body strokes of device `d`'s class.
    pub fn device_op_count(&self, d: usize) -> usize {
        // SAFETY: `ptr` is live.
        unsafe { cktimg_device_op_count(self.ptr(), d) }
    }

    /// Kind of stroke `o` of device `d` ([`OP_LINE`] … [`OP_TEXT`]).
    pub fn device_op_kind(&self, d: usize, o: usize) -> u8 {
        // SAFETY: `ptr` is live.
        let kind = unsafe { cktimg_device_op_kind(self.ptr(), d, o) };
        assert!(kind <= OP_TEXT, "stroke index out of range");
        kind
    }

    /// Placed points of line or polyline stroke `o` of device `d` (empty for other kinds).
    ///
    /// Cost: allocates the result.
    pub fn device_op_points(&self, d: usize, o: usize) -> Vec<[i32; 2]> {
        // SAFETY: a null buffer with cap 0 only asks for the count.
        let n = unsafe { cktimg_device_op_points(self.ptr(), d, o, ptr::null_mut(), 0) };
        let mut pts = vec![[0i32; 2]; n];
        // SAFETY: `pts` holds `n` points = `2n` writable i32; cktImg writes at most `cap`
        // points.
        let got = unsafe { cktimg_device_op_points(self.ptr(), d, o, pts.as_mut_ptr().cast(), n) };
        assert_eq!(got, n);
        pts
    }

    /// Placed centre and radius of circle stroke `o` of device `d`; `None` for another kind.
    pub fn device_op_circle(&self, d: usize, o: usize) -> Option<([i32; 2], i32)> {
        let (mut x, mut y, mut r) = (0, 0, 0);
        // SAFETY: `ptr` is live; the out-pointers are valid.
        let ok = unsafe { cktimg_device_op_circle(self.ptr(), d, o, &mut x, &mut y, &mut r) };
        ok.then_some(([x, y], r))
    }

    /// Placed text stroke `o` of device `d`: the string, its centre and size; `None` for
    /// another kind.
    pub fn device_op_text(&self, d: usize, o: usize) -> Option<(&str, [i32; 2], u8)> {
        let (mut x, mut y, mut size) = (0, 0, 0u8);
        // SAFETY: `ptr` is live; the out-pointers are valid; the text lives in the library,
        // which outlives `self`.
        let text = unsafe {
            borrowed(cktimg_device_op_text(
                self.ptr(),
                d,
                o,
                &mut x,
                &mut y,
                &mut size,
            ))
        }?;
        Some((text, [x, y], size))
    }
}
