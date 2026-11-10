#!/bin/bash
# Removes WindowServer's one-refresh presentation-latency lead: every swap is retargeted to the
# first vsync at least 2 ms after its submission, so the display controller flips a frame at the
# next vsync it can make instead of the one after. It also holds WindowServer's display update
# for UPDATE_DELAY_US after each vsync: the update otherwise submits about 5.8 ms ahead of the
# refresh while the display controller only needs about 3.5 ms, so clients can commit that much
# later and still make the same vsync. Synced flips, no tearing. Runs under launchd as root.
set -u
UPDATE_DELAY_US=${UPDATE_DELAY_US:-2000}
# HEARTBEAT=1 targets the panel's 4.17 ms heartbeat ticks (variable refresh in whole subframes)
# instead of the 8.33 ms vsync grid.
HEARTBEAT=${HEARTBEAT:-0}
[ -f "/Library/Application Support/Umbra/flipshift.conf" ] && . "/Library/Application Support/Umbra/flipshift.conf"
WS=$(pgrep -x WindowServer) || { sleep 5; exit 1; }
SCRIPT=$(mktemp /tmp/umbra-flipshift.XXXXXX)
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<D
#pragma D option quiet
#pragma D option destructive
int64_t period, lastvsync, lasttarget;
/* vsync_callback(fb, count, vsync time, refresh period, server), in continuous-time ticks */
pid$WS:QuartzCore:*IOMFBServer??vsync_callback*:entry /arg3 > 100000 && arg3 < 2000000/ { period = arg3; lastvsync = arg2; }
/* IOMobileFramebufferSwapEnd submits the 1760-byte swap record through selector 5. Record
   offset 0x0 is the target presentation time, 0x20 the submit time (continuous ticks).
   The display controller shows a frame at the refresh its target lands on only when the target
   sits on the vsync grid (WindowServer stamps vsync - period/8); an off-grid target slips a
   refresh. Retarget every swap to the first vsync at least 2 ms after submission, the earliest
   refresh it can still make; in heartbeat mode, to the first 4.17 ms subframe tick at least
   3.5 ms after submission and a full frame after the previous target. */
pid$WS:IOKit:IOConnectCallStructMethod:entry /arg1 == 5 && arg3 == 1760 && period && lastvsync/ {
  this->step = $HEARTBEAT ? period / 2 : period;
  this->submit = *(int64_t *)copyin(arg2 + 0x20, 8);
  this->earliest = this->submit + ($HEARTBEAT ? 84000 : 48000);
  this->earliest = $HEARTBEAT && this->earliest < lasttarget + period ? lasttarget + period : this->earliest;
  this->refreshes = this->earliest <= lastvsync ? 0 : (this->earliest - lastvsync + this->step - 1) / this->step;
  lasttarget = lastvsync + this->refreshes * this->step;
  this->t = (int64_t *)alloca(8);
  *this->t = lasttarget - period / 8;
  copyout(this->t, arg2, 8);
}
/* WindowServer's display update starts about 0.5 ms after each vsync; start it later. */
pid$WS:SkyLight:*CGXUpdateDispla?:entry /$UPDATE_DELAY_US > 0/ { chill($UPDATE_DELAY_US * 1000); }
proc:::exit /pid == $WS/ { exit(0); }
D
/usr/sbin/dtrace -Z -s "$SCRIPT"
