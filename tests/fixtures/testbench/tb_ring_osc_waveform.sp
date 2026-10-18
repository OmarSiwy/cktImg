.title TB Ring Oscillator Waveforms
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Mp1 n1 n3 vdd vdd pmos_1v8 W=2u L=180n
Mn1 n1 n3 0 0 nmos_1v8 W=1u L=180n
Mp2 n2 n1 vdd vdd pmos_1v8 W=2u L=180n
Mn2 n2 n1 0 0 nmos_1v8 W=1u L=180n
Mp3 n3 n2 vdd vdd pmos_1v8 W=2u L=180n
Mn3 n3 n2 0 0 nmos_1v8 W=1u L=180n
C1 n1 0 1e-14
C2 n2 0 1e-14
C3 n3 0 1e-14
.end

