.title BJT Differential Pair
.model 2N2222 npn (bf=100 is=1e-14 vaf=50)
Vcc vcc 0 5
Vinp inp 0 2.5
Vinn inn 0 2.5
Rc1 vcc outp 5000.0
Rc2 vcc outn 5000.0
Q1 outp inp tail 2N2222
Q2 outn inn tail 2N2222
Itail tail 0 0.0005
.end

