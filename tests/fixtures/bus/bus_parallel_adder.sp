.title 4-bit Ripple Carry Adder
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Va[0] a[0] 0 1.8
Vb[0] b[0] 0 1.8
Va[1] a[1] 0 0.0
Vb[1] b[1] 0 1.8
Va[2] a[2] 0 1.8
Vb[2] b[2] 0 0.0
Va[3] a[3] 0 0.0
Vb[3] b[3] 0 0.0
Vcin carry[0] 0 0
Mp_xor1_0_inv xor1_0_ab a[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_0_inv xor1_0_ab a[0] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_0_tg1 b[0] xor1_0_ab psum[0] 0 nmos_1v8 W=2u L=180n
Mp_xor1_0_tg1 b[0] a[0] psum[0] vdd pmos_1v8 W=4u L=180n
Mp_xor1_0_inv2 xor1_0_bb b[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_0_inv2 xor1_0_bb b[0] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_0_tg2 xor1_0_bb a[0] psum[0] 0 nmos_1v8 W=2u L=180n
Mp_xor1_0_tg2 xor1_0_bb xor1_0_ab psum[0] vdd pmos_1v8 W=4u L=180n
Mp_xor2_0_inv xor2_0_ab psum[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_0_inv xor2_0_ab psum[0] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_0_tg1 carry[0] xor2_0_ab sum[0] 0 nmos_1v8 W=2u L=180n
Mp_xor2_0_tg1 carry[0] psum[0] sum[0] vdd pmos_1v8 W=4u L=180n
Mp_xor2_0_inv2 xor2_0_bb carry[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_0_inv2 xor2_0_bb carry[0] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_0_tg2 xor2_0_bb psum[0] sum[0] 0 nmos_1v8 W=2u L=180n
Mp_xor2_0_tg2 xor2_0_bb xor2_0_ab sum[0] vdd pmos_1v8 W=4u L=180n
Ecarry_0 carry[1] 0 a[0] 0 1
Ccs0 sum[0] 0 5e-15
Ccc0 carry[1] 0 5e-15
Mp_xor1_1_inv xor1_1_ab a[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_1_inv xor1_1_ab a[1] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_1_tg1 b[1] xor1_1_ab psum[1] 0 nmos_1v8 W=2u L=180n
Mp_xor1_1_tg1 b[1] a[1] psum[1] vdd pmos_1v8 W=4u L=180n
Mp_xor1_1_inv2 xor1_1_bb b[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_1_inv2 xor1_1_bb b[1] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_1_tg2 xor1_1_bb a[1] psum[1] 0 nmos_1v8 W=2u L=180n
Mp_xor1_1_tg2 xor1_1_bb xor1_1_ab psum[1] vdd pmos_1v8 W=4u L=180n
Mp_xor2_1_inv xor2_1_ab psum[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_1_inv xor2_1_ab psum[1] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_1_tg1 carry[1] xor2_1_ab sum[1] 0 nmos_1v8 W=2u L=180n
Mp_xor2_1_tg1 carry[1] psum[1] sum[1] vdd pmos_1v8 W=4u L=180n
Mp_xor2_1_inv2 xor2_1_bb carry[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_1_inv2 xor2_1_bb carry[1] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_1_tg2 xor2_1_bb psum[1] sum[1] 0 nmos_1v8 W=2u L=180n
Mp_xor2_1_tg2 xor2_1_bb xor2_1_ab sum[1] vdd pmos_1v8 W=4u L=180n
Ecarry_1 carry[2] 0 a[1] 0 1
Ccs1 sum[1] 0 5e-15
Ccc1 carry[2] 0 5e-15
Mp_xor1_2_inv xor1_2_ab a[2] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_2_inv xor1_2_ab a[2] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_2_tg1 b[2] xor1_2_ab psum[2] 0 nmos_1v8 W=2u L=180n
Mp_xor1_2_tg1 b[2] a[2] psum[2] vdd pmos_1v8 W=4u L=180n
Mp_xor1_2_inv2 xor1_2_bb b[2] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_2_inv2 xor1_2_bb b[2] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_2_tg2 xor1_2_bb a[2] psum[2] 0 nmos_1v8 W=2u L=180n
Mp_xor1_2_tg2 xor1_2_bb xor1_2_ab psum[2] vdd pmos_1v8 W=4u L=180n
Mp_xor2_2_inv xor2_2_ab psum[2] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_2_inv xor2_2_ab psum[2] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_2_tg1 carry[2] xor2_2_ab sum[2] 0 nmos_1v8 W=2u L=180n
Mp_xor2_2_tg1 carry[2] psum[2] sum[2] vdd pmos_1v8 W=4u L=180n
Mp_xor2_2_inv2 xor2_2_bb carry[2] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_2_inv2 xor2_2_bb carry[2] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_2_tg2 xor2_2_bb psum[2] sum[2] 0 nmos_1v8 W=2u L=180n
Mp_xor2_2_tg2 xor2_2_bb xor2_2_ab sum[2] vdd pmos_1v8 W=4u L=180n
Ecarry_2 carry[3] 0 a[2] 0 1
Ccs2 sum[2] 0 5e-15
Ccc2 carry[3] 0 5e-15
Mp_xor1_3_inv xor1_3_ab a[3] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_3_inv xor1_3_ab a[3] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_3_tg1 b[3] xor1_3_ab psum[3] 0 nmos_1v8 W=2u L=180n
Mp_xor1_3_tg1 b[3] a[3] psum[3] vdd pmos_1v8 W=4u L=180n
Mp_xor1_3_inv2 xor1_3_bb b[3] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor1_3_inv2 xor1_3_bb b[3] 0 0 nmos_1v8 W=1u L=180n
Mn_xor1_3_tg2 xor1_3_bb a[3] psum[3] 0 nmos_1v8 W=2u L=180n
Mp_xor1_3_tg2 xor1_3_bb xor1_3_ab psum[3] vdd pmos_1v8 W=4u L=180n
Mp_xor2_3_inv xor2_3_ab psum[3] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_3_inv xor2_3_ab psum[3] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_3_tg1 carry[3] xor2_3_ab sum[3] 0 nmos_1v8 W=2u L=180n
Mp_xor2_3_tg1 carry[3] psum[3] sum[3] vdd pmos_1v8 W=4u L=180n
Mp_xor2_3_inv2 xor2_3_bb carry[3] vdd vdd pmos_1v8 W=2u L=180n
Mn_xor2_3_inv2 xor2_3_bb carry[3] 0 0 nmos_1v8 W=1u L=180n
Mn_xor2_3_tg2 xor2_3_bb psum[3] sum[3] 0 nmos_1v8 W=2u L=180n
Mp_xor2_3_tg2 xor2_3_bb xor2_3_ab sum[3] vdd pmos_1v8 W=4u L=180n
Ecarry_3 carry[4] 0 a[3] 0 1
Ccs3 sum[3] 0 5e-15
Ccc3 carry[4] 0 5e-15
.end

