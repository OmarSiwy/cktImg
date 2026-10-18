.title TB Diff Pair Transient
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Rd1 vdd outp 10000.0
Rd2 vdd outn 10000.0
M1 outp inp tail 0 nmos_1v8 W=10u L=180n
M2 outn inn tail 0 nmos_1v8 W=10u L=180n
Itail 0 tail 0.0001
Vinp inp 0 DC 0.9 SIN(0.9 0.005 1000000.0)
Vinn inn 0 DC 0.9 SIN(0.9 -0.005 1000000.0)
.end

