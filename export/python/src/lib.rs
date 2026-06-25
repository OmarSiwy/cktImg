//! Python bindings for cktImg.
//!
//! ```python
//! import cktimg
//! svg = cktimg.render(spice)        # SPICE -> schematic SVG
//! sch = cktimg.schematic(spice)     # SPICE -> dict {devices, nets, junctions}
//! ```
//!
//! `schematic()` is the seam for the AMSNet/SINA loop: AMSNet turns an image
//! into SPICE, cktImg places & routes it, and you get back resolved geometry
//! (device positions, pin coords, wire junctions) as plain Python data to clean
//! up before re-rendering.

use pyo3::prelude::*;

/// Render SPICE/netlist text to an SVG schematic string.
#[pyfunction]
fn render(spice: &str) -> String {
    cktimg_lib::run(spice, cktimg_lib::backend::svg).0
}

/// Place & route `spice` and return the resolved schematic as a dict
/// (`json.loads` of the JSON backend): `{devices: [...], nets: [...], junctions: [...]}`.
#[pyfunction]
fn schematic<'py>(py: Python<'py>, spice: &str) -> PyResult<Bound<'py, PyAny>> {
    let json = cktimg_lib::run(spice, cktimg_lib::backend::json).0;
    // ponytail: reuse python's stdlib json instead of pulling in `pythonize`.
    py.import("json")?.call_method1("loads", (json,))
}

/// Same as [`schematic`] but returns the raw JSON string (no parsing).
#[pyfunction]
fn schematic_json(spice: &str) -> String {
    cktimg_lib::run(spice, cktimg_lib::backend::json).0
}

#[pymodule]
fn cktimg(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(render, m)?)?;
    m.add_function(wrap_pyfunction!(schematic, m)?)?;
    m.add_function(wrap_pyfunction!(schematic_json, m)?)?;
    Ok(())
}
