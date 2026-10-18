.title BJT Cascode Amplifier
.model 2N2222 npn (bf=100 is=1e-14 vaf=50)
Vcc vcc 0 12
Vin vin 0 0
Rb1 vcc base_ce 100000.0
Rb2 base_ce 0 22000.0
Rb3 vcc base_cb 56000.0
Rb4 base_cb 0 22000.0
Cbypass base_cb 0 0.0001
Cin vin base_ce 1e-06
Q1 mid base_ce emitter 2N2222
Re emitter 0 470
Q2 vout base_cb mid 2N2222
Rc vcc vout 4700.0
Cout vout output 1e-06
Rload output 0 10000.0
.end

