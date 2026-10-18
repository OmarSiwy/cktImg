.title CMOS Comparator
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vin vin 0 PULSE(0 1.8 0 1e-05 1e-05 1e-09 2e-05)
Vref vref 0 0.9
M1 n1 vin tail 0 nmos_1v8 W=5u L=180n
M2 n2 vref tail 0 nmos_1v8 W=5u L=180n
M3 n1 n1 vdd vdd pmos_1v8 W=2u L=180n
M4 n2 n1 vdd vdd pmos_1v8 W=2u L=180n
Itail 0 tail 5e-05
Mp5 vout n2 vdd vdd pmos_1v8 W=4u L=180n
Mn5 vout n2 0 0 nmos_1v8 W=2u L=180n
Mhyst tail vout hyst_src 0 nmos_1v8 W=500n L=500n
Ihyst 0 hyst_src 5e-06
.end

