#!/usr/bin/env python3
# Drives scripts/tick-report.py against small logs shaped like the host's own.
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "tick-report.py"


def tick(stamp, seconds):
    return (f"[2026.11.12-{stamp}:000][ 12]LogNetPlayerMovement: Warning: TickInterval exceeded threshold=[0.100000s] "
            f"MaxTickInterval=[{seconds:.6f}s] MaxExecutionTime=[0.000100s]\n")


def logs(tmp):
    game = (
        tick("15.19.59", 9.0)                       # before the window: not counted
        + tick("15.20.10", 0.2) + tick("15.21.10", 0.6) + tick("15.22.10", 1.5)
        + "[2026.11.12-15.22.30:000][ 40]LogNetPlayerMovement: Warning: ServerMove: TimeStamp expired: 1.0, CurrentTimeStamp: 2.0\n"
        + "[2026.11.12-15.24.00:000][ 50]LogUWEAnalytics: Not logged in to GPP. Queuing up event 'autosave_completed'.\n"
        + tick("15.30.00", 3.0)                     # the window ends at 15:30: not counted
    )
    (tmp / "game.log").write_text(game)
    # The archived copy repeats one line with a prefix, as the s6 log does: it counts once.
    (tmp / "game.log.prev").write_text("[2026-11-12T15:20:10Z] " + tick("15.20.10", 0.2))
    mod = ("[2026-11-12 15:21:00.1] [Lua] [SN2SlotFreeHost] console as dirtbikr59: HealMe (game reply lines follow)"
           "[2026-11-12 15:21:04.1] [Lua] [SN2SlotFreeHost] console as dirtbikr59 failed: no controller"
           "[2026-11-12 15:25:00.1] [Lua] [SN2SlotFreeHost] forced save requested on the host controller")
    (tmp / "UE4SS.log").write_text(mod)
    (tmp / "metrics.csv").write_text("utc,cpu_cores,mem_mib,players\n2026-11-12T15:20:30Z,2,6000,1\n"
                                     "2026-11-12T15:25:30Z,2,6000,2\n2026-11-12T15:40:00Z,2,6000,4\n")


def run(tmp, *extra):
    out = subprocess.run([sys.executable, str(SCRIPT), "--json", "--game-log", str(tmp / "game.log"),
                          "--game-log", str(tmp / "game.log.prev"), "--mod-log", str(tmp / "UE4SS.log"),
                          "--metrics", str(tmp / "metrics.csv"), *extra], check=True, capture_output=True, text=True)
    return [json.loads(line) for line in out.stdout.splitlines()]


def test_one_window_counts_each_thing_once_and_only_inside_the_span() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        logs(tmp)
        [r] = run(tmp, "--from", "2026-11-12T15:20", "--to", "2026-11-12T15:30")
        assert r["slow_frames"] == 3 and r["max_s"] == 1.5
        assert (r["p50_s"], r["p95_s"]) == (0.6, 1.5)
        assert (r["over_0_5_s"], r["over_1_s"]) == (2, 1)
        assert (r["servermove_expired"], r["game_autosaves"], r["host_saves"]) == (1, 1, 1)
        assert r["console_commands"] == 1  # the failed one is not a command the game ran
        assert r["players"] == {"min": 1, "max": 2, "mean": 1.5, "samples": 2}


def test_windows_split_the_span_and_an_empty_one_says_so() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        logs(tmp)
        first, second = run(tmp, "--from", "2026-11-12T15:20", "--to", "2026-11-12T15:30", "--window", "5")
        assert first["slow_frames"] == 3 and second["slow_frames"] == 0 and second["p95_s"] is None
        assert second["host_saves"] == 1 and first["host_saves"] == 0
        text = subprocess.run([sys.executable, str(SCRIPT), "--game-log", str(tmp / "game.log"), "--mod-log",
                               str(tmp / "UE4SS.log"), "--metrics", str(tmp / "metrics.csv"),
                               "--from", "2026-11-12T15:26", "--to", "2026-11-12T15:29"],
                              check=True, capture_output=True, text=True).stdout
        assert "no slow frames logged" in text and "players unknown" in text


def test_a_backwards_span_is_refused() -> None:
    r = subprocess.run([sys.executable, str(SCRIPT), "--from", "2026-11-12T15:30", "--to", "2026-11-12T15:20"],
                       capture_output=True, text=True)
    assert r.returncode == 2 and "--to must be after --from" in r.stderr
