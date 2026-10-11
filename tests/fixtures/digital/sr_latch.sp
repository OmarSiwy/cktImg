.title SR Latch
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vs vs 0 PULSE(0 1.8 0 1e-10 1e-10 1e-09 1e-08)
Vr vr 0 PULSE(0 1.8 0 1e-10 1e-10 1e-09 1e-08)
Mp1a mid1 vs vdd vdd pmos_1v8 W=4u L=180n
Mp1b q qbar mid1 vdd pmos_1v8 W=4u L=180n
Mn1a q vs 0 0 nmos_1v8 W=1u L=180n
Mn1b q qbar 0 0 nmos_1v8 W=1u L=180n
Mp2a mid2 vr vdd vdd pmos_1v8 W=4u L=180n
Mp2b qbar q mid2 vdd pmos_1v8 W=4u L=180n
Mn2a qbar vr 0 0 nmos_1v8 W=1u L=180n
Mn2b qbar q 0 0 nmos_1v8 W=1u L=180n
.end

