.title Op-Amp Integrator
Vcc vcc 0 15
Vee vee 0 -15
Vin vin 0 PULSE(-0.5 0.5 0 1e-06 1e-06 0.0005 0.001)
Rin vin vminus 10000.0
Cf vminus vout 1e-08
Rf vminus vout 1000000.0
Eamp vout 0 0 vminus 1000000.0
.end

