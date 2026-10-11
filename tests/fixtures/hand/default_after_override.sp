* A subckt default that references another parameter, overridden by the call.
* ngspice 45 evaluates wp after the override (v(n1) = 10); see the XFAIL in roundtrip.rs.
.subckt dv a wn=1 wp={2*wn}
R1 a 0 {wp}
.ends
X1 n1 dv wn=5
I1 0 n1 1
.op
