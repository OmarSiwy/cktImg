.title TB LDO Load Regulation
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
Xdut vin vout vref ldo_regulator
Vin vin 0 3.3
Vref vref 0 1.2
Resr vout cap_node 0.03
Cout cap_node 0 4.7e-06
Vctrl vctrl 0 PULSE(0 1.8 0 1e-07 1e-07 5e-05 0.0001)
Mload vout vctrl rsense 0 nmos_1v8 W=500u L=180n
Rsense rsense 0 1
Rlight vout 0 1800.0
.end

