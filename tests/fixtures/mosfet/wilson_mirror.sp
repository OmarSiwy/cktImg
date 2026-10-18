.title Wilson Current Mirror
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Iref vdd iref 5e-05
M1 n1 iref 0 0 nmos_1v8 W=2u L=500n
M2 iref n1 0 0 nmos_1v8 W=2u L=500n
M3 iout n1 0 0 nmos_1v8 W=2u L=500n
Vout vdd iout 0
.end

