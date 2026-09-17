# aa-standby

Stop Android Auto when the car is off, bring it back when the car wakes up — using a signal the
kernel already publishes. **No GPIO, no resistors, no cut USB cable, no extra hardware.**

> **Tested on:** Hyundai Kona EV 2021 with a Gen5W head unit (Mobis `standard_m_5`, software
> `V014.010.250818`, Android Auto protocol 1.4), running on an AAWireless Two. One car, one board —
> see [Status and caveats](#status-and-caveats).

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
That is what makes an "awake but silent" standby possible: the wake signal costs nothing and needs
no Bluetooth. Worth verifying on your own build — it may differ.

(It is `aa-proxy-rs` **starting** that rebuilds the gadget, so expect a ~13 s `not attached` blip
right after a restart.)

## How it decides

**Sleep** — any of:

- USB detached for `USB_OFF` seconds (primary; needs no OBD at all)
- head unit took the screen back *and* OBD went quiet for `FOCUS_CONFIRM` seconds (fast path,
  requires the optional WASM hook below)
- no OBD data for `OFF_AFTER` seconds (slow net)

**Wake** — any of:

- USB reattached — sub-second, no Bluetooth
- OBD data reappears
- Bluetooth OBD dongle reachable *and* a short OBD probe confirms the car is answering

**Safety nets:**

- if the script is killed, Android Auto is restarted before it exits
- if `aa-proxy-rs` dies while ACTIVE, it is restarted
- if it went to sleep on an OBD criterion but the USB never dropped within `FALSE_OFF` seconds, it
  concludes it was wrong (typically a Bluetooth OBD dongle dying mid-drive), restarts Android Auto
  and stops trusting OBD until data comes back
- at boot, Android Auto is only started if the USB is attached — but if the gadget never appears at
  all, it starts anyway rather than risk leaving Android Auto dead

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
| `VGATE` | MAC of your Bluetooth OBD dongle; leave alone if you have none |
| `INIT` | your `aa-proxy-rs` init script |

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
- On the car above the USB power is itself cut intermittently while parked — the board rebooted 12
  times in one morning, apparently from remote preheating cycling the accessory rail. A long silent
  standby may not survive on every car. The `extcon` line tells you whether this is happening.
- The script's comments and log messages are **in French**. The mechanism is documented in English
  here.

## Licence

Not chosen yet — open an issue if you need one.
