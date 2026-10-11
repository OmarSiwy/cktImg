* Hierarchy, subckt parameters, continuations, mixed case, globals and control text.
.global VDD
.include ./models.lib
.param vsup=1.8 rload=10k

.SUBCKT inv IN OUT params: wn=1u wp={2*wn}
*.PININFO IN:I OUT:O
.param lmin=0.18u
Mp OUT IN VDD VDD pmos_1v8 W={wp} L=lmin
Mn OUT IN 0 0 nmos_1v8
+ w=wn l={lmin} $ continuation with a trailing comment
.ends inv

.subckt buf a y strength=1
x1 a mid inv wn={strength*1u} wp={strength*2u}
X2 mid y INV wn={strength*2u} wp=4u
Cload y 0 {strength*10f}
.ends

Vdd VDD 0 {vsup}
Vin in 0 dc 0 pulse(0 1.8 1n 100p 100p 5n 10n)
Xb1 in out1 buf strength=2
Xb2 out1 out2 buf
Rl out2 0 {rload}
.tran 10p 40n
.control
run
echo "v=$&vsup" ; not a comment inside control
.endc
.end
