.title Source Follower
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Vdd vdd 0 1.8
Vin vin 0 1.2
M1 vdd vin vout 0 nmos_1v8 W=20u L=180n
Ibias vout 0 0.0002
Cload vout 0 1e-12
.end

