* Cards the core cells cannot re-emit, plus every other recognized letter.
.model dmod d is=1e-14
.model qn npn bf=100
.model jn njf vto=-2
V1 a 0 sin(0 1 1k)
I1 0 b 1m
D1 a b dmod
D2 b 0 dmod area=2
Q1 c b e qn
Q2 c b e s qn area=1.5
Qa c b 0 qn area=2 m=3
J1 c a e jn
E1 o1 0 a b 10
E2 o2 0 value={v(a)*2}
G1 0 o3 a 0 1m
F1 o4 0 V1 2
H1 o5 0 V1 1k
B1 o6 0 V=v(a)*v(b)
B2 o6 0 I=1m*v(a)
W1 o7 0 V1 swc
S1 o8 0 a 0 swv
T1 a 0 o9 0 z0=50 td=1n
T2 a 0 o10 0 z0=75 f=1g nl=0.25
L1 o9 o10 1u
L2 o10 0 2u
K1 L1 L2 0.5
R1 o1 o2 1k tc1=0.01
R2 o3 o4 rmod l=10u w=1u
C1 o5 0 1p m=2
Xu1 a b c undefined_block gain=3
Xu2 o1 o2 undefined_block
M1 o6 a 0 0 nfet
M2 o7 a vdd vdd pfet w=1u
.model swc csw it=1m
.model swv sw vt=0.5
.op
