#!/bin/sh
# Banc d'essai aa-standby. Ne touche NI aa-proxy-rs NI le Bluetooth :
# MODE=observation, INIT=/bin/true, VGATE bidon (donc jamais de sonde OBD reelle).
# Usage : AA_STANDBY=/tmp/aa-standby.v44 ESSAIS="C A B" sh test-aa-standby.sh
T=/tmp/sbtest
ESSAIS=${ESSAIS:-"A B C"}
prep() {   # $1 = VEILLE_MAX  $2 = udc initial  $3 = gadget initial  $4 = focus initial (vide = aucun)
  rm -rf $T; mkdir -p $T
  echo "$2" > $T/udc
  echo "USB=1" > $T/extcon
  : > $T/obd.log ; : > $T/rs.log ; printf "%s" "$3" > $T/gadget
  [ -n "$4" ] && echo "[hu-focus] VIDEO_FOCUS mode=$4" > $T/rs.log
  echo observation > $T/mode
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
obd()   { echo "  battery_level_percentage: 40" >> $T/obd.log; }
focus() { echo "[hu-focus] VIDEO_FOCUS mode=$1" >> $T/rs.log; }
mark()  { echo "### t=${1}s  $2" >> $T/standby.log; }
fin()   { mark $t "fin de l'essai $1"; kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null; cp $T/standby.log /tmp/essai$1.log; }

for E in $ESSAIS; do case $E in
A)
echo "############ ESSAI A — va-et-vient (scenario du demarrage 98) ############"
prep 7200 "not attached" "" ""
$T/run & PID=$!
t=0
while [ $t -lt 260 ]; do
  sleep 5; t=$((t+5))
  [ $t -eq 50 ]  && mark $t "l'OBD repond : la voiture roule, mais l'autoradio n'est pas encore enumere"
  [ $t -eq 200 ] && mark $t "l'autoradio s'enumere enfin (USB -> configured)" && echo configured > $T/udc
  [ $t -eq 215 ] && mark $t "la voiture s'eteint : plus d'OBD, USB detache" && echo "not attached" > $T/udc
  if [ $t -ge 50 ] && [ $t -lt 215 ]; then obd; fi
done
fin A ;;
B)
echo "############ ESSAI B — filet homme mort (VEILLE_MAX abaisse a 60 s) ############"
prep 60 "not attached" "" ""
$T/run & PID=$!
t=0
while [ $t -lt 210 ]; do sleep 5; t=$((t+5)); done
fin B ;;
C)
echo "############ ESSAI C — 2026-09-25 : USB configured + OBD muet + focus perime ############"
prep 7200 "configured" "ffb00000.usb" "2"
$T/run & PID=$!
t=0
while [ $t -lt 215 ]; do
  sleep 5; t=$((t+5))
  [ $t -eq 10 ]  && mark $t "un seul paquet OBD (comme apres une sonde), puis silence total, USB reste configured"
  [ $t -eq 10 ]  && obd
  [ $t -eq 130 ] && mark $t "v4.3 aurait dormi a ~35s (focus perime) puis a ~100s (filet lent). Maintenant un VRAI focus 1 -> 2, USB toujours configured : ne doit PAS dormir"
  [ $t -eq 130 ] && focus 1
  [ $t -eq 140 ] && focus 2
  [ $t -eq 170 ] && mark $t "la voiture s'eteint vraiment : USB detache -> VEILLE attendue ~25s plus tard" && echo "not attached" > $T/udc
done
fin C ;;
esac; done
echo "TERMINE"
