# aa-standby

Stop Android Auto when the car is off, bring it back when the car wakes up — using a signal the
kernel already publishes. **No GPIO, no resistors, no cut USB cable, no extra hardware.**

> **Tested on:** Hyundai Kona EV 2021 with a Gen5W head unit (Mobis `standard_m_5`, software
> `V014.010.250818`, Android Auto protocol 1.4), running on an AAWireless Two. One car, one board —
> see [Status and caveats](#status-and-caveats). **v4.3 is in production** on that car since
> 2026-09-21: ignition off → Android Auto stopped in 23 s; restart → Android Auto on screen in 32 s.

Companion script for [aa-proxy-rs](https://github.com/aa-proxy/aa-proxy-rs). Plain POSIX shell,
runs on BusyBox.

## The problem

Many cars (Kia/Hyundai especially) keep the Android Auto USB port powered permanently. The dongle
therefore never powers down: it sits in the driveway broadcasting an SSID, pulling your phone off
the home Wi-Fi and repeatedly trying to start an Android Auto session while you are nowhere near
the car.

The usual answers are a Y-split cable powered from the (switched) lighter socket — which brings
back the full boot delay — or wiring a switched 12 V line down to a GPIO pin.

## The signal

Neither is necessary. The USB **device controller** state tells you whether the head unit is alive:

```
/sys/class/udc/<udc>/state
```

| Value | Meaning |
|---|---|
| `configured` | the head unit's USB host is up and has enumerated the gadget |
| `not attached` | the head unit is powered down |

On ignition-off it goes `configured` → `not attached`. When the car comes back:
`not attached` → `default` → `configured`.

**This is not the same thing as VBUS.** The car keeps supplying 5 V — that is precisely why the
board never powers down — but the *host controller* goes away. Conflating the two is what makes
this problem look unsolvable. If you want the power rail itself, it is exposed separately at the
PHY level:

```
/sys/class/extcon/<extcon>/state   →   USB=0|1
```

`aa-standby` logs both, so you can tell "car is still feeding 5 V" apart from "head unit is off".

### Why it works while Android Auto is stopped

The useful part: on the hardware this was developed on, **stopping `aa-proxy-rs` does not tear down
the USB gadget**. Verified explicitly — car on, `aa-proxy-rs` stopped for 12 s:

```
t+3s → t+12s   udc=configured   UDC=[ffb00000.usb]
```

The gadget stays bound, so `udc/state` keeps tracking the head unit *while Android Auto is down*.
That is what makes an "awake but silent" standby possible once a session has existed.

(It is `aa-proxy-rs` **starting** that rebuilds the gadget, so expect a ~13 s `not attached` blip
right after a restart.)

### ⚠️ What that measurement does *not* mean — read before you get clever

That measurement was taken **with a session already established**. It proves the gadget
*survives* stopping `aa-proxy-rs`. It does **not** prove the gadget can be *created* without it.
Measured with the car off, `aa-proxy-rs` running:

```
/sys/kernel/config/usb_gadget/accessory/UDC   (empty)
/sys/kernel/config/usb_gadget/default/UDC     (empty)
```

**No gadget is bound at all.** `aa-proxy-rs` only presents the USB accessory *after* the Bluetooth
handshake with the phone. So on this hardware **Bluetooth is on the critical path for creating the
USB gadget**, and two tempting ideas are dead on arrival:

- **Cutting the Bluetooth radio during standby** (`bluetoothctl power off`) to stop the phone
  being pestered while keeping `aa-proxy-rs` alive. Deployed on 2026-09-18 as "v5": radio off →
  no handshake → gadget never created → `udc` never becomes `configured` → the wake condition can
  never fire. **Android Auto was dead for 6 h 30** until manual recovery. A defensive rule that
  re-killed the radio when `aa-proxy-rs` tried to bring it back made it worse. Never do this.
- **Not starting `aa-proxy-rs` at boot when the head unit is absent** ("option B"). Same root
  cause: there would be nothing for the head unit to enumerate when it powers up, so the wake
  could never be detected. The script's boot guard (`gadget_bound()` wait, then *leave Android Auto
  running* if the gadget never appears) exists precisely for this. Do not remove it.

The consequence is a floor you cannot get under in software: when the board boots with the car
off, `aa-proxy-rs` must run — and may call the phone — for about **`BOOT_GRACE` + a few seconds**
before the USB rule can conclude the head unit is really absent. On the Kona that is ~41 s per
board reboot. The only way to remove it is hardware: power the board from a switched source.

## How it decides

**Sleep** — any of:

- USB detached for `USB_OFF` seconds (primary; needs no OBD at all)
- head unit took the screen back *and* OBD went quiet for `FOCUS_CONFIRM` seconds (fast path,
  requires the optional WASM hook below)
- no OBD data for `OFF_AFTER` seconds (slow net)

**Wake** — any of:

- USB reattached — sub-second; the wake itself needs no Bluetooth, but the gadget it watches
  only exists if a session was established earlier (see the caveat above)
- OBD data reappears
- Bluetooth OBD dongle reachable *and* a short OBD probe confirms the car is answering

**Safety nets** — every one of them only ever *delays a sleep* or *forces a wake*. None can keep
Android Auto down:

- if the script is killed, Android Auto is restarted before it exits
- if `aa-proxy-rs` dies while ACTIVE, it is restarted
- if it went to sleep on an OBD criterion but the USB never dropped within `FALSE_OFF` seconds, it
  concludes it was wrong (typically a Bluetooth OBD dongle dying mid-drive), restarts Android Auto
  and stops trusting OBD until data comes back
- at boot, if the USB is not attached it waits for the gadget; if the gadget never appears it
  leaves Android Auto running rather than risk a board that can never be enumerated (see above)
- **the USB rule will not sleep while OBD data is flowing** (v4.3). Live OBD means the car's bus is
  up, so it is not off — even if the head unit has not enumerated yet. Without an OBD dongle this
  guard is simply never reached and the behaviour is identical to v4.2
- **`MIN_ACTIF`** (v4.3): after any wake, no new sleep for 90 s. Bounds any flip-flop to one
  stop/start per 90 s. Does not apply at boot, so the initial sleep still happens at ~41 s
- **`VEILLE_MAX` dead-man switch** (v4.3): after 2 h of continuous standby Android Auto is restarted
  regardless of anything else. If the car really is off, the USB rule puts it back to sleep ~40 s
  later — about 90 s every 2 h. In exchange **no failure can last indefinitely**. Had it existed on
  2026-09-18, the v5 outage would have lasted 2 h instead of 6 h 30

### The flip-flop bug fixed in v4.3

Three days of logs in observation mode (98 boots) exposed a defect in v4.2: when the car is
starting but the head unit has not enumerated yet, OBD answers while the USB is still detached.
The OBD wake path set `last_usb_ok` to now, the USB rule expired again `USB_OFF` seconds later, and
the script oscillated:

```
up=41s   SLEEP  (USB detached 36 s)
up=56s   WAKE   (car confirmed by OBD)
up=81s   SLEEP  (USB detached 25 s)      <- counter restarted from zero
up=92s   WAKE ...                          five cycles in three minutes
```

In real mode that is five `stop`/`start` cycles of `aa-proxy-rs` in three minutes — exactly the kind
of churn that can leave the USB gadget unbound. The "don't sleep while OBD talks" guard removes the
cause; `MIN_ACTIF` bounds the damage if anything similar ever reappears.

**Without an OBD dongle everything still works.** No OBD data ever arrives, so every OBD rule stays
inert and only the USB rule acts.

## Measured timings

Hyundai Kona EV 2021, Gen5W head unit, AAWireless Two. **Starting points, not gospel** —
measure your own.

| Event | Observed |
|---|---|
| `udc` detaching after ignition-off | up to **~169 s** later — do not react instantly |
| `udc` attaching after board boot | **22–28 s** — hence `BOOT_GRACE` |
| Spurious detach/reattach while driving | **10–13 s** blips — hence `USB_OFF` = 25 s |
| Android Auto on screen after boot | ~35 s |
| Ignition off → Android Auto stopped by the script (fast path) | **23 s** |
| Head unit keeping USB alive after a short off/door-open/on | never dropped — correctly ignored |

### How often the board reboots on this car

The Kona cuts and restores the accessory rail constantly while parked (remote preheating, BMS
wake-ups). From 98 boots over 24.4 h of cumulative uptime, in observation mode:

| Boot lasted | Count | What standby can do about it |
|---|---|---|
| ≤ 15 s | 28 | nothing — the board dies before any decision |
| 15–60 s | 29 | almost nothing — sleep at ~41 s, board dies at ~50 s |
| 1–10 min | 9 | useful |
| > 10 min | 32 | **this is where it pays** |

Median boot: **51 s**. On this log, Android Auto would have run pointlessly for **1 h 54** without
standby and **36 min** with it (53 car-off boots × ~41 s) — about **69 %** less phone-pestering.
The remaining 36 min is the boot floor described above.

## Configuration

Nothing in the script needs editing. Drop a `/etc/aa-standby.conf` next to it and override only
what you need — see [`aa-standby.conf.example`](aa-standby.conf.example):

```sh
USB_OFF=30
VGATE=aa:bb:cc:dd:ee:ff
```

The USB paths are **auto-detected**: the script takes the single entry under `/sys/class/udc/` and
`/sys/class/extcon/`, which is right on most boards. Override `UDC_STATE` / `EXTCON_STATE` only if
`ls /sys/class/udc/` shows more than one. The resolved paths are printed in the log at startup:

```
chemins : udc=/sys/class/udc/ffb00000.usb/state extcon=/sys/class/extcon/extcon0/state ...
```

| Setting | Notes |
|---|---|
| `USB_OFF` | USB detached this long ⇒ head unit is off (default 25 s) |
| `BOOT_GRACE` | grace after start, since the USB takes 22–28 s to attach at boot (35 s) |
| `FALSE_OFF` | slept on an OBD criterion but the USB never dropped ⇒ we were wrong, wake up (240 s) |
| `OFF_AFTER` | slow net: no OBD data at all (90 s) |
| `FOCUS_CONFIRM` | screen handed back to the car + OBD silence; needs the WASM hook (25 s) |
| `MIN_ACTIF` | after a wake, no new sleep for this long — anti flip-flop (90 s) |
| `VEILLE_MAX` | dead-man switch: after this long asleep, restart Android Auto regardless (7200 s) |
| `VGATE` | MAC of your Bluetooth OBD dongle; leave alone if you have none |
| `INIT` | your `aa-proxy-rs` init script |
| `GADGET_UDC` | the `accessory` gadget's `UDC` file; only the boot guard and the test bench use it |

Mode lives in `/data/aa-standby.mode`:

- `observation` — logs every decision, **changes nothing**. Start here.
- `reel` — actually stops and starts Android Auto.

Log: `/data/aa-standby.log`, rotated at 1 MB.

## Install

```sh
cp aa-standby /etc/aa-standby && chmod +x /etc/aa-standby
cp S96aa-standby /etc/init.d/ && chmod +x /etc/init.d/S96aa-standby
echo observation > /data/aa-standby.mode
/etc/init.d/S96aa-standby start
```

Watch `/data/aa-standby.log` through a few real drives, then switch to `reel`.

To back out at any time:

```sh
echo observation > /data/aa-standby.mode && /etc/init.d/S96aa-standby restart
```

Nothing is stopped or held in `observation`, so this is a complete kill switch.

## Testing a change without touching the running daemon

Every input the script reads — `UDC_STATE`, `EXTCON_STATE`, `GADGET_UDC`, `OBDLOG`, `RSLOG`,
`MODE_FILE`, `LOG`, `INIT`, `VGATE` — is a variable that `/etc/aa-standby.conf` can override.
[`test-aa-standby.sh`](test-aa-standby.sh) uses that to run the state machine against fake files
under `/tmp/sbtest/`, with `INIT=/bin/true` and a bogus `VGATE` (so the OBD probe can never grab
your real Bluetooth adapter), and replays timelines taken from real logs:

- **Test A** replays the flip-flop scenario above and asserts the script stays awake while OBD talks
- **Test B** lowers `VEILLE_MAX` to 60 s and asserts the dead-man fires, `MIN_ACTIF` delays the
  re-sleep, and the exit trap restarts Android Auto

```sh
scp aa-standby test-aa-standby.sh root@<board>:/tmp/
ssh root@<board> 'cd /tmp && AA_STANDBY=/tmp/aa-standby sh test-aa-standby.sh'
cat /tmp/essaiA.log /tmp/essaiB.log
```

About 8 minutes. The real `aa-proxy-rs` is never touched. **Run this before switching any
modified script to `reel`** — the v5 outage happened precisely because a new state machine went
straight to real mode without ever having been seen working. Keep new inputs as variables so the
bench stays possible.

## Optional: faster shutdown detection

The `FOCUS_CONFIRM` path needs a WASM hook that logs `VIDEO_FOCUS mode=N` (1 = Android Auto has the
screen, 2 = the car took it back). Without it the script simply falls back to the USB and OBD
rules. On the car above, the USB rule alone is what does the real work.

## Status and caveats

Young. Developed and measured on **one car and one board** — a Hyundai Kona EV 2021 with a Gen5W
head unit, on an AAWireless Two. Other head units may detach the USB differently, or not at all. Treat it as a working reference
implementation of the idea, not a finished product.

Known limits:

- **Stopping Android Auto does not stop the Wi-Fi.** `hostapd` is a separate process and keeps
  broadcasting the SSID, so a phone in range will still join the car's network. Not handled here.
- On the car above the USB power is itself cut intermittently while parked — median boot 51 s, see
  the reboot table. A long silent standby may not survive on every car. The `extcon` line tells you
  whether this is happening.
- **~41 s of phone-pestering per board reboot with the car off** is a floor, not a bug — see
  "What that measurement does not mean". Only switched power removes it.
- The script's comments and log messages are **in French**. The mechanism is documented in English
  here.

### Dead ends — measured, not assumed. Please don't reopen them without new evidence

| Idea | What happened |
|---|---|
| Cut the Bluetooth radio during standby (v5) | Circular deadlock, **6 h 30 outage**. Bluetooth is on the critical path for creating the USB gadget |
| Don't start `aa-proxy-rs` at boot when the head unit is absent ("option B") | Same root cause: no gadget → nothing to enumerate → wake impossible. Never fired in 98 boots; the failsafe always did |
| Passive mode `connect=""` so the board stops calling the phone | The **phone** initiates too (`inbound RFCOMM`), and the board accepts. Pestering continues |
| `l2ping` the head unit's Bluetooth address to detect ignition | Head unit and board have no BT relationship; `Host is down` with the car on, not visible in scan |
| `l2ping` the OBD dongle as a wake criterion | Answers with the car off. 5 false wakes out of 5. Only an actual OBD probe discriminates |
| Simulate ignition-off by unbinding the gadget (`echo "" > .../UDC`) | `aa-proxy-rs` rebuilds it in ~10 s; not the same as the host disappearing. Lower `USB_OFF` temporarily instead |

## Licence

[MIT](LICENSE). Take what you need — that is the point.
