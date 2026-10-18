.title 4-bit Current DAC
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vbias vbias 0 0.6
Vcode[0] code[0] 0 0
Vcode[1] code[1] 0 1.8
Vcode[2] code[2] 0 0
Vcode[3] code[3] 0 1.8
Mcs0 src[0] vbias 0 0 nmos_1v8 W=2u L=1u
Msw_on0 iout code[0] src[0] 0 nmos_1v8 W=2u L=180n
Msw_off0 idummy code_b[0] src[0] 0 nmos_1v8 W=2u L=180n
Mp_inv0 code_b[0] code[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_inv0 code_b[0] code[0] 0 0 nmos_1v8 W=1u L=180n
Mcs1 src[1] vbias 0 0 nmos_1v8 W=4u L=1u
Msw_on1 iout code[1] src[1] 0 nmos_1v8 W=2u L=180n
Msw_off1 idummy code_b[1] src[1] 0 nmos_1v8 W=2u L=180n
Mp_inv1 code_b[1] code[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_inv1 code_b[1] code[1] 0 0 nmos_1v8 W=1u L=180n
Mcs2 src[2] vbias 0 0 nmos_1v8 W=8u L=1u
Msw_on2 iout code[2] src[2] 0 nmos_1v8 W=2u L=180n
Msw_off2 idummy code_b[2] src[2] 0 nmos_1v8 W=2u L=180n
Mp_inv2 code_b[2] code[2] vdd vdd pmos_1v8 W=2u L=180n
Mn_inv2 code_b[2] code[2] 0 0 nmos_1v8 W=1u L=180n
Mcs3 src[3] vbias 0 0 nmos_1v8 W=16u L=1u
Msw_on3 iout code[3] src[3] 0 nmos_1v8 W=2u L=180n
Msw_off3 idummy code_b[3] src[3] 0 nmos_1v8 W=2u L=180n
Mp_inv3 code_b[3] code[3] vdd vdd pmos_1v8 W=2u L=180n
Mn_inv3 code_b[3] code[3] 0 0 nmos_1v8 W=1u L=180n
Rout vdd iout 5000.0
Rdummy vdd idummy 5000.0
Cout iout 0 1e-12
.end

