.title 4-bit Shift Register
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vclk clk 0 PULSE(0 1.8 0 5e-11 5e-11 5e-09 1e-08)
Mp_clkb clkb clk vdd vdd pmos_1v8 W=2u L=180n
Mn_clkb clkb clk 0 0 nmos_1v8 W=1u L=180n
Vdin din 0 PULSE(1.8 0 0 5e-11 5e-11 1e-08 4e-08)
Mn_m0 din clkb master0 0 nmos_1v8 W=1u L=180n
Mp_m0 din clk master0 vdd pmos_1v8 W=2u L=180n
Mp_mi0 mb0 master0 vdd vdd pmos_1v8 W=1u L=180n
Mn_mi0 mb0 master0 0 0 nmos_1v8 W=500n L=180n
Ccm0 master0 0 2e-15
Mn_s0 master0 clk q[0] 0 nmos_1v8 W=1u L=180n
Mp_s0 master0 clkb q[0] vdd pmos_1v8 W=2u L=180n
Mp_si0 sb0 q[0] vdd vdd pmos_1v8 W=1u L=180n
Mn_si0 sb0 q[0] 0 0 nmos_1v8 W=500n L=180n
Ccs0 q[0] 0 2e-15
Mn_m1 q[0] clkb master1 0 nmos_1v8 W=1u L=180n
Mp_m1 q[0] clk master1 vdd pmos_1v8 W=2u L=180n
Mp_mi1 mb1 master1 vdd vdd pmos_1v8 W=1u L=180n
Mn_mi1 mb1 master1 0 0 nmos_1v8 W=500n L=180n
Ccm1 master1 0 2e-15
Mn_s1 master1 clk q[1] 0 nmos_1v8 W=1u L=180n
Mp_s1 master1 clkb q[1] vdd pmos_1v8 W=2u L=180n
Mp_si1 sb1 q[1] vdd vdd pmos_1v8 W=1u L=180n
Mn_si1 sb1 q[1] 0 0 nmos_1v8 W=500n L=180n
Ccs1 q[1] 0 2e-15
Mn_m2 q[1] clkb master2 0 nmos_1v8 W=1u L=180n
Mp_m2 q[1] clk master2 vdd pmos_1v8 W=2u L=180n
Mp_mi2 mb2 master2 vdd vdd pmos_1v8 W=1u L=180n
Mn_mi2 mb2 master2 0 0 nmos_1v8 W=500n L=180n
Ccm2 master2 0 2e-15
Mn_s2 master2 clk q[2] 0 nmos_1v8 W=1u L=180n
Mp_s2 master2 clkb q[2] vdd pmos_1v8 W=2u L=180n
Mp_si2 sb2 q[2] vdd vdd pmos_1v8 W=1u L=180n
Mn_si2 sb2 q[2] 0 0 nmos_1v8 W=500n L=180n
Ccs2 q[2] 0 2e-15
Mn_m3 q[2] clkb master3 0 nmos_1v8 W=1u L=180n
Mp_m3 q[2] clk master3 vdd pmos_1v8 W=2u L=180n
Mp_mi3 mb3 master3 vdd vdd pmos_1v8 W=1u L=180n
Mn_mi3 mb3 master3 0 0 nmos_1v8 W=500n L=180n
Ccm3 master3 0 2e-15
Mn_s3 master3 clk q[3] 0 nmos_1v8 W=1u L=180n
Mp_s3 master3 clkb q[3] vdd pmos_1v8 W=2u L=180n
Mp_si3 sb3 q[3] vdd vdd pmos_1v8 W=1u L=180n
Mn_si3 sb3 q[3] 0 0 nmos_1v8 W=500n L=180n
Ccs3 q[3] 0 2e-15
.end

