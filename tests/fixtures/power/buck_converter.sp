.title Buck Converter
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vin vin 0 3.3
Vpwm vpwm 0 PULSE(0 1.8 0 1e-08 1e-08 5.45e-07 1e-06)
Mhs vin vpwm sw vin pmos_1v8 W=500u L=180n
Mls sw vpwm 0 0 nmos_1v8 W=250u L=180n
L1 sw vout 1e-06
Cout vout 0 1e-05
Resr vout vesr 0.01
Rload vout 0 1.8
.end

