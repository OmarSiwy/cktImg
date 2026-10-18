.title 4x4 SRAM Array
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vwl[0] wl[0] 0 1.8
Vwl[1] wl[1] 0 0.0
Vwl[2] wl[2] 0 0.0
Vwl[3] wl[3] 0 0.0
Vpre_bl[0] bl[0] 0 0.9
Vpre_blb[0] blb[0] 0 0.9
Vpre_bl[1] bl[1] 0 0.9
Vpre_blb[1] blb[1] 0 0.9
Vpre_bl[2] bl[2] 0 0.9
Vpre_blb[2] blb[2] 0 0.9
Vpre_bl[3] bl[3] 0 0.9
Vpre_blb[3] blb[3] 0 0.9
Mr0c0_p1 r0c0_q r0c0_qb vdd vdd pmos_1v8 W=1u L=180n
Mr0c0_n1 r0c0_q r0c0_qb 0 0 nmos_1v8 W=500n L=180n
Mr0c0_p2 r0c0_qb r0c0_q vdd vdd pmos_1v8 W=1u L=180n
Mr0c0_n2 r0c0_qb r0c0_q 0 0 nmos_1v8 W=500n L=180n
Mr0c0_acc1 bl[0] wl[0] r0c0_q 0 nmos_1v8 W=1u L=180n
Mr0c0_acc2 blb[0] wl[0] r0c0_qb 0 nmos_1v8 W=1u L=180n
Mr0c1_p1 r0c1_q r0c1_qb vdd vdd pmos_1v8 W=1u L=180n
Mr0c1_n1 r0c1_q r0c1_qb 0 0 nmos_1v8 W=500n L=180n
Mr0c1_p2 r0c1_qb r0c1_q vdd vdd pmos_1v8 W=1u L=180n
Mr0c1_n2 r0c1_qb r0c1_q 0 0 nmos_1v8 W=500n L=180n
Mr0c1_acc1 bl[1] wl[0] r0c1_q 0 nmos_1v8 W=1u L=180n
Mr0c1_acc2 blb[1] wl[0] r0c1_qb 0 nmos_1v8 W=1u L=180n
Mr0c2_p1 r0c2_q r0c2_qb vdd vdd pmos_1v8 W=1u L=180n
Mr0c2_n1 r0c2_q r0c2_qb 0 0 nmos_1v8 W=500n L=180n
Mr0c2_p2 r0c2_qb r0c2_q vdd vdd pmos_1v8 W=1u L=180n
Mr0c2_n2 r0c2_qb r0c2_q 0 0 nmos_1v8 W=500n L=180n
Mr0c2_acc1 bl[2] wl[0] r0c2_q 0 nmos_1v8 W=1u L=180n
Mr0c2_acc2 blb[2] wl[0] r0c2_qb 0 nmos_1v8 W=1u L=180n
Mr0c3_p1 r0c3_q r0c3_qb vdd vdd pmos_1v8 W=1u L=180n
Mr0c3_n1 r0c3_q r0c3_qb 0 0 nmos_1v8 W=500n L=180n
Mr0c3_p2 r0c3_qb r0c3_q vdd vdd pmos_1v8 W=1u L=180n
Mr0c3_n2 r0c3_qb r0c3_q 0 0 nmos_1v8 W=500n L=180n
Mr0c3_acc1 bl[3] wl[0] r0c3_q 0 nmos_1v8 W=1u L=180n
Mr0c3_acc2 blb[3] wl[0] r0c3_qb 0 nmos_1v8 W=1u L=180n
Mr1c0_p1 r1c0_q r1c0_qb vdd vdd pmos_1v8 W=1u L=180n
Mr1c0_n1 r1c0_q r1c0_qb 0 0 nmos_1v8 W=500n L=180n
Mr1c0_p2 r1c0_qb r1c0_q vdd vdd pmos_1v8 W=1u L=180n
Mr1c0_n2 r1c0_qb r1c0_q 0 0 nmos_1v8 W=500n L=180n
Mr1c0_acc1 bl[0] wl[1] r1c0_q 0 nmos_1v8 W=1u L=180n
Mr1c0_acc2 blb[0] wl[1] r1c0_qb 0 nmos_1v8 W=1u L=180n
Mr1c1_p1 r1c1_q r1c1_qb vdd vdd pmos_1v8 W=1u L=180n
Mr1c1_n1 r1c1_q r1c1_qb 0 0 nmos_1v8 W=500n L=180n
Mr1c1_p2 r1c1_qb r1c1_q vdd vdd pmos_1v8 W=1u L=180n
Mr1c1_n2 r1c1_qb r1c1_q 0 0 nmos_1v8 W=500n L=180n
Mr1c1_acc1 bl[1] wl[1] r1c1_q 0 nmos_1v8 W=1u L=180n
Mr1c1_acc2 blb[1] wl[1] r1c1_qb 0 nmos_1v8 W=1u L=180n
Mr1c2_p1 r1c2_q r1c2_qb vdd vdd pmos_1v8 W=1u L=180n
Mr1c2_n1 r1c2_q r1c2_qb 0 0 nmos_1v8 W=500n L=180n
Mr1c2_p2 r1c2_qb r1c2_q vdd vdd pmos_1v8 W=1u L=180n
Mr1c2_n2 r1c2_qb r1c2_q 0 0 nmos_1v8 W=500n L=180n
Mr1c2_acc1 bl[2] wl[1] r1c2_q 0 nmos_1v8 W=1u L=180n
Mr1c2_acc2 blb[2] wl[1] r1c2_qb 0 nmos_1v8 W=1u L=180n
Mr1c3_p1 r1c3_q r1c3_qb vdd vdd pmos_1v8 W=1u L=180n
Mr1c3_n1 r1c3_q r1c3_qb 0 0 nmos_1v8 W=500n L=180n
Mr1c3_p2 r1c3_qb r1c3_q vdd vdd pmos_1v8 W=1u L=180n
Mr1c3_n2 r1c3_qb r1c3_q 0 0 nmos_1v8 W=500n L=180n
Mr1c3_acc1 bl[3] wl[1] r1c3_q 0 nmos_1v8 W=1u L=180n
Mr1c3_acc2 blb[3] wl[1] r1c3_qb 0 nmos_1v8 W=1u L=180n
Mr2c0_p1 r2c0_q r2c0_qb vdd vdd pmos_1v8 W=1u L=180n
Mr2c0_n1 r2c0_q r2c0_qb 0 0 nmos_1v8 W=500n L=180n
Mr2c0_p2 r2c0_qb r2c0_q vdd vdd pmos_1v8 W=1u L=180n
Mr2c0_n2 r2c0_qb r2c0_q 0 0 nmos_1v8 W=500n L=180n
Mr2c0_acc1 bl[0] wl[2] r2c0_q 0 nmos_1v8 W=1u L=180n
Mr2c0_acc2 blb[0] wl[2] r2c0_qb 0 nmos_1v8 W=1u L=180n
Mr2c1_p1 r2c1_q r2c1_qb vdd vdd pmos_1v8 W=1u L=180n
Mr2c1_n1 r2c1_q r2c1_qb 0 0 nmos_1v8 W=500n L=180n
Mr2c1_p2 r2c1_qb r2c1_q vdd vdd pmos_1v8 W=1u L=180n
Mr2c1_n2 r2c1_qb r2c1_q 0 0 nmos_1v8 W=500n L=180n
Mr2c1_acc1 bl[1] wl[2] r2c1_q 0 nmos_1v8 W=1u L=180n
Mr2c1_acc2 blb[1] wl[2] r2c1_qb 0 nmos_1v8 W=1u L=180n
Mr2c2_p1 r2c2_q r2c2_qb vdd vdd pmos_1v8 W=1u L=180n
Mr2c2_n1 r2c2_q r2c2_qb 0 0 nmos_1v8 W=500n L=180n
Mr2c2_p2 r2c2_qb r2c2_q vdd vdd pmos_1v8 W=1u L=180n
Mr2c2_n2 r2c2_qb r2c2_q 0 0 nmos_1v8 W=500n L=180n
Mr2c2_acc1 bl[2] wl[2] r2c2_q 0 nmos_1v8 W=1u L=180n
Mr2c2_acc2 blb[2] wl[2] r2c2_qb 0 nmos_1v8 W=1u L=180n
Mr2c3_p1 r2c3_q r2c3_qb vdd vdd pmos_1v8 W=1u L=180n
Mr2c3_n1 r2c3_q r2c3_qb 0 0 nmos_1v8 W=500n L=180n
Mr2c3_p2 r2c3_qb r2c3_q vdd vdd pmos_1v8 W=1u L=180n
Mr2c3_n2 r2c3_qb r2c3_q 0 0 nmos_1v8 W=500n L=180n
Mr2c3_acc1 bl[3] wl[2] r2c3_q 0 nmos_1v8 W=1u L=180n
Mr2c3_acc2 blb[3] wl[2] r2c3_qb 0 nmos_1v8 W=1u L=180n
Mr3c0_p1 r3c0_q r3c0_qb vdd vdd pmos_1v8 W=1u L=180n
Mr3c0_n1 r3c0_q r3c0_qb 0 0 nmos_1v8 W=500n L=180n
Mr3c0_p2 r3c0_qb r3c0_q vdd vdd pmos_1v8 W=1u L=180n
Mr3c0_n2 r3c0_qb r3c0_q 0 0 nmos_1v8 W=500n L=180n
Mr3c0_acc1 bl[0] wl[3] r3c0_q 0 nmos_1v8 W=1u L=180n
Mr3c0_acc2 blb[0] wl[3] r3c0_qb 0 nmos_1v8 W=1u L=180n
Mr3c1_p1 r3c1_q r3c1_qb vdd vdd pmos_1v8 W=1u L=180n
Mr3c1_n1 r3c1_q r3c1_qb 0 0 nmos_1v8 W=500n L=180n
Mr3c1_p2 r3c1_qb r3c1_q vdd vdd pmos_1v8 W=1u L=180n
Mr3c1_n2 r3c1_qb r3c1_q 0 0 nmos_1v8 W=500n L=180n
Mr3c1_acc1 bl[1] wl[3] r3c1_q 0 nmos_1v8 W=1u L=180n
Mr3c1_acc2 blb[1] wl[3] r3c1_qb 0 nmos_1v8 W=1u L=180n
Mr3c2_p1 r3c2_q r3c2_qb vdd vdd pmos_1v8 W=1u L=180n
Mr3c2_n1 r3c2_q r3c2_qb 0 0 nmos_1v8 W=500n L=180n
Mr3c2_p2 r3c2_qb r3c2_q vdd vdd pmos_1v8 W=1u L=180n
Mr3c2_n2 r3c2_qb r3c2_q 0 0 nmos_1v8 W=500n L=180n
Mr3c2_acc1 bl[2] wl[3] r3c2_q 0 nmos_1v8 W=1u L=180n
Mr3c2_acc2 blb[2] wl[3] r3c2_qb 0 nmos_1v8 W=1u L=180n
Mr3c3_p1 r3c3_q r3c3_qb vdd vdd pmos_1v8 W=1u L=180n
Mr3c3_n1 r3c3_q r3c3_qb 0 0 nmos_1v8 W=500n L=180n
Mr3c3_p2 r3c3_qb r3c3_q vdd vdd pmos_1v8 W=1u L=180n
Mr3c3_n2 r3c3_qb r3c3_q 0 0 nmos_1v8 W=500n L=180n
Mr3c3_acc1 bl[3] wl[3] r3c3_q 0 nmos_1v8 W=1u L=180n
Mr3c3_acc2 blb[3] wl[3] r3c3_qb 0 nmos_1v8 W=1u L=180n
Msa_p0 data[0] blb[0] vdd vdd pmos_1v8 W=2u L=180n
Msa_n0 data[0] bl[0] 0 0 nmos_1v8 W=1u L=180n
Msa_p1 data[1] blb[1] vdd vdd pmos_1v8 W=2u L=180n
Msa_n1 data[1] bl[1] 0 0 nmos_1v8 W=1u L=180n
Msa_p2 data[2] blb[2] vdd vdd pmos_1v8 W=2u L=180n
Msa_n2 data[2] bl[2] 0 0 nmos_1v8 W=1u L=180n
Msa_p3 data[3] blb[3] vdd vdd pmos_1v8 W=2u L=180n
Msa_n3 data[3] bl[3] 0 0 nmos_1v8 W=1u L=180n
.end

