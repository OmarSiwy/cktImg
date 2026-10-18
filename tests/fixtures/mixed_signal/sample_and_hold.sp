.title Sample and Hold
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vin vin 0 DC 0.9 SIN(0.9 0.4 10000.0)
Vclk phi 0 PULSE(0 1.8 0 1e-10 1e-10 2.5e-08 1e-07)
Vclkb phib 0 PULSE(1.8 0 0 1e-10 1e-10 2.5e-08 1e-07)
Mns vin phi vhold 0 nmos_1v8 W=2u L=180n
Mps vin phib vhold vdd pmos_1v8 W=4u L=180n
Chold vhold 0 1e-12
Mbuf vdd vhold vout 0 nmos_1v8 W=10u L=180n
Ibias vout 0 0.0001
.end

