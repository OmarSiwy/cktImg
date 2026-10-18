.title CS Active Load
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vin vin 0 0.7
Vbias vbias 0 1.0
M1 vout vin 0 0 nmos_1v8 W=5u L=500n
M2 vout vbias vdd vdd pmos_1v8 W=10u L=500n
.end

