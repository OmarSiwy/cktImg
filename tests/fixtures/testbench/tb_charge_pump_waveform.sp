.title TB Charge Pump Waveforms
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Vclk1 phi1 0 PULSE(0 1.8 0 1e-10 1e-10 4e-09 1e-08)
Vclk2 phi2 0 PULSE(0 1.8 0 1e-10 1e-10 4e-09 1e-08)
Md1 n1 n1 vdd vdd nmos_1v8 W=5u L=180n
Cp1 n1 phi1 5e-12
Md2 n2 n2 n1 n1 nmos_1v8 W=5u L=180n
Cp2 n2 phi2 5e-12
Md3 n3 n3 n2 n2 nmos_1v8 W=5u L=180n
Cp3 n3 phi1 5e-12
Md4 vout vout n3 n3 nmos_1v8 W=5u L=180n
Cout vout 0 2e-11
Rload vout 0 500000.0
.end

