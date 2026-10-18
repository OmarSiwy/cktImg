//! Every analysis ngspice accepts as a dot-command, with the parameters it
//! needs besides the devices themselves.
//!
//! Source of truth: ngspice `src/spicelib/parser/inp2dot.c` (master, 2026)
//! and the ngspice manual, chapter "Analyses". Syntax in each doc comment
//! uses `<...>` for optional fields.
//!
//! Node and device references are already resolved to ids, so a simulator
//! never looks a name up again. Names that don't exist are rejected by the
//! parser, not discovered halfway through a simulation.
//!
//! Not included, on purpose:
//!   * `.hb` (harmonic balance): compile-time experimental (`WITH_HB`),
//!     undocumented. The parser reports `error.UnsupportedAnalysis`.
//!   * Transient noise: not a command; it is enabled by `trnoise`/`trrandom`
//!     source functions and runs inside `.tran`.
//!   * `.four`, `.meas`, `.print`, `.save`: post-processing/output requests
//!     on another analysis's results, not analyses.

const std = @import("std");
const csr = @import("csr.zig");

const VertexId = csr.VertexId;
const EdgeId = csr.EdgeId;

pub const Kind = enum(u8) { op, dc, ac, disto, noise, pz, sens, tf, tran, pss, sp };

pub const Analysis = union(Kind) {
    /// `.op`
    op,
    /// `.dc srcnam vstart vstop vincr <src2 start2 stop2 incr2>`
    dc: Dc,
    /// `.ac {dec|oct|lin} np fstart fstop`
    ac: FreqSweep,
    /// `.disto {dec|oct|lin} np fstart fstop <f2overf1>`
    disto: Disto,
    /// `.noise v(output <,ref>) src {dec|oct|lin} np fstart fstop <pts_per_summary>`
    noise: Noise,
    /// `.pz node1 node2 node3 node4 {cur|vol} {pol|zer|pz}`
    pz: Pz,
    /// `.sens outvar <filter...> <dc | ac {dec|oct|lin} np fstart fstop>`
    sens: Sens,
    /// `.tf outvar insrc`
    tf: Tf,
    /// `.tran tstep tstop <tstart <tmax>> <uic>`
    tran: Tran,
    /// `.pss gfreq tstab oscnode psspoints harms sciter steadycoeff <uic>`
    pss: Pss,
    /// `.sp {dec|oct|lin} np fstart fstop <donoise>`
    sp: Sp,
};

// ---------------------------------------------------------------------------
// Shared building blocks. Five analyses sweep frequency the same way, so
// they share one struct instead of five copies of the same four fields.
// ---------------------------------------------------------------------------

pub const SweepScale = enum(u8) {
    /// `points` per decade
    dec,
    /// `points` per octave
    oct,
    /// `points` total, linearly spaced
    lin,
};

pub const FreqSweep = struct {
    scale: SweepScale,
    points: u32,
    fstart: f64,
    fstop: f64,
};

/// `v(pos)` or `v(pos, neg)`. `neg` is the ground net when omitted.
pub const VoltageProbe = struct {
    pos: VertexId,
    neg: VertexId,
};

/// An output variable: a node voltage or the current through a voltage
/// source, `i(vxxx)`.
pub const Output = union(enum) {
    voltage: VoltageProbe,
    current: EdgeId,
};

// ---------------------------------------------------------------------------
// Per-analysis parameters.
// ---------------------------------------------------------------------------

pub const DcTarget = union(enum) {
    /// An independent V or I source, or a resistor.
    device: EdgeId,
    /// The keyword `temp`: sweep the circuit temperature (°C).
    temperature,
};

pub const DcSweep = struct {
    target: DcTarget,
    start: f64,
    stop: f64,
    /// Never zero (ngspice rejects a zero increment).
    step: f64,
};

pub const Dc = struct {
    /// Inner loop.
    sweep: DcSweep,
    /// Optional outer loop: `sweep` runs completely for each of its values.
    outer: ?DcSweep,
};

pub const Disto = struct {
    sweep: FreqSweep,
    /// When given, a two-tone intermodulation analysis is run with
    /// f2 = f2overf1 · f1 (must be in (0, 1)). When null, harmonic analysis.
    f2_over_f1: ?f64,
};

pub const Noise = struct {
    output: VoltageProbe,
    /// Independent source that the output noise is referred back to.
    input: EdgeId,
    sweep: FreqSweep,
    /// Print per-device contributions every N frequency points; 0 = never.
    points_per_summary: u32,
};

pub const Pz = struct {
    pub const Transfer = enum(u8) {
        /// (output voltage) / (input current)
        cur,
        /// (output voltage) / (input voltage)
        vol,
    };
    pub const Solve = enum(u8) { poles, zeros, both };

    input_pos: VertexId,
    input_neg: VertexId,
    output_pos: VertexId,
    output_neg: VertexId,
    transfer: Transfer,
    solve: Solve,
};

pub const Sens = struct {
    pub const Mode = union(enum) {
        dc,
        ac: FreqSweep,
    };

    output: Output,
    /// Optional name patterns restricting which parameters are perturbed.
    /// Empty means all. Slices live in the netlist's arena.
    filters: []const []const u8,
    mode: Mode,
};

pub const Tf = struct {
    output: Output,
    /// Independent source used as the small-signal input.
    input: EdgeId,
};

pub const Tran = struct {
    tstep: f64,
    tstop: f64,
    /// Output is not stored before this time. Default 0.
    tstart: f64,
    /// Maximum internal step; null lets the simulator choose.
    tmax: ?f64,
    /// Skip the initial operating point; use IC= values instead.
    uic: bool,
};

pub const Pss = struct {
    /// Guessed fundamental frequency.
    fguess: f64,
    /// Transient time allowed for the circuit to settle before shooting.
    tstab: f64,
    /// Node whose waveform is monitored for the oscillation.
    osc_node: VertexId,
    /// Time points per period in the output (should exceed 2 · harmonics).
    points: u32,
    harmonics: u32,
    /// Maximum shooting iterations (ngspice suggests 50).
    sc_iter: u32,
    /// Weight of the global convergence error (ngspice suggests 1e-3).
    steady_coeff: f64,
    uic: bool,
};

pub const Sp = struct {
    sweep: FreqSweep,
    /// Also compute the noise correlation matrix and NF/NFmin/Rn/Sopt.
    noise: bool,
};

comptime {
    // Few analyses exist per netlist, so an array of this union (AoS) is the
    // right layout here. The assert just keeps the union from growing
    // unnoticed.
    std.debug.assert(@sizeOf(Analysis) <= 96);
}
