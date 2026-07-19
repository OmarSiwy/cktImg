//! Runtime class registry: host-installed anchor overrides and host-defined classes.

use crate::catalog::{BY_NAME, CLASSES};
use crate::class::{DeviceClass, SymbolRole, Terminal, TerminalRole};
use crate::geom::{CELL_WIDTH, DrawOp, Pt};

/// Index of a class by name, for the loader to stamp into the IR's `SymbolIdx`.
/// Covers builtins and host classes appended by [`install_host_classes`];
/// among same-name host classes the LATEST registration wins.
pub fn class_of(name: &str) -> Option<usize> {
    BY_NAME.get(name).copied().or_else(|| {
        let lc = name.to_ascii_lowercase();
        EXTRA
            .read()
            .unwrap()
            .iter()
            .rposition(|(n, _)| *n == lc)
            .map(|i| CLASSES.len() + i)
    })
}

/// Is `name` one of the builtin classes? Host classes may not shadow these.
pub fn is_builtin(name: &str) -> bool {
    BY_NAME.contains_key(name.to_ascii_lowercase().as_str())
}

/// Class table in effect: builtin [`CLASSES`] unless a host installed
/// anchor overrides. Set once, before any parse/layout.
static ACTIVE: std::sync::OnceLock<&'static [DeviceClass]> = std::sync::OnceLock::new();

/// The class at an index (i.e. what a `SymbolIdx` resolves to): builtin
/// (possibly anchor-overridden) below `CLASSES.len()`, host-registered above.
pub fn class_at(id: usize) -> &'static DeviceClass {
    let table = ACTIVE.get().copied().unwrap_or(CLASSES);
    if id < table.len() {
        &table[id]
    } else {
        EXTRA.read().unwrap()[id - CLASSES.len()].1
    }
}

/// Replace terminal anchor points per class, for hosts whose symbol pin
/// geometry differs from the builtin canonical symbols (e.g. a schematic
/// editor importing placed-and-routed output must have wires land on *its*
/// pins). Terminal count, names, and roles are fixed by the class; only the
/// anchor points move. Bounding boxes and routing pick the new anchors up
/// automatically, since both derive from [`DeviceClass::terminals`].
///
/// Call once, before any parse/layout. Panics on an unknown class, an anchor
/// count mismatch, or a second call — geometry must not change mid-run.
pub fn install_anchor_overrides(overrides: &[(&str, &[Pt])]) {
    install_host_classes(overrides, &[]);
}

/// A host-defined component class, categorized at runtime: a symbol whose
/// terminals (names, roles, anchor points) are only known when the host runs —
/// a schematic editor's project symbols, testbench DUT boxes, etc. Instances
/// resolve by `name` wherever a builtin would (element cards, `X` masters), so
/// `XDUT in out vdd gnd my_opamp` places `my_opamp` as a box device instead of
/// flattening or skipping it.
#[derive(Clone, Debug)]
pub struct HostClass {
    pub name: String,
    /// (terminal name, electrical role, anchor point). Roles drive placement:
    /// control terminals (Gate/Base) attract driving nets, conducting ones
    /// join the spine walk.
    pub terminals: Vec<(String, TerminalRole, Pt)>,
}

/// Host classes appended after the builtin table: (lowercased name, leaked
/// class). Append-only under a lock — indices, once handed out, never move —
/// so a long-lived host (a schematic editor) can register new project
/// symbols between parses without violating "geometry must not change".
static EXTRA: std::sync::RwLock<Vec<(String, &'static DeviceClass)>> =
    std::sync::RwLock::new(Vec::new());

/// [`install_anchor_overrides`] plus host-defined runtime classes appended to
/// the table. Call once, before any parse/layout; panics on a second call.
pub fn install_host_classes(overrides: &[(&str, &[Pt])], extra: &[HostClass]) {
    let mut table: Vec<DeviceClass> = CLASSES.to_vec();
    for (name, anchors) in overrides {
        let idx = class_of(name).unwrap_or_else(|| panic!("unknown device class '{name}'"));
        let terms = table[idx].terminals;
        assert_eq!(
            anchors.len(),
            terms.len(),
            "class '{name}': {} anchors for {} terminals",
            anchors.len(),
            terms.len()
        );
        let new: Vec<Terminal> = terms
            .iter()
            .zip(anchors.iter())
            .map(|(t, &at)| Terminal { at, ..*t })
            .collect();
        table[idx].terminals = Box::leak(new.into_boxed_slice());
    }
    // Leaked once per process by design: the table lives for the program.
    let leaked: &'static [DeviceClass] = Box::leak(table.into_boxed_slice());
    assert!(
        ACTIVE.set(leaked).is_ok(),
        "device anchor overrides already installed"
    );
    for hc in extra {
        register_host_class(hc);
    }
}

/// Register one host class at runtime, appending it to the class table and
/// returning its index. Callable any time between parses (append-only: an
/// index, once handed out, never changes meaning). Re-registering an
/// identical (name, terminals) class returns the existing index; a same-name
/// class with different geometry panics — placed IRs referencing the old
/// index must stay valid.
pub fn register_host_class(hc: &HostClass) -> usize {
    assert!(
        !hc.terminals.is_empty(),
        "host class '{}': no terminals",
        hc.name
    );
    assert!(
        BY_NAME.get(hc.name.to_ascii_lowercase().as_str()).is_none(),
        "host class '{}' shadows a builtin",
        hc.name
    );
    let lc = hc.name.to_ascii_lowercase();
    let mut extra = EXTRA.write().unwrap();
    if let Some(i) = extra.iter().rposition(|(n, _)| *n == lc) {
        let existing = extra[i].1;
        let same = existing.terminals.len() == hc.terminals.len()
            && existing
                .terminals
                .iter()
                .zip(hc.terminals.iter())
                .all(|(t, (n, r, at))| t.name == n && t.role == *r && t.at == *at);
        if same {
            return CLASSES.len() + i;
        }
        // Changed geometry (the host edited the symbol): append a NEW entry
        // under the same name — indices already handed out stay valid, and
        // name lookups resolve to the latest version.
    }
    let terminals: Vec<Terminal> = hc
        .terminals
        .iter()
        .map(|(n, role, at)| Terminal {
            name: Box::leak(n.clone().into_boxed_str()),
            role: *role,
            at: *at,
        })
        .collect();
    // Body: the terminal hull as a closed box outline, so collision and
    // rendering both see the component the host will draw.
    let (mut xmin, mut ymin, mut xmax, mut ymax) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for (_, _, at) in &hc.terminals {
        xmin = xmin.min(at.x);
        ymin = ymin.min(at.y);
        xmax = xmax.max(at.x);
        ymax = ymax.max(at.y);
    }
    // A degenerate hull (collinear pins) still gets a visible body.
    if xmin == xmax {
        xmin -= CELL_WIDTH / 4;
        xmax += CELL_WIDTH / 4;
    }
    if ymin == ymax {
        ymin -= CELL_WIDTH / 4;
        ymax += CELL_WIDTH / 4;
    }
    let outline: &'static [Pt] = Box::leak(
        vec![
            Pt { x: xmin, y: ymin },
            Pt { x: xmax, y: ymin },
            Pt { x: xmax, y: ymax },
            Pt { x: xmin, y: ymax },
            Pt { x: xmin, y: ymin },
        ]
        .into_boxed_slice(),
    );
    let draw: &'static [DrawOp] = Box::leak(vec![DrawOp::Polyline(outline)].into_boxed_slice());
    let class: &'static DeviceClass = Box::leak(Box::new(DeviceClass {
        name: Box::leak(hc.name.clone().into_boxed_str()),
        role: SymbolRole::None,
        terminals: Box::leak(terminals.into_boxed_slice()),
        draw,
        prefix: 'X',
        default_value: "",
    }));
    extra.push((lc, class));
    CLASSES.len() + extra.len() - 1
}
