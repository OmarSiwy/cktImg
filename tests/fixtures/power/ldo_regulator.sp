.title LDO Regulator
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vin vin 0 3.3
Vref vref 0 1.2
M1 n1 vref tail 0 nmos_1v8 W=5u L=500n
M2 gate fb tail 0 nmos_1v8 W=5u L=500n
M3 n1 n1 vin vin pmos_1v8 W=4u L=500n
M4 gate n1 vin vin pmos_1v8 W=4u L=500n
Itail 0 tail 2e-05
Mpass vout gate vin vin pmos_1v8 W=200u L=180n
R1 vout fb 180000.0
R2 fb 0 120000.0
Resr vout cap_node 0.05
Cout cap_node 0 1e-06
Rload vout 0 100
.end

