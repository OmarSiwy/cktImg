"""Minimal stand-in for the `pyspice_rs.Circuit` API the salvaged net2schem fixtures use.

`gen.py` runs each fixture script with this module first on `sys.path` and stores its
stdout as `<category>/<name>.sp`. Only the calls the fixtures make are implemented; the
output follows ngspice card syntax (PySpice's element-name convention: kind letter +
`name`).
"""


def _v(x):
    return repr(x) if isinstance(x, float) else str(x)


class Circuit:
    gnd = "0"

    def __init__(self, title):
        self.title = title
        self.lines = []
        self.models = []

    def _add(self, *tokens):
        self.lines.append(" ".join(_v(t) for t in tokens))

    def R(self, name, positive, negative, value):
        self._add("R" + name, positive, negative, value)

    def C(self, name, positive, negative, value):
        self._add("C" + name, positive, negative, value)

    def L(self, name, positive, negative, value):
        self._add("L" + name, positive, negative, value)

    def V(self, name, positive, negative, value):
        self._add("V" + name, positive, negative, value)

    def I(self, name, positive, negative, value):
        self._add("I" + name, positive, negative, value)

    def D(self, name, anode, cathode, model):
        self._add("D" + name, anode, cathode, model)

    def Q(self, name, collector, base, emitter, model):
        self._add("Q" + name, collector, base, emitter, model)

    def M(self, name, drain, gate, source, bulk, model, **params):
        self._add("M" + name, drain, gate, source, bulk, model,
                  *("%s=%s" % (k, _v(v)) for k, v in params.items()))

    def E(self, name, positive, negative, control_positive, control_negative, voltage_gain):
        self._add("E" + name, positive, negative, control_positive, control_negative, voltage_gain)

    def X(self, name, subckt, *nodes):
        self._add("X" + name, *nodes, subckt)

    def PulseVoltageSource(self, name, positive, negative, initial_value, pulsed_value,
                           rise_time, fall_time, pulse_width, period, delay_time=0):
        spec = "PULSE(%s)" % " ".join(_v(v) for v in (
            initial_value, pulsed_value, delay_time, rise_time, fall_time, pulse_width, period))
        self._add("V" + name, positive, negative, spec)

    def SinusoidalVoltageSource(self, name, positive, negative, dc_offset, offset,
                                amplitude, frequency):
        spec = "DC %s SIN(%s %s %s)" % (_v(dc_offset), _v(offset), _v(amplitude), _v(frequency))
        self._add("V" + name, positive, negative, spec)

    def model(self, name, kind, **params):
        body = " ".join("%s=%s" % (k, _v(v)) for k, v in params.items())
        self.models.append(".model %s %s (%s)" % (name, kind, body))

    def raw_spice(self, line):
        self.lines.append(line)

    def __str__(self):
        return "\n".join([".title " + self.title] + self.models + self.lines + [".end"]) + "\n"
