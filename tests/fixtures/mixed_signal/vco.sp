.title Current-Starved VCO
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vctrl vctrl 0 0.9
Mpb1 vdd_s1 vctrl vdd vdd pmos_1v8 W=2u L=180n
Mp1 n1 n3 vdd_s1 vdd pmos_1v8 W=2u L=180n
Mn1 n1 n3 gnd_s1 0 nmos_1v8 W=1u L=180n
Mnb1 gnd_s1 vctrl 0 0 nmos_1v8 W=1u L=180n
Mpb2 vdd_s2 vctrl vdd vdd pmos_1v8 W=2u L=180n
Mp2 n2 n1 vdd_s2 vdd pmos_1v8 W=2u L=180n
Mn2 n2 n1 gnd_s2 0 nmos_1v8 W=1u L=180n
Mnb2 gnd_s2 vctrl 0 0 nmos_1v8 W=1u L=180n
Mpb3 vdd_s3 vctrl vdd vdd pmos_1v8 W=2u L=180n
Mp3 n3 n2 vdd_s3 vdd pmos_1v8 W=2u L=180n
Mn3 n3 n2 gnd_s3 0 nmos_1v8 W=1u L=180n
Mnb3 gnd_s3 vctrl 0 0 nmos_1v8 W=1u L=180n
C1 n1 0 1e-14
C2 n2 0 1e-14
C3 n3 0 1e-14
.end

