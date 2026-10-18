.title Common Source Amplifier
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Vin vin 0 0.7
Rd vdd vout 5000.0
M1 vout vin 0 0 nmos_1v8 W=10u L=180n
.end

