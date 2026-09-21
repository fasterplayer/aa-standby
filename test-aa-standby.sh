#!/bin/sh
# Banc d'essai aa-standby v4.3. Ne touche NI aa-proxy-rs NI le Bluetooth :
# MODE=observation, INIT=/bin/true, VGATE bidon (donc jamais de sonde OBD reelle).
T=/tmp/sbtest
prep() {
  rm -rf $T; mkdir -p $T
  echo "not attached" > $T/udc
  echo "USB=1"        > $T/extcon
  : > $T/obd.log ; : > $T/rs.log ; : > $T/gadget
  echo observation    > $T/mode
  { cat <<'C'
LOG=/tmp/sbtest/standby.log
MODE_FILE=/tmp/sbtest/mode
OBDLOG=/tmp/sbtest/obd.log
RSLOG=/tmp/sbtest/rs.log
UDC_STATE=/tmp/sbtest/udc
EXTCON_STATE=/tmp/sbtest/extcon
GADGET_UDC=/tmp/sbtest/gadget
PROBE_TOML=/tmp/sbtest/probe.toml
PROBE_LOG=/tmp/sbtest/probe.log
INIT=/bin/true
VGATE=00:00:00:00:00:01
C
    echo "VEILLE_MAX=$1"; } > $T/conf
  sed "s|/etc/aa-standby.conf|$T/conf|g" ${AA_STANDBY:-./aa-standby} > $T/run
  chmod +x $T/run
}
obd()  { echo "  battery_level_percentage: 40" >> $T/obd.log; }
mark() { echo "### t=${1}s  $2" >> $T/standby.log; }

echo "############ ESSAI A — va-et-vient (scenario du demarrage 98) ############"
prep 7200
$T/run & PID=$!
t=0
while [ $t -lt 260 ]; do
  sleep 5; t=$((t+5))
  [ $t -eq 50 ]  && mark $t "l'OBD repond : la voiture roule, mais l'autoradio n'est pas encore enumere"
  [ $t -eq 200 ] && mark $t "l'autoradio s'enumere enfin (USB -> configured)" && echo configured > $T/udc
  [ $t -eq 215 ] && mark $t "la voiture s'eteint : plus d'OBD, USB detache" && echo "not attached" > $T/udc
  if [ $t -ge 50 ] && [ $t -lt 215 ]; then obd; fi
done
mark $t "fin de l'essai A"
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
cp $T/standby.log /tmp/essaiA.log

echo "############ ESSAI B — filet homme mort (VEILLE_MAX abaisse a 60 s) ############"
prep 60
$T/run & PID=$!
t=0
while [ $t -lt 210 ]; do sleep 5; t=$((t+5)); done
mark $t "fin de l'essai B"
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
cp $T/standby.log /tmp/essaiB.log
echo "TERMINE"
