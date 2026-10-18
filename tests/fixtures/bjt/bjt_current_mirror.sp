.title BJT Current Mirror
.model 2N2222 npn (bf=100 is=1e-14 vaf=50)
Vcc vcc 0 5
Rref vcc iref 47000.0
Q1 iref iref 0 2N2222
Q2 iout iref 0 2N2222
Rload vcc iout 10000.0
.end

