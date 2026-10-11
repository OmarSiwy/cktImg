.title CMOS Inverter
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vin vin 0 0.9
Mp vout vin vdd vdd pmos_1v8 W=2u L=180n
Mn vout vin 0 0 nmos_1v8 W=1u L=180n
.end

