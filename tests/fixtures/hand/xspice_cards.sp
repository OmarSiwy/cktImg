* XSPICE A, OSDI N, coupled-line P and lossy-line Y cards, node-less X calls and
* cktImg's *@ block-side directives: all drawn as instances.
.subckt digital a y
A1 [a b] ~y nand1
Rb b 0 1k
.ends
.subckt xsp in out
A2 in mid gain1
A3 %vd(in 0) %v out gain1
Rm mid out 1k
.ends
.subckt lines in far
Y1 in 0 mid 0 ymod
P1 in mid 0 o1 o2 0 cplmod
N1 o1 far 0 0 osdimod
Rload far 0 1k
Ro o2 0 1k
.ends
.subckt blk in out vdd vss
*@ left in
*@ right out
*@ top vdd
*@ bottom vss
R1 in out 1k
R2 vdd out 10k
R3 out vss 10k
.ends
.subckt on_globals
R1 vdd! 0 1k
.ends
.model nand1 d_nand
.model gain1 gain(gain=2)
.model ymod txl r=12.45 l=8.972e-9 g=0 c=0.468e-12 length=16
.model cplmod cpl r=1 l=1n g=0 c=1p length=1
.model osdimod bsimcmg
Vdd vdd! 0 1.8
V1 in 0 1
Xx in x1 xsp
Xd x1 y digital
Xl y far lines
Xb y out vdd! 0 blk
X9 on_globals
X8 undefined_globals
.op
