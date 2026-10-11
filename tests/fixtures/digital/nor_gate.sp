.title CMOS NOR Gate
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Va va 0 0
Vb vb 0 0
Mp1 mid va vdd vdd pmos_1v8 W=4u L=180n
Mp2 vout vb mid vdd pmos_1v8 W=4u L=180n
Mn1 vout va 0 0 nmos_1v8 W=1u L=180n
Mn2 vout vb 0 0 nmos_1v8 W=1u L=180n
Cload vout 0 1e-14
.end

