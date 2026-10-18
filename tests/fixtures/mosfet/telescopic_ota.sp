.title Telescopic OTA
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vinp inp 0 0.9
Vinn inn 0 0.9
Vbn vbn 0 0.6
Vbp vbp 0 1.2
Vbpt vbpt 0 1.0
Mp1 n1 vbpt vdd vdd pmos_1v8 W=10u L=500n
Mp2 n2 vbpt vdd vdd pmos_1v8 W=10u L=500n
Mp3 outp vbp n1 vdd pmos_1v8 W=10u L=500n
Mp4 outn vbp n2 vdd pmos_1v8 W=10u L=500n
Mn1 n3 inp tail 0 nmos_1v8 W=10u L=180n
Mn2 n4 inn tail 0 nmos_1v8 W=10u L=180n
Mn3 outp vbn n3 0 nmos_1v8 W=10u L=500n
Mn4 outn vbn n4 0 nmos_1v8 W=10u L=500n
Itail 0 tail 0.0002
.end

