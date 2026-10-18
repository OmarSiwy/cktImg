.title Bandgap Reference
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
.model npn_1x npn (bf=100 is=1e-15)
.model npn_8x npn (bf=100 is=8e-15)
Vcc vcc 0 3.3
Eamp opout 0 va vb 1000000.0
Mp1 va opout vcc vcc pmos_1v8 W=10u L=1u
Mp2 vb opout vcc vcc pmos_1v8 W=10u L=1u
Q1 0 0 va npn_1x
R1 va vref 10000.0
Q2 0 0 n1 npn_8x
Rptat vb n1 7400.0
R2 n1 vref 10000.0
Rout vref 0 100000.0
.end

