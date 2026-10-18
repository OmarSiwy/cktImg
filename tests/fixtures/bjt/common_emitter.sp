.title Common Emitter Amplifier
.model 2N2222 npn (bf=100 is=1e-14 vaf=50)
Vcc vcc 0 5
Vin vin 0 0
R1 vcc base 56000.0
R2 base 0 10000.0
Cin vin base 1e-05
Cout vout output 1e-05
Q1 vout base emitter 2N2222
Rc vcc vout 2200.0
Re emitter 0 1000.0
Ce emitter 0 0.0001
Rload output 0 10000.0
.end

