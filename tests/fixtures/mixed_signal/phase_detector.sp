.title Phase Frequency Detector
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vref fref 0 PULSE(0 1.8 0 5e-11 5e-11 5e-09 1e-08)
Vfb ffb 0 PULSE(0 1.8 0 5e-11 5e-11 5e-09 1e-08)
Mp_up1 n_up fref vdd vdd pmos_1v8 W=2u L=180n
Mn_up1 n_up fref rst 0 nmos_1v8 W=1u L=180n
Mp_up2 up n_up vdd vdd pmos_1v8 W=2u L=180n
Mn_up2 up n_up 0 0 nmos_1v8 W=1u L=180n
Mp_dn1 n_dn ffb vdd vdd pmos_1v8 W=2u L=180n
Mn_dn1 n_dn ffb rst 0 nmos_1v8 W=1u L=180n
Mp_dn2 dn n_dn vdd vdd pmos_1v8 W=2u L=180n
Mn_dn2 dn n_dn 0 0 nmos_1v8 W=1u L=180n
Mp_rst1 nand_out up vdd vdd pmos_1v8 W=2u L=180n
Mp_rst2 nand_out dn vdd vdd pmos_1v8 W=2u L=180n
Mn_rst1 nand_out up nand_mid 0 nmos_1v8 W=2u L=180n
Mn_rst2 nand_mid dn 0 0 nmos_1v8 W=2u L=180n
Mp_inv rst nand_out vdd vdd pmos_1v8 W=2u L=180n
Mn_inv rst nand_out 0 0 nmos_1v8 W=1u L=180n
.end

