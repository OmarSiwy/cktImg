//! Common analog circuits as they appear in the textbooks (Razavi, Sedra &
//! Smith, Gray & Meyer). Device order follows the usual left-to-right reading
//! of the figure; the algorithm only uses it to break ties.

pub const Circuit = struct {
    name: []const u8,
    /// What the book's figure looks like, so a drawing can be judged.
    book: []const u8,
    spice: []const u8,
};

pub const all = [_]Circuit{
    .{
        .name = "rc_lowpass",
        .book = "Vin, series R to the right, C from the output node down to ground.",
        .spice =
        \\RC low-pass
        \\Vin in 0 ac 1
        \\R1 in out 1k
        \\C1 out 0 1n
        ,
    },
    .{
        .name = "cs_resistive",
        .book = "Rd on top from VDD, M1 below it, gate driven from the left, output tapped to the right at the drain.",
        .spice =
        \\Common-source stage, resistive load
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 0.8 ac 1
        \\Rd vdd out 5k
        \\M1 out in 0 0 nch w=10u l=0.18u
        ,
    },
    .{
        .name = "cs_degenerated",
        .book = "Like the CS stage, with Rs between the source and ground.",
        .spice =
        \\CS stage with source degeneration
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 0.8 ac 1
        \\Rd vdd out 5k
        \\M1 out in s 0 nch
        \\Rs s 0 500
        ,
    },
    .{
        .name = "cs_active_load",
        .book = "PMOS current source M2 on top (gate at Vb), NMOS M1 below, output at the shared drain.",
        .spice =
        \\CS stage, current-source load
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 0.7 ac 1
        \\Vb vb 0 1.0
        \\M2 out vb vdd vdd pch
        \\M1 out in 0 0 nch
        ,
    },
    .{
        .name = "source_follower",
        .book = "M1 drain to VDD, gate from the left, output at the source, current source Mb below.",
        .spice =
        \\Source follower
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 1.2 ac 1
        \\Vb vb 0 0.7
        \\M1 vdd in out 0 nch
        \\Mb out vb 0 0 nch
        ,
    },
    .{
        .name = "common_gate",
        .book = "Rd on top, M1 below with gate at Vb, input entering at the source from below-left, output at the drain.",
        .spice =
        \\Common-gate stage
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 0.3 ac 1
        \\Vb vb 0 1.0
        \\Rd vdd out 5k
        \\M1 out vb in 0 nch
        ,
    },
    .{
        .name = "cascode",
        .book = "Rd, M2 (gate Vb), M1 (gate Vin) in one vertical stack; output at M2's drain.",
        .spice =
        \\Cascode stage
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 dc 0.7 ac 1
        \\Vb vb 0 1.2
        \\Rd vdd out 5k
        \\M2 out vb x 0 nch
        \\M1 x in 0 0 nch
        ,
    },
    .{
        .name = "cmos_inverter",
        .book = "PMOS on top, NMOS below, gates tied to the input on the left, drains tied to the output on the right.",
        .spice =
        \\CMOS inverter
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 pulse(0 1.8 0 1n 1n 5n 10n)
        \\Mp out in vdd vdd pch
        \\Mn out in 0 0 nch
        ,
    },
    .{
        .name = "current_mirror",
        .book = "M1 (diode-connected, gate facing right) and M2 side by side, gates joined by a horizontal line, Iref above M1, load above M2.",
        .spice =
        \\NMOS current mirror
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Iref vdd a 100u
        \\M1 a a 0 0 nch
        \\M2 out a 0 0 nch
        \\Rl vdd out 5k
        ,
    },
    .{
        .name = "diff_pair_resistive",
        .book = "Symmetric: Rd1/Rd2 on top, M1/M2 side by side, tail current source below, inputs on the outer sides.",
        .spice =
        \\Differential pair, resistive loads
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vinp inp 0 dc 0.9 ac 0.5
        \\Vinn inn 0 dc 0.9 ac -0.5
        \\Rd1 vdd outn 5k
        \\Rd2 vdd outp 5k
        \\M1 outn inp tail 0 nch
        \\M2 outp inn tail 0 nch
        \\Iss tail 0 200u
        ,
    },
    .{
        .name = "ota_5t",
        .book = "PMOS mirror M3 (diode, flipped)/M4 on top, input pair M1/M2 below, tail M5 at the bottom, output at M2/M4 drains.",
        .spice =
        \\Five-transistor OTA
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vinn inn 0 dc 0.9
        \\Vinp inp 0 dc 0.9 ac 1
        \\Vb vb 0 0.7
        \\M1 x inn tail 0 nch
        \\M2 out inp tail 0 nch
        \\M3 x x vdd vdd pch
        \\M4 out x vdd vdd pch
        \\M5 tail vb 0 0 nch
        ,
    },
    .{
        .name = "two_stage_opamp",
        .book = "5T OTA on the left, second stage M6 (PMOS)/M7 (NMOS) on the right, Cc bridging the two outputs horizontally, CL to ground.",
        .spice =
        \\Two-stage Miller op-amp
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vinn inn 0 dc 0.9
        \\Vinp inp 0 dc 0.9 ac 1
        \\Vb vb 0 0.7
        \\M1 x inn tail 0 nch
        \\M2 y inp tail 0 nch
        \\M3 x x vdd vdd pch
        \\M4 y x vdd vdd pch
        \\M5 tail vb 0 0 nch
        \\M6 out y vdd vdd pch
        \\M7 out vb 0 0 nch
        \\Cc y out 1p
        \\CL out 0 2p
        ,
    },
    .{
        .name = "bandgap",
        .book = "Three PMOS side by side on top with a shared gate line, op-amp between the first two branches, Q1 | R1+Q2 | R2+Q3 branches below, Vref on the right.",
        .spice =
        \\Bandgap reference
        \\.model pch pmos level=1
        \\.model qp pnp
        \\Vdd vdd 0 2.0
        \\M1 x g vdd vdd pch
        \\M2 y g vdd vdd pch
        \\M3 vref g vdd vdd pch
        \\Q1 0 0 x qp
        \\R1 y z 1k
        \\Q2 0 0 z qp
        \\R2 vref w 10k
        \\Q3 0 0 w qp
        \\E1 g 0 y x 1e4
        ,
    },
    .{
        .name = "noninverting_amp",
        .book = "Op-amp triangle, Vin into +, Rf from output back to -, Rg from - down to ground.",
        .spice =
        \\Non-inverting amplifier, ideal op-amp
        \\Vin in 0 ac 1
        \\E1 out 0 in fb 1e5
        \\Rf out fb 10k
        \\Rg fb 0 1k
        ,
    },
};

/// Textbook circuits beyond the acceptance set: they exercise particular
/// rules (see cases.zig) and show where the drawings still fall short of the
/// book (ALGORITHM.md, open cases).
pub const beyond = [_]Circuit{
    .{
        .name = "telescopic_cascode",
        .book = "Two cascode stacks side by side, PMOS loads self-biased from outn with a gate line, tail at the bottom, outputs between the cascodes.",
        .spice =
        \\Telescopic cascode OTA
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vinp inp 0 dc 0.9 ac 1
        \\Vinn inn 0 dc 0.9
        \\Vb1 vb1 0 0.6
        \\Vb2 vb2 0 1.1
        \\Vb3 vb3 0 1.2
        \\M1 x inp tail 0 nch
        \\M2 y inn tail 0 nch
        \\M3 outn vb2 x 0 nch
        \\M4 outp vb2 y 0 nch
        \\M5 outn vb3 p 0 pch
        \\M6 outp vb3 q 0 pch
        \\M7 p outn vdd vdd pch
        \\M8 q outn vdd vdd pch
        \\M9 tail vb1 0 0 nch
        ,
    },
    .{
        .name = "sallen_key",
        .book = "R1, R2 in series into the op-amp's + input, C2 from + to ground, C1 from the R1/R2 node up to the output, output fed back to -.",
        .spice =
        \\Sallen-Key low-pass, unity-gain buffer
        \\Vin in 0 ac 1
        \\R1 in a 10k
        \\R2 a b 10k
        \\C1 a out 1n
        \\C2 b 0 1n
        \\E1 out 0 b out 1e5
        ,
    },
    .{
        .name = "ring_oscillator",
        .book = "Three inverters in a row, each output wired to the next input bar, the last output looping back to the first.",
        .spice =
        \\Three-stage ring oscillator
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Mp1 a c vdd vdd pch
        \\Mn1 a c 0 0 nch
        \\Mp2 b a vdd vdd pch
        \\Mn2 b a 0 0 nch
        \\Mp3 c b vdd vdd pch
        \\Mn3 c b 0 0 nch
        ,
    },
};
