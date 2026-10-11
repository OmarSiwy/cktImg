.title Instrumentation Amplifier
Vcc vcc 0 15
Vee vee 0 -15
Vcm vcm 0 2.5
Vdp inp vcm 0.005
Vdn vcm inn 0.005
Ea1 out_a1 0 inp fb_a1 1000000.0
Rg1 fb_a1 mid 10000.0
R1a fb_a1 out_a1 24700.0
Ea2 out_a2 0 inn fb_a2 1000000.0
Rg2 mid fb_a2 10000.0
R2a fb_a2 out_a2 24700.0
R3 out_a1 diff_m 10000.0
R4 diff_m vout 10000.0
R5 out_a2 diff_p 10000.0
R6 diff_p 0 10000.0
Ea3 vout 0 diff_p diff_m 1000000.0
.end

