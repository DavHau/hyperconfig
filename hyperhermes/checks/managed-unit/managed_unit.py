"""Offline check of patches/hermes-gateway-managed-unit-only.patch on the patched package.

With HERMES_GATEWAY_MANAGED_UNIT/_HOME set for the process's HERMES_HOME:
  - ensure_gateway_runtime (what a cron worker, the TUI and Desktop call) starts nothing and
    answers "starting"/deadline, also for a named profile the home's gateway serves;
  - a unit that stays stopped/failed is reported at once, with the systemctl hint;
  - spawn_unmanaged_gateway refuses; `gateway restart --detach`'s replacement prints the hint;
  - `gateway run` (with --force too) refuses before the respawn-storm log, start_gateway too;
  - is_managed_unit_main_process needs SYSTEMD_EXEC_PID == own pid and /system.slice/<unit>;
  - another HERMES_HOME and a standalone profile are not covered.
Without the variable, upstream's path still reaches the spawn (stubbed: nothing really starts).
"""
import asyncio
import os
import subprocess
import sys
import tempfile
from pathlib import Path

home = Path(os.environ["HERMES_HOME"])
home.mkdir(parents=True, exist_ok=True)
UNIT = "hermes-agent-alice.service"
os.environ["HERMES_GATEWAY_MANAGED_UNIT"] = UNIT
os.environ["HERMES_GATEWAY_MANAGED_HOME"] = str(home)

from hermes_cli import gateway_managed_unit as gmu
from hermes_cli import gateway_runtime, gateway_runtime_start
from hermes_cli.gateway_runtime_service import RuntimeStartError

fails = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


spawned = []
real_spawn = gateway_runtime_start.spawn_unmanaged_gateway


def fake_spawn(profile_home, *, deadline, idle_exit=False, force=False):
    spawned.append(str(profile_home))
    raise RuntimeStartError("spawn_stubbed")


# 1. the home the variable covers
check("unit_managing_home(own home)", gmu.unit_managing_home(home) == UNIT)
other = Path(tempfile.mkdtemp()) / ".hermes"
other.mkdir()
check("unit_managing_home(other home) is None", gmu.unit_managing_home(other) is None)
profile = home / "profiles" / "work"
profile.mkdir(parents=True)
(profile / "config.yaml").write_text("model: x\n")
check(f"unit_serving_home(named profile) (got {gmu.unit_serving_home(profile)})",
      gmu.unit_serving_home(profile) == UNIT)
solo = home / "profiles" / "solo"
solo.mkdir(parents=True)
(solo / "config.yaml").write_text("gateway:\n  standalone: true\n")
check("unit_serving_home(standalone profile) is None", gmu.unit_serving_home(solo) is None)

# 2. ensure never spawns for the managed home
gateway_runtime_start.spawn_unmanaged_gateway = fake_spawn
result = gateway_runtime.ensure_gateway_runtime(home, timeout=3.0, idle_exit=True)
check(f"ensure waits for the unit (got {result.state}/{result.reason_code})",
      result.state == "starting" and result.reason_code == "deadline")
check("ensure spawned nothing", spawned == [])
result = gateway_runtime.ensure_gateway_runtime(profile, timeout=3.0, idle_exit=True)
check(f"ensure waits for the unit for a served profile (got {result.state}/{result.reason_code})",
      result.state == "starting" and result.reason_code == "deadline" and spawned == [])

# 2b. a unit that stays down is reported at once, not waited out
real_state, real_watch = gmu.unit_state, gmu.StoppedUnitWatch
gmu.StoppedUnitWatch = lambda: real_watch(grace=0.5, interval=0.1)
for state, queued, code, hint in [("failed", False, "service_failed", "systemctl reset-failed " + UNIT),
                                  ("inactive", False, "service_inactive", "systemctl start " + UNIT)]:
    gmu.unit_state = lambda unit, st=(state, queued): st
    import time as _t
    t0 = _t.monotonic()
    result = gateway_runtime.ensure_gateway_runtime(home, timeout=30.0, idle_exit=True)
    took = _t.monotonic() - t0
    check(f"ensure reports a {state} unit in {took:.1f}s (got {result.reason_code})",
          result.reason_code == code and hint in (result.detail or "") and took < 10 and spawned == [])
# a stop with a start job queued (a deploy, an auto-restart) is waited for
gmu.unit_state = lambda unit: ("inactive", True)
result = gateway_runtime.ensure_gateway_runtime(home, timeout=3.0, idle_exit=True)
check(f"ensure waits for a queued start (got {result.reason_code})", result.reason_code == "deadline")
gmu.unit_state, gmu.StoppedUnitWatch = real_state, real_watch

# 3. without the variable, the upstream path reaches the spawn
del os.environ["HERMES_GATEWAY_MANAGED_UNIT"]
result = gateway_runtime.ensure_gateway_runtime(home, timeout=3.0, idle_exit=True)
check(f"unmanaged home still spawns (got {result.reason_code})",
      spawned == [str(home.resolve())] and result.reason_code == "spawn_stubbed")
os.environ["HERMES_GATEWAY_MANAGED_UNIT"] = UNIT
gateway_runtime_start.spawn_unmanaged_gateway = real_spawn

# 4. the spawn primitive itself refuses
try:
    real_spawn(home, deadline=10**12, idle_exit=True)
    check("spawn_unmanaged_gateway refuses", False)
except RuntimeStartError as exc:
    check(f"spawn_unmanaged_gateway refuses ({exc.reason})", exc.reason == "service_managed")
check("no gateway-stdio.log from a refused spawn", not (home / "logs" / "gateway-stdio.log").exists())
import contextlib
import io
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = gateway_runtime_start.start_detached_replacement(home)
check(f"restart --detach replacement refuses with the hint (rc={rc})",
      rc == 1 and "systemctl status " + UNIT in err.getvalue() and "service_managed" not in err.getvalue())

# 5. main-process detection
os.environ.pop("SYSTEMD_EXEC_PID", None)
check("not main process without SYSTEMD_EXEC_PID", not gmu.is_managed_unit_main_process())
os.environ["SYSTEMD_EXEC_PID"] = str(os.getpid() + 1)
check("not main process with a parent's SYSTEMD_EXEC_PID", not gmu.is_managed_unit_main_process())
os.environ["SYSTEMD_EXEC_PID"] = str(os.getpid())
check("not main process outside the unit's cgroup", not gmu.is_managed_unit_main_process())
real_cgroup = gmu._own_cgroup
gmu._own_cgroup = lambda: "/user.slice/user-1000.slice/user@1000.service/app.slice/" + UNIT
check("not main process in a user unit of the same name", not gmu.is_managed_unit_main_process())
gmu._own_cgroup = lambda: "/system.slice/" + UNIT
check("main process: own pid + the system unit's cgroup", gmu.is_managed_unit_main_process())
gmu._own_cgroup = real_cgroup
os.environ.pop("SYSTEMD_EXEC_PID", None)

# 6. `hermes gateway run --force` refuses before it binds anything
proc = subprocess.run([sys.executable, "-m", "hermes_cli.main", "gateway", "run", "--force"],
                      capture_output=True, text=True, timeout=120, env=dict(os.environ))
check(f"gateway run --force refuses (rc={proc.returncode})", proc.returncode != 0
      and "managed by the systemd unit " + UNIT in proc.stderr)
check("no gateway.pid written", not (home / "gateway.pid").exists())
check("refused run left no respawn-storm record", not (home / "gateway-starts.log").exists())
proc = subprocess.run([sys.executable, "-m", "hermes_cli.main", "-p", "work", "gateway", "run"],
                      capture_output=True, text=True, timeout=120, env=dict(os.environ))
check(f"gateway run of a served profile refuses (rc={proc.returncode})", proc.returncode != 0
      and "managed by the systemd unit " + UNIT in proc.stderr)

# 7. start_gateway directly (cli.py's and gateway.run's entry)
from gateway.run import start_gateway
check("start_gateway returns False", asyncio.run(start_gateway()) is False)

if fails:
    print(f"{len(fails)} check(s) failed")
    sys.exit(1)
print("all checks passed")
