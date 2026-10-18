.title NMOS Current Mirror
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Iref vdd iref 5e-05
M1 iref iref 0 0 nmos_1v8 W=2u L=500n
M2 iout iref 0 0 nmos_1v8 W=2u L=500n
Rload vdd iout 10000.0
.end

