.title 2-to-4 Decoder
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Vaddr[0] addr[0] 0 0
Vaddr[1] addr[1] 0 1.8
Ven en 0 1.8
Mp_a0b addr_b[0] addr[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_a0b addr_b[0] addr[0] 0 0 nmos_1v8 W=1u L=180n
Mp_a1b addr_b[1] addr[1] vdd vdd pmos_1v8 W=2u L=180n
Mn_a1b addr_b[1] addr[1] 0 0 nmos_1v8 W=1u L=180n
Mp_n0a nand0 addr_b[1] vdd vdd pmos_1v8 W=2u L=180n
Mp_n0b nand0 addr_b[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_n0a nand0 addr_b[1] mid0 0 nmos_1v8 W=2u L=180n
Mn_n0b mid0 addr_b[0] 0 0 nmos_1v8 W=2u L=180n
Mp_o0 out[0] nand0 vdd vdd pmos_1v8 W=2u L=180n
Mn_o0 out[0] nand0 0 0 nmos_1v8 W=1u L=180n
Mp_n1a nand1 addr_b[1] vdd vdd pmos_1v8 W=2u L=180n
Mp_n1b nand1 addr[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_n1a nand1 addr_b[1] mid1 0 nmos_1v8 W=2u L=180n
Mn_n1b mid1 addr[0] 0 0 nmos_1v8 W=2u L=180n
Mp_o1 out[1] nand1 vdd vdd pmos_1v8 W=2u L=180n
Mn_o1 out[1] nand1 0 0 nmos_1v8 W=1u L=180n
Mp_n2a nand2 addr[1] vdd vdd pmos_1v8 W=2u L=180n
Mp_n2b nand2 addr_b[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_n2a nand2 addr[1] mid2 0 nmos_1v8 W=2u L=180n
Mn_n2b mid2 addr_b[0] 0 0 nmos_1v8 W=2u L=180n
Mp_o2 out[2] nand2 vdd vdd pmos_1v8 W=2u L=180n
Mn_o2 out[2] nand2 0 0 nmos_1v8 W=1u L=180n
Mp_n3a nand3 addr[1] vdd vdd pmos_1v8 W=2u L=180n
Mp_n3b nand3 addr[0] vdd vdd pmos_1v8 W=2u L=180n
Mn_n3a nand3 addr[1] mid3 0 nmos_1v8 W=2u L=180n
Mn_n3b mid3 addr[0] 0 0 nmos_1v8 W=2u L=180n
Mp_o3 out[3] nand3 vdd vdd pmos_1v8 W=2u L=180n
Mn_o3 out[3] nand3 0 0 nmos_1v8 W=1u L=180n
.end

