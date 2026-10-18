.title Folded Cascode OTA
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vinp inp 0 0.9
Vinn inn 0 0.9
Vbn vbn 0 0.5
Vbp vbp 0 1.3
Mp1 n1 inp vdd vdd pmos_1v8 W=20u L=500n
Mp2 n2 inn vdd vdd pmos_1v8 W=20u L=500n
Mn1 n1 vbn n3 0 nmos_1v8 W=5u L=500n
Mn2 n2 vbn n4 0 nmos_1v8 W=5u L=500n
Ib1 0 n3 0.0001
Ib2 0 n4 0.0001
Mp3 outp vbp n5 vdd pmos_1v8 W=10u L=500n
Mp4 outn vbp n6 vdd pmos_1v8 W=10u L=500n
Mp5 n5 n5 vdd vdd pmos_1v8 W=10u L=500n
Mp6 n6 n6 vdd vdd pmos_1v8 W=10u L=500n
Itail vdd tail_node 0.0002
.end

