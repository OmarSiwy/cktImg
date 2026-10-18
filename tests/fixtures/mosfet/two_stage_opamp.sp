.title Two-Stage Op-Amp
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vinp inp 0 0.9
Vinn inn 0 0.9
M1 n1 inp tail 0 nmos_1v8 W=10u L=500n
M2 n2 inn tail 0 nmos_1v8 W=10u L=500n
M3 n1 n1 vdd vdd pmos_1v8 W=5u L=500n
M4 n2 n1 vdd vdd pmos_1v8 W=5u L=500n
Itail 0 tail 0.0001
M5 vout n2 0 0 nmos_1v8 W=40u L=180n
Iload vdd vout 0.0005
Cc n2 vout 2e-12
Rz n2 cc_node 500
Cc2 cc_node vout 2e-12
Cload vout 0 5e-12
.end

