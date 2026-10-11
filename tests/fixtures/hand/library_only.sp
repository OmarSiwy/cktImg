* A cell library: subckts only, no top level.
.subckt rc_filter in out
*.PININFO in:I out:O
R1 in out 1k
C1 out 0 159n
.ends rc_filter

.subckt diff_amp inp inn outp outn vdd vss bias=10u
M1 outp inp tail vss nch w=2u l=0.5u
M2 outn inn tail vss nch w=2u l=0.5u
R1 vdd outp 5k
R2 vdd outn 5k
I1 tail vss {bias}
.model nch nmos level=1
.ends

.subckt unused_port a b c
R1 a b 1
.ends
