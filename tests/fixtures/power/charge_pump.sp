.title Dickson Charge Pump
.model diode_1v8 D (is=1e-14 n=1.05)
Vdd vdd 0 1.8
Vclk1 phi1 0 PULSE(0 1.8 0 1e-10 1e-10 5e-09 1e-08)
Vclk2 phi2 0 PULSE(0 1.8 0 1e-10 1e-10 5e-09 1e-08)
D1 vdd n1 diode_1v8
Cp1 n1 phi1 1e-11
D2 n1 n2 diode_1v8
Cp2 n2 phi2 1e-11
D3 n2 n3 diode_1v8
Cp3 n3 phi1 1e-11
D4 n3 vout diode_1v8
Cout vout 0 5e-11
Rload vout 0 100000.0
.end

