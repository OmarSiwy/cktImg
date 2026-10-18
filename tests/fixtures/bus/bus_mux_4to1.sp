.title 4:1 Analog Mux
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vin[0] in[0] 0 0.3
Vin[1] in[1] 0 0.6
Vin[2] in[2] 0 0.9
Vin[3] in[3] 0 1.2
Vsel[0] sel[0] 0 0
Vsel[1] sel[1] 0 1.8
Mp_s0b sel_b[0] sel[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_s0b sel_b[0] sel[0] 0 0 nmos_1v8 W=1u L=180n
Mp_s1b sel_b[1] sel[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_s1b sel_b[1] sel[1] 0 0 nmos_1v8 W=1u L=180n
Mn_tg0 in[0] sel_b[1] vout 0 nmos_1v8 W=2u L=180n
Mp_tg0 in[0] sel[1] vout vdd pmos_1v8 W=4u L=180n
Mn_tg1 in[1] sel[0] vout 0 nmos_1v8 W=2u L=180n
Mp_tg1 in[1] sel_b[0] vout vdd pmos_1v8 W=4u L=180n
Mn_tg2 in[2] sel[1] vout 0 nmos_1v8 W=2u L=180n
Mp_tg2 in[2] sel_b[1] vout vdd pmos_1v8 W=4u L=180n
Mn_tg3 in[3] sel[1] vout 0 nmos_1v8 W=2u L=180n
Mp_tg3 in[3] sel_b[1] vout vdd pmos_1v8 W=4u L=180n
Cout vout 0 1e-13
.end

