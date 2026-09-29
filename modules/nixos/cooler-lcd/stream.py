"""Stream the cooler LCD frames rendered by render.py.

Usage: cooler-lcd-stream HIDRAW_DEVICE FRAMES_DIR

The snowflake spins at a speed proportional to the CPU use of all cores
together, never slower than MIN_SPEED; every 20 s "I <icon> Joy" shows
for 1 s, the icon alternating between a heart and a head louse. The
panel falls back
to its stock image seconds after frames stop, so an unchanged frame is
resent as a keepalive.

hidraw takes a leading report-ID byte per write (0: the report descriptor
declares no IDs); each write is one 512-byte output report and blocks
until the panel took it, which paces a frame at ~50 ms. A write error
(device gone) ends the process; systemd restarts it.
"""

import os
import sys
import time

FRAME = 512 + 240 * 320 * 2
MESSAGE_EVERY = 20
MESSAGE_FOR = 1
# Degrees per second at 100% CPU; 10% CPU turns a tenth as fast. At ~50 ms
# per frame the fastest spin advances ~11 degrees a frame.
MAX_SPEED = 220
# Floor for an idle CPU: 2-degree frames at 15 per second still read as
# smooth motion; much slower and the single steps show.
MIN_SPEED = 30


def load(path):
    data = open(path, "rb").read()
    return [
        [b"\x00" + data[f + o:f + o + 512] for o in range(0, FRAME, 512)]
        for f in range(0, len(data), FRAME)
    ]


def cpu_times():
    # Aggregate "cpu" line: every core. Fields 8+ (guest) are already
    # counted in user/nice.
    with open("/proc/stat") as f:
        ticks = [int(x) for x in f.readline().split()[1:9]]
    return sum(ticks) - ticks[3] - ticks[4], sum(ticks)


logo = load(sys.argv[2] + "/logo")
# Alternate flashes: heart, louse, heart, ...
messages = [load(f"{sys.argv[2]}/message-{name}")[0]
            for name in ("heart", "louse")]
fd = os.open(sys.argv[1], os.O_WRONLY)
busy, total = cpu_times()
sampled = last = sent = time.monotonic()
usage = angle = 0.0
shown = None
while True:
    now = time.monotonic()
    if now - sampled >= 1:
        b, t = cpu_times()
        usage = (b - busy) / (t - total) if t > total else 0.0
        busy, total, sampled = b, t, now
    now_wall = time.time()
    phase = now_wall % MESSAGE_EVERY
    if phase < MESSAGE_FOR:
        # The spin pauses under the message and resumes where it was.
        which = int(now_wall // MESSAGE_EVERY) % len(messages)
        key, frame = f"message-{which}", messages[which]
        pause = MESSAGE_FOR - phase
    else:
        speed = max(MIN_SPEED, MAX_SPEED * usage)
        step = 120 / len(logo)
        angle = (angle + speed * (now - last)) % 120
        key = int(angle / step)
        frame = logo[key]
        # Wake for the next frame's angle or the next message.
        pause = min((step - angle % step) / speed, MESSAGE_EVERY - phase)
    last = now
    # An unchanged frame is only resent as the keepalive.
    if key != shown or now - sent >= 0.5:
        for report in frame:
            os.write(fd, report)
        shown, sent = key, time.monotonic()
    time.sleep(min(pause, 0.5))
