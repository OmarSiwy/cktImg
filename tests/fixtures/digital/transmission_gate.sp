.title Transmission Gate
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vctrl ctrl 0 1.8
Vctrlb ctrlb 0 0
Vin vin 0 0.9
Mn vin ctrl vout 0 nmos_1v8 W=2u L=180n
Mp vin ctrlb vout vdd pmos_1v8 W=4u L=180n
Rload vout 0 100000.0
Cload vout 0 1e-13
.end

