#!/bin/bash
# Removes WindowServer's one-refresh presentation-latency lead: every swap is retargeted to the
# first vsync at least 2 ms after its submission, so the display controller flips a frame at the
# next vsync it can make instead of the one after. Synced flips, no tearing. Runs under launchd
# as root.
set -u
WS=$(pgrep -x WindowServer) || { sleep 5; exit 1; }
SCRIPT=$(mktemp /tmp/umbra-flipshift.XXXXXX)
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<D
#pragma D option quiet
#pragma D option destructive
int64_t period, lastvsync;
/* vsync_callback(fb, count, vsync time, refresh period, server), in continuous-time ticks */
pid$WS:QuartzCore:*IOMFBServer??vsync_callback*:entry /arg3 > 100000 && arg3 < 2000000/ { period = arg3; lastvsync = arg2; }
/* IOMobileFramebufferSwapEnd submits the 1760-byte swap record through selector 5. Record
   offset 0x0 is the target presentation time, 0x20 the submit time (continuous ticks).
   The display controller shows a frame at the refresh its target lands on only when the target
   sits on the vsync grid (WindowServer stamps vsync - period/8); an off-grid target slips a
   refresh. Retarget every swap to the first vsync at least 2 ms after submission, the earliest
   refresh it can still make. */
pid$WS:IOKit:IOConnectCallStructMethod:entry /arg1 == 5 && arg3 == 1760 && period && lastvsync/ {
  this->submit = *(int64_t *)copyin(arg2 + 0x20, 8);
  this->earliest = this->submit + 48000 - lastvsync;
  this->refreshes = this->earliest <= 0 ? 0 : (this->earliest + period - 1) / period;
  this->t = (int64_t *)alloca(8);
  *this->t = lastvsync + this->refreshes * period - period / 8;
  copyout(this->t, arg2, 8);
}
proc:::exit /pid == $WS/ { exit(0); }
D
/usr/sbin/dtrace -Z -s "$SCRIPT"
