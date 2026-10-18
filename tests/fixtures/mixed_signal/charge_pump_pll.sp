.title PLL Charge Pump
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vup up 0 PULSE(0 1.8 0 5e-11 5e-11 5e-10 1e-08)
Vdn dn 0 PULSE(0 1.8 0 5e-11 5e-11 2e-10 1e-08)
Mp1 vdd vdd src_p vdd pmos_1v8 W=10u L=500n
Mp_sw src_p up_b vctrl vdd pmos_1v8 W=5u L=180n
Mn1 src_n vbn 0 0 nmos_1v8 W=5u L=500n
Mn_sw vctrl dn src_n 0 nmos_1v8 W=5u L=180n
Vbn vbn 0 0.5
Mp_inv up_b up vdd vdd pmos_1v8 W=2u L=180n
Mn_inv up_b up 0 0 nmos_1v8 W=1u L=180n
Rz vctrl n_filt 5000.0
C1 n_filt 0 1e-11
C2 vctrl 0 1e-12
.end

