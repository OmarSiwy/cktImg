.title Emitter Follower
.model 2N2222 npn (bf=100 is=1e-14 vaf=50)
Vcc vcc 0 12
Vin vin 0 6
R1 vcc base 100000.0
R2 base 0 100000.0
Cin vin base 1e-06
Q1 vcc base vout 2N2222
Re vout 0 1000.0
Cout vout output 1e-05
Rload output 0 100
.end

