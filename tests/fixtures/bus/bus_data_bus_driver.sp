.title 8-bit Tri-State Bus Driver
.model nmos_1v8 nmos (level=1 kp=0.00012 vto=0.5)
.model pmos_1v8 pmos (level=1 kp=6e-05 vto=-0.5)
Vdd vdd 0 1.8
Voe oe 0 1.8
Mp_oeb oeb oe vdd vdd pmos_1v8 W=2u L=180n
Mn_oeb oeb oe 0 0 nmos_1v8 W=1u L=180n
Vdin[0] din[0] 0 1.8
Vdin[1] din[1] 0 0
Vdin[2] din[2] 0 1.8
Vdin[3] din[3] 0 0
Vdin[4] din[4] 0 0
Vdin[5] din[5] 0 1.8
Vdin[6] din[6] 0 0
Vdin[7] din[7] 0 1.8
Mp_buf0 buf[0] din[0] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf0 buf[0] din[0] 0 0 nmos_1v8 W=2u L=180n
Mp_drv0 drv[0] buf[0] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv0 drv[0] buf[0] 0 0 nmos_1v8 W=4u L=180n
Mn_ts0 drv[0] oe bus[0] 0 nmos_1v8 W=4u L=180n
Mp_ts0 drv[0] oeb bus[0] vdd pmos_1v8 W=8u L=180n
Rkeeper0 bus[0] 0 1000000.0
Ccbus0 bus[0] 0 5e-14
Mp_buf1 buf[1] din[1] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf1 buf[1] din[1] 0 0 nmos_1v8 W=2u L=180n
Mp_drv1 drv[1] buf[1] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv1 drv[1] buf[1] 0 0 nmos_1v8 W=4u L=180n
Mn_ts1 drv[1] oe bus[1] 0 nmos_1v8 W=4u L=180n
Mp_ts1 drv[1] oeb bus[1] vdd pmos_1v8 W=8u L=180n
Rkeeper1 bus[1] 0 1000000.0
Ccbus1 bus[1] 0 5e-14
Mp_buf2 buf[2] din[2] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf2 buf[2] din[2] 0 0 nmos_1v8 W=2u L=180n
Mp_drv2 drv[2] buf[2] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv2 drv[2] buf[2] 0 0 nmos_1v8 W=4u L=180n
Mn_ts2 drv[2] oe bus[2] 0 nmos_1v8 W=4u L=180n
Mp_ts2 drv[2] oeb bus[2] vdd pmos_1v8 W=8u L=180n
Rkeeper2 bus[2] 0 1000000.0
Ccbus2 bus[2] 0 5e-14
Mp_buf3 buf[3] din[3] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf3 buf[3] din[3] 0 0 nmos_1v8 W=2u L=180n
Mp_drv3 drv[3] buf[3] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv3 drv[3] buf[3] 0 0 nmos_1v8 W=4u L=180n
Mn_ts3 drv[3] oe bus[3] 0 nmos_1v8 W=4u L=180n
Mp_ts3 drv[3] oeb bus[3] vdd pmos_1v8 W=8u L=180n
Rkeeper3 bus[3] 0 1000000.0
Ccbus3 bus[3] 0 5e-14
Mp_buf4 buf[4] din[4] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf4 buf[4] din[4] 0 0 nmos_1v8 W=2u L=180n
Mp_drv4 drv[4] buf[4] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv4 drv[4] buf[4] 0 0 nmos_1v8 W=4u L=180n
Mn_ts4 drv[4] oe bus[4] 0 nmos_1v8 W=4u L=180n
Mp_ts4 drv[4] oeb bus[4] vdd pmos_1v8 W=8u L=180n
Rkeeper4 bus[4] 0 1000000.0
Ccbus4 bus[4] 0 5e-14
Mp_buf5 buf[5] din[5] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf5 buf[5] din[5] 0 0 nmos_1v8 W=2u L=180n
Mp_drv5 drv[5] buf[5] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv5 drv[5] buf[5] 0 0 nmos_1v8 W=4u L=180n
Mn_ts5 drv[5] oe bus[5] 0 nmos_1v8 W=4u L=180n
Mp_ts5 drv[5] oeb bus[5] vdd pmos_1v8 W=8u L=180n
Rkeeper5 bus[5] 0 1000000.0
Ccbus5 bus[5] 0 5e-14
Mp_buf6 buf[6] din[6] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf6 buf[6] din[6] 0 0 nmos_1v8 W=2u L=180n
Mp_drv6 drv[6] buf[6] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv6 drv[6] buf[6] 0 0 nmos_1v8 W=4u L=180n
Mn_ts6 drv[6] oe bus[6] 0 nmos_1v8 W=4u L=180n
Mp_ts6 drv[6] oeb bus[6] vdd pmos_1v8 W=8u L=180n
Rkeeper6 bus[6] 0 1000000.0
Ccbus6 bus[6] 0 5e-14
Mp_buf7 buf[7] din[7] vdd vdd pmos_1v8 W=4u L=180n
Mn_buf7 buf[7] din[7] 0 0 nmos_1v8 W=2u L=180n
Mp_drv7 drv[7] buf[7] vdd vdd pmos_1v8 W=8u L=180n
Mn_drv7 drv[7] buf[7] 0 0 nmos_1v8 W=4u L=180n
Mn_ts7 drv[7] oe bus[7] 0 nmos_1v8 W=4u L=180n
Mp_ts7 drv[7] oeb bus[7] vdd pmos_1v8 W=8u L=180n
Rkeeper7 bus[7] 0 1000000.0
Ccbus7 bus[7] 0 5e-14
.end

