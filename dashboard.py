#!/usr/bin/env python3
"""SCONE dashboard: start, pause, resume and stop the engine, follow its progress live and
browse the proven classes in scone.db.

    python3 dashboard.py [--port 8080]

Standard library only. The engine runs detached in its own process group and writes its output
to scone_run.log, so it keeps running if the dashboard is closed and the dashboard re-attaches
on restart. Progress is parsed from that log and pushed to the browser over Server-Sent Events;
scone.db is only ever opened read-only and only re-queried after the file changes.
"""
import argparse
import codecs
import collections
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
BIN = ROOT / "zig-out" / "bin" / "scone"
DB_PATH = ROOT / "scone.db"
LOG_PATH = ROOT / "scone_run.log"
PID_PATH = ROOT / "scone_run.pid"
STATUS_PATH = ROOT / "scone_status.json"  # live worker view, written by the engine while verifying
Z3LOG_DIR = ROOT / "z3log"  # per-worker Z3 query logs (SCONE_QUERY_LOG), when a run enables them

# Mirrors ast.zig; the database stores enum values as integers.
VARS = ["x", "y", "z"]
UNOPS = ["neg", "not", "clz", "ctz", "popcount"]
BINOPS = ["add", "sub", "mul", "and_op", "or_op", "xor", "shl", "lshr", "ashr", "ult", "ule", "slt", "sle", "eq"]
BIN_SYM = ["+", "-", "*", "&", "|", "^", "<<", ">>", ">>s", "<u", "<=u", "<s", "<=s", "=="]

LOG_LINES = 2000  # log lines kept in memory for new browser tabs
RATE_POINTS = 1200  # throughput samples kept (~10 minutes at the engine's 2 Hz)
RATE_WINDOW = 30.0  # seconds of engine time behind the displayed (rolling) throughput


# ----------------------------------------------------------------------------------------------
# Engine output parser
# ----------------------------------------------------------------------------------------------

RE_ENUM = re.compile(r"Cost (\d+): Processed (\d+) exprs \((\d+) unique\) \| ([\d.]+) expr/s \| elapsed: ([\d.]+)s")
RE_Z3 = re.compile(
    r"Z3: (\d+)/(\d+) tasks, (\d+)/(\d+) exprs \| (\d+) exprs/s \| by absint: (\d+) \| by normal form: (\d+) \| "
    r"by rewriting: (\d+) \| shared CEs: (\d+) \| queries: (\d+) \| CEs: (\d+) \| new classes: (\d+) \| "
    r"timeouts: (\d+) \| ([\d.]+)s"
)
RE_Z3_START = re.compile(r"Z3: verifying (\d+) new expressions across (\d+) tasks in (\d+) classes using (\d+) worker")
RE_LEVEL = re.compile(r"SCONE cost level (\d+)")
RE_RESUME = re.compile(r"Resuming from Cost (\d+)")
RE_SUMMARY = re.compile(r"--- COST (\d+) SUMMARY ---")
RE_SUM_FIELDS = [
    (re.compile(r"Expressions built:\s+(\d+) \(([\d.]+)s\)"), ("exprs_built", "enum_s")),
    (re.compile(r"Classes from fingerprints:\s+(\d+)"), ("fp_classes",)),
    (re.compile(r"Classes after Z3 splits:\s+(\d+) \(\+(\d+)\)"), ("level_classes", "splits")),
    (re.compile(r"Total classes:\s+(\d+)"), ("total_classes",)),
    (re.compile(r"Z3: (\d+) exprs in (\d+) classes, ([\d.]+)s, (\d+) counterexamples"), ("z3_exprs", "z3_classes", "verify_s", "ces")),
    (re.compile(r"\[WARNING\] (\d+) groups timed out"), ("timeouts",)),
    (re.compile(r"Sample grid size:\s+(\d+)"), ("samples",)),
]


def num(s):
    return float(s) if "." in s else int(s)


class Parser:
    """Turns the engine's stderr into structured state. `\\r`-terminated text is a progress line
    that the terminal would overwrite; `\\n`-terminated text is a log line."""

    def __init__(self, run):
        self.run = run
        self.buf = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.summary = None
        self.last = None
        self.window = collections.deque()  # (elapsed, count) of the current phase

    def rolling(self, elapsed, count):
        """Throughput over the last RATE_WINDOW seconds of engine time. Using the engine's own
        clock keeps it right when a whole log is parsed at once (re-attaching to a run)."""
        w = self.window
        if w and elapsed < w[-1][0]:  # a new phase restarted the clock
            w.clear()
        w.append((elapsed, count))
        while len(w) > 2 and elapsed - w[1][0] >= RATE_WINDOW:
            w.popleft()
        t0, c0 = w[0]
        return (count - c0) / (elapsed - t0) if elapsed > t0 else None

    def feed(self, data):
        self.buf += self.decoder.decode(data)
        parts = re.split(r"([\r\n])", self.buf)
        for i in range(0, len(parts) - 1, 2):
            seg, sep = parts[i], parts[i + 1]
            if sep == "\n":
                self.run.add_log(seg)
                self.parse(seg)
            elif seg:
                self.parse(seg)
        self.buf = parts[-1]
        # The current progress line is only terminated by the next one, 500 ms later. Parse it
        # early once the engine has finished writing it (it always ends in padding).
        if self.buf.endswith("   "):
            self.parse(self.buf)

    def flush(self):
        if self.buf.strip():
            self.run.add_log(self.buf)
            self.parse(self.buf)
        self.buf = ""

    def parse(self, s):
        if s == self.last:  # a progress line parsed early is seen again when terminated
            return
        self.last = s
        r = self.run
        if s.startswith("Cost ") and (m := RE_ENUM.search(s)):
            level, done, uniq, rate, el = m.groups()
            r.level = int(level)
            r.phase = "enumerate" if "DONE" not in s else "recompute"
            rolling = self.rolling(float(el), int(done))
            r.progress = {"kind": "enumerate", "processed": int(done), "unique": int(uniq), "rate": rolling if rolling is not None else float(rate),
                          "rate_overall": float(rate), "elapsed": float(el)}
            r.add_rate("enumerate", r.progress["rate"])
        elif s.startswith("Z3: ") and (m := RE_Z3.search(s)):
            g = [num(x) for x in m.groups()]
            keys = ["tasks_done", "tasks", "done", "total", "rate", "absint", "normal_form", "rewriting",
                    "shared_ces", "queries", "ces", "splits", "timeouts", "elapsed"]
            r.progress = {"kind": "verify", **dict(zip(keys, g))}
            rolling = self.rolling(float(g[13]), int(g[2]))
            r.progress["rate_overall"] = g[4]
            if rolling is not None:
                r.progress["rate"] = rolling
            r.phase = "verify" if g[2] < g[3] or g[0] < g[1] else "saving"
            r.add_rate("verify", float(r.progress["rate"]))
        elif m := RE_Z3_START.search(s):
            self.window.clear()
            r.phase = "verify"
            r.progress = {"kind": "verify", "tasks_done": 0, "tasks": int(m[2]), "done": 0, "total": int(m[1]), "rate": 0, "elapsed": 0,
                          "classes": int(m[3]), "workers": int(m[4])}
        elif m := RE_LEVEL.search(s):
            self.window.clear()
            r.level = int(m[1])
            r.phase = "enumerate"
            r.progress = None
        elif m := RE_RESUME.search(s):
            r.phase = "loading"
            r.resumed_from = int(m[1])
        elif s.startswith("Rebuilt ") or "Parallel Recompute" in s:
            pass
        elif m := RE_SUMMARY.search(s):
            self.summary = {"level": int(m[1])}
            r.levels.append(self.summary)
            r.phase = "level done"
            r.progress = None
        elif self.summary is not None and s.startswith("---"):
            self.summary = None
        elif self.summary is not None:
            for rx, keys in RE_SUM_FIELDS:
                if m := rx.search(s):
                    self.summary.update({k: num(v) for k, v in zip(keys, m.groups())})
                    break
        elif "DISTILLING" in s:
            r.phase = "distill"
        elif "error" in s.lower() or "panic" in s.lower() or "[BUG]" in s:
            r.last_error = s.strip()
        else:
            return
        r.touch()


# ----------------------------------------------------------------------------------------------
# Process control
# ----------------------------------------------------------------------------------------------

def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def pid_is_scone(pid):
    out = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return out.endswith("scone")


class Run:
    def __init__(self):
        self.cond = threading.Condition()
        self.version = 0
        self.log = collections.deque(maxlen=LOG_LINES)  # (seq, text)
        self.log_seq = 0
        self.rates = collections.deque(maxlen=RATE_POINTS)  # (seq, t, phase, level, rate)
        self.rate_seq = 0
        self.proc = None  # Popen when we launched it in this dashboard session
        self.pid = None
        self.external_pid = None
        self.stop_requested = False
        self.queued = None  # {"opts", "args", "restart"}: run to start once the current one exits
        self.z3now = None
        self.status_key = None
        self.proc_stats = None
        self.db = {}
        self.db_key = None
        self.db_checked = 0.0
        self._reset(None)
        self.log_file = None
        self.parser = Parser(self)

    def _reset(self, meta):
        self.meta = meta or {}
        self.status = "idle"
        self.exit_code = None
        self.ended = None
        self.level = None
        self.phase = None
        self.progress = None
        self.levels = []
        self.resumed_from = None
        self.last_error = None
        self.paused = False
        self.stop_requested = False
        self.rates.clear()

    def touch(self):
        self.version += 1
        self.cond.notify_all()

    def add_log(self, text):
        self.log_seq += 1
        self.log.append((self.log_seq, text))

    def add_rate(self, phase, rate):
        self.rate_seq += 1
        self.rates.append((self.rate_seq, time.time(), phase, self.level, rate))

    # -- lifecycle -----------------------------------------------------------------------------

    def attach_existing(self):
        """Re-attach to a run started by a previous dashboard session."""
        try:
            meta = json.loads(PID_PATH.read_text())
        except (OSError, ValueError):
            return
        with self.cond:
            self._reset(meta)
            self.pid = meta.get("pid")
            self._open_log()
            Z3LOG.reset()
            if self.pid and pid_alive(self.pid) and pid_is_scone(self.pid):
                self.status = "running"
            else:
                self.status = "exited"
                self.pid = None
        self.pump()
        with self.cond:
            if self.status == "exited":
                self.parser.flush()
                self.phase = self.phase if self.phase == "level done" else "ended"

    def _open_log(self):
        if self.log_file:
            self.log_file.close()
        self.parser = Parser(self)
        self.log.clear()
        try:
            self.log_file = open(LOG_PATH, "rb")
        except OSError:
            self.log_file = None

    def start(self, opts):
        args = build_args(opts)
        with self.cond:
            if self.status in ("running", "stopping"):
                raise ValueError("SCONE is already running")
            if self.external_pid:
                raise ValueError(f"another scone process (pid {self.external_pid}) is using scone.db")
            if not BIN.exists():
                raise ValueError(f"{BIN.relative_to(ROOT)} not found; run `zig build -Doptimize=ReleaseFast` first")
            if LOG_PATH.exists():
                LOG_PATH.replace(LOG_PATH.with_suffix(".log.1"))
            env = os.environ.copy()
            env.pop("SCONE_QUERY_LOG", None)
            z3_log = bool(opts.get("z3_log"))
            if z3_log:
                Z3LOG_DIR.mkdir(exist_ok=True)
                for f in Z3LOG_DIR.glob("q.*"):
                    f.unlink()
                env["SCONE_QUERY_LOG"] = str(Z3LOG_DIR / "q")
            out = open(LOG_PATH, "wb")
            self.proc = subprocess.Popen([str(BIN), *args], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=out,
                                         stderr=subprocess.STDOUT, start_new_session=True, env=env)
            out.close()
            # Baseline for the "+N this run" deltas; a wiped database starts from zero.
            base = dict.fromkeys(("classes", "expressions", "ces"), 0) if opts.get("clean") else {k: self.db.get(k) for k in ("classes", "expressions", "ces")}
            meta = {"pid": self.proc.pid, "args": args, "started": time.time(), "target": opts_cost(opts), "db_at_start": base, "z3_log": z3_log}
            Z3LOG.reset()
            PID_PATH.write_text(json.dumps(meta))
            self._reset(meta)
            self.pid = self.proc.pid
            self.status = "running"
            self._open_log()
            _row_cache.clear()
            self.touch()

    def queue(self, opts, restart):
        """Stores a run to start as soon as the current one exits; with `restart`, also stops the
        current run. Starts at once if nothing is running."""
        args = build_args(opts)  # validate now, not when the current run ends
        with self.cond:
            live = self.status in ("running", "stopping")
            if live:
                self.queued = {"opts": opts, "args": args, "restart": restart}
                self.touch()
        if not live:
            return self.start(opts)
        if restart and self.status == "running":
            self.signal("stop")

    def unqueue(self):
        with self.cond:
            self.queued = None
            self.touch()

    def signal(self, action):
        with self.cond:
            if self.status not in ("running",) or not self.pid:
                raise ValueError("SCONE is not running")
            pgid = os.getpgid(self.pid)
            if action == "pause":
                os.killpg(pgid, signal.SIGSTOP)
                self.paused = True
            elif action == "resume":
                os.killpg(pgid, signal.SIGCONT)
                self.paused = False
            elif action == "stop":
                self.stop_requested = True
                self.status = "stopping"
                if self.paused:
                    os.killpg(pgid, signal.SIGCONT)
                    self.paused = False
                os.killpg(pgid, signal.SIGINT)
                threading.Thread(target=self._reap_group, args=(pgid,), daemon=True).start()
            self.touch()

    def _reap_group(self, pgid):
        # SIGINT exits the engine at once, and its Z3 worker processes exit when orphaned; this
        # is the fallback for anything still stuck after that.
        time.sleep(5)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    # -- background work -----------------------------------------------------------------------

    def pump(self):
        """Feeds new log output to the parser. Returns True if anything was read."""
        f = self.log_file
        if not f:
            return False
        data = f.read()
        if not data:
            return False
        with self.cond:
            self.parser.feed(data)
            self.touch()
        return True

    def check_process(self):
        with self.cond:
            if self.status not in ("running", "stopping") or not self.pid:
                return
            if self.proc is not None and self.proc.pid == self.pid:
                code = self.proc.poll()
                alive = code is None
            else:
                code, alive = None, pid_alive(self.pid)
            if alive:
                return
        self.pump()  # drain the tail of the log before marking the run finished
        self.refresh_db(force=True)  # so the "finished" snapshot carries the final max_cost
        with self.cond:
            self.parser.flush()
            self.exit_code = code
            self.ended = time.time()
            self.status = "exited"
            self.paused = False
            self.proc_stats = None
            if self.stop_requested:
                self.phase = "stopped"
            elif code == 0:
                self.phase = "finished"
            else:
                self.phase = "failed"
            self.pid = None
            q = self.queued
            # A queued run follows a finished or stopped run; after a failure it waits for the user.
            if q and self.phase not in ("finished", "stopped"):
                self.last_error = "The queued run was not started because the current run failed."
                q = None
            self.touch()
        if q:
            try:
                self.start(q["opts"])
            except ValueError as e:
                with self.cond:
                    self.last_error = f"Queued run could not start: {e}"
                    self.touch()
            with self.cond:
                self.queued = None
                self.touch()

    def sample_processes(self):
        out = subprocess.run(["ps", "-A", "-o", "pgid=,pid=,%cpu=,rss=,comm="], capture_output=True, text=True).stdout
        with self.cond:
            pgid = None
            if self.pid and self.status in ("running", "stopping"):
                try:
                    pgid = os.getpgid(self.pid)
                except ProcessLookupError:
                    pass
            cpu = rss = n = 0
            external = None
            for line in out.splitlines():
                parts = line.split(None, 4)
                if len(parts) < 5:
                    continue
                g, p, c, r, comm = int(parts[0]), int(parts[1]), float(parts[2]), int(parts[3]), parts[4]
                if g == pgid:
                    cpu, rss, n = cpu + c, rss + r, n + 1
                elif comm.endswith("/scone") or comm == "scone":
                    external = p
            stats = {"cpu": round(cpu, 1), "rss": rss * 1024, "procs": n} if pgid else None
            if stats != self.proc_stats or external != self.external_pid:
                self.proc_stats, self.external_pid = stats, external
                self.touch()

    def refresh_db(self, force=False):
        """Re-queries scone.db only when it (or its WAL) changed, and at most every 3 s."""
        now = time.time()
        if not force and now - self.db_checked < 3:
            return
        self.db_checked = now
        try:
            st = DB_PATH.stat()
            wal = DB_PATH.with_name("scone.db-wal")
            wst = wal.stat().st_mtime_ns if wal.exists() else 0
            key = (st.st_ino, st.st_mtime_ns, st.st_size, wst)
        except OSError:
            key = None
        if key == self.db_key and not force:
            return
        self.db_key = key
        stats = {"exists": key is not None}
        if key is not None:
            try:
                with db_connect() as conn:
                    row = conn.execute(
                        "SELECT (SELECT value FROM meta WHERE key='max_cost'), (SELECT count(*) FROM classes),"
                        " (SELECT count(*) FROM classes WHERE status='unverified'), (SELECT count(*) FROM expressions),"
                        " (SELECT count(*) FROM counterexamples)"
                    ).fetchone()
                stats.update(max_cost=row[0], classes=row[1], unverified=row[2], expressions=row[3], ces=row[4],
                             size=st.st_size)
            except sqlite3.Error as e:
                stats["error"] = str(e)
        if stats.get("classes") is not None:
            CLASS_INDEX.ensure((stats["classes"], stats["expressions"]))
        with self.cond:
            if stats != self.db:
                self.db = stats
                self.touch()

    def refresh_status(self):
        """Reads the engine's live worker view. Only trusted when it belongs to the current run
        and was written in the last few seconds (the engine deletes it after verifying)."""
        try:
            st = STATUS_PATH.stat()
            key = (st.st_mtime_ns, st.st_size)
        except OSError:
            key = None
        if key == self.status_key:
            return
        self.status_key = key
        z = None
        if key is not None:
            try:
                z = json.loads(STATUS_PATH.read_text())
                for w in z["workers"]:
                    if w:
                        w["expr"] = pretty_expr(w["expr"])
            except (OSError, ValueError, KeyError, IndexError):
                z = None
        with self.cond:
            # The engine only rewrites the file between Z3 chunks, so while every worker sits in a
            # long query it goes quiet: keep the last view as long as the run is alive.
            if z and (z.get("pid") != self.pid or self.status not in ("running", "stopping")):
                z = None
            if z != self.z3now:
                self.z3now = z
                self.touch()

    def snapshot(self):
        return {
            "status": "paused" if self.paused else self.status,
            "pid": self.pid,
            "external_pid": self.external_pid,
            "meta": self.meta,
            "exit_code": self.exit_code,
            "ended": self.ended,
            "level": self.level,
            "phase": self.phase,
            "progress": self.progress,
            "levels": self.levels,
            "last_error": self.last_error,
            "proc": self.proc_stats,
            "z3now": self.z3now,
            "db": self.db,
            "queued": self.queued and {"args": self.queued["args"], "restart": self.queued["restart"]},
            "now": time.time(),
        }


def opts_cost(opts):
    return int(opts.get("cost") or 3)


def build_args(opts):
    """Turns the start form into engine arguments. Everything is validated; nothing reaches a shell."""
    def int_opt(key, lo, hi):
        v = opts.get(key)
        if v in (None, ""):
            return None
        v = int(v)
        if not lo <= v <= hi:
            raise ValueError(f"{key} must be between {lo} and {hi}")
        return v

    def list_opt(key, valid):
        v = str(opts.get(key) or "").replace(" ", "")
        if not v:
            return None
        bad = [x for x in v.split(",") if x not in valid]
        if bad:
            raise ValueError(f"unknown {key}: {', '.join(bad)}")
        return v

    args = ["-c", str(int_opt("cost", 1, 12) or 3)]
    if (t := int_opt("threads", 0, 1024)) is not None:
        args += ["-t", str(t)]
    if (t := int_opt("z3_timeout", 1, 3_600_000)) is not None:
        args += ["--z3-timeout", str(t)]
    if (t := int_opt("audit_normalize", 0, 1_000_000)) is not None and t > 0:
        args += ["--audit-normalize", str(t)]
    for key, flag in [("lite", "--lite"), ("no_select", "--no-select"), ("no_unary", "--no-unary"),
                      ("no_absint", "--no-absint"), ("distill_ces", "--distill-ces"), ("clean", "--clean")]:
        if opts.get(key):
            args.append(flag)
    if v := list_opt("binops", BINOPS):
        args += ["--binops", v]
    if v := list_opt("unops", UNOPS):
        args += ["--unops", v]
    consts = str(opts.get("consts") or "").replace(" ", "")
    if consts:
        if not re.fullmatch(r"(0x[0-9a-fA-F]+|\d+)(,(0x[0-9a-fA-F]+|\d+))*", consts):
            raise ValueError("consts must be a comma-separated list of numbers")
        args += ["--consts", consts]
    return args


class Z3Log:
    """Incremental summary of the engine's Z3 query logs (one file per worker process, one line
    per query: microseconds, result, member count, base, members). Only new bytes are read."""

    TOP = 40

    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        with getattr(self, "lock", threading.Lock()):
            self.offsets = {}
            self.partial = {}
            self.n = 0
            self.by_result = collections.defaultdict(lambda: [0, 0])  # result -> [queries, us]
            self.by_base = collections.defaultdict(lambda: [0, 0])
            self.families = {}  # (result, shape) -> [members, us, examples [(base, member, us)], histogram]
            self.slowest = []  # min-heap of (us, seq, result, n, base, member)
            self.recent = collections.deque(maxlen=60)
            self.seq = 0
            self.files = 0

    @staticmethod
    def shape(e):
        return re.sub(r"\b[xyz]\b", "v", re.sub(r"\b\d+\b", "K", e))

    def update(self):
        import heapq
        try:
            paths = sorted(Z3LOG_DIR.glob("q.*"))
        except OSError:
            return
        with self.lock:
            self.files = len(paths)
            for path in paths:
                key = str(path)
                try:
                    with open(path, "rb") as f:
                        f.seek(self.offsets.get(key, 0))
                        data = f.read(1 << 20)  # small slices: the rest is read on the next pass
                        self.offsets[key] = f.tell()
                except OSError:
                    continue
                text = self.partial.pop(key, "") + data.decode("utf-8", "replace")
                lines = text.split("\n")
                self.partial[key] = lines.pop()
                for line in lines:
                    p = line.split("\t")
                    if len(p) < 5:
                        continue
                    try:
                        us = int(p[0])
                    except ValueError:
                        continue
                    res, base, members = p[1], p[3], p[4:]
                    self.n += 1
                    self.seq += 1
                    r = self.by_result[res]
                    r[0] += 1
                    r[1] += us
                    b = self.by_base[base]
                    b[0] += 1
                    b[1] += us
                    share = us / len(members)
                    for m in members:
                        k = (res, self.shape(base) + "\t" + self.shape(m))
                        fam = self.families.get(k)
                        if fam is None:
                            if len(self.families) >= 200_000:  # bound memory on huge logs
                                continue
                            fam = self.families[k] = [0, 0.0, [], [0] * 12]
                        fam[0] += 1
                        fam[1] += share
                        if len(fam[2]) < 6 and all(e[1] != m for e in fam[2]):
                            fam[2].append((base, m, share))
                        # bins: <1ms, <2ms, <4ms ... doubling, last bin open-ended
                        fam[3][min(11, max(0, int(share).bit_length() - 9))] += 1
                    item = (us, self.seq, res, len(members), base, members[0])
                    if len(self.slowest) < self.TOP:
                        heapq.heappush(self.slowest, item)
                    elif us > self.slowest[0][0]:
                        heapq.heapreplace(self.slowest, item)
                    self.recent.append((us, res, len(members), base, members[0]))

    def summary(self):
        with self.lock:
            fams = sorted(self.families.items(), key=lambda kv: -kv[1][1])[: self.TOP]
            bases = sorted(self.by_base.items(), key=lambda kv: -kv[1][1])[:12]
            return {
                "files": self.files,
                "queries": self.n,
                "by_result": {k: {"queries": v[0], "us": v[1]} for k, v in self.by_result.items()},
                "families": [{"result": k[0], "count": v[0], "us": round(v[1]), "base": pretty_expr(v[2][0][0]), "member": pretty_expr(v[2][0][1]),
                              "examples": [{"base": pretty_expr(b), "member": pretty_expr(m), "us": round(u)} for b, m, u in v[2]], "hist": v[3]} for k, v in fams],
                "bases": [{"base": pretty_expr(b), "queries": v[0], "us": v[1]} for b, v in bases],
                "slowest": [{"us": t[0], "result": t[2], "n": t[3], "base": pretty_expr(t[4]), "member": pretty_expr(t[5])} for t in sorted(self.slowest, reverse=True)],
                "recent": [{"us": t[0], "result": t[1], "n": t[2], "base": pretty_expr(t[3]), "member": pretty_expr(t[4])} for t in reversed(self.recent)],
            }


RUN = Run()
Z3LOG = Z3Log()


def z3log_loop():
    """Reads the Z3 query logs on its own thread, so catching up on a large log (after a restart)
    never delays the live progress updates."""
    while True:
        if RUN.meta.get("z3_log"):
            Z3LOG.update()
        time.sleep(1)


def background_loop():
    last_slow = 0.0
    while True:
        RUN.pump()
        RUN.refresh_status()
        now = time.time()
        if now - last_slow >= 2:
            last_slow = now
            RUN.check_process()
            RUN.sample_processes()
            RUN.refresh_db()
        time.sleep(0.25)


# ----------------------------------------------------------------------------------------------
# Database browsing
# ----------------------------------------------------------------------------------------------

def db_connect():
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    conn.execute("PRAGMA query_only=1")
    return conn


_row_cache = {}  # expr id -> (tag, op, c1, c2, c3); expression rows are immutable within a run


def load_rows(conn, ids):
    """Loads expressions and their whole subtrees, one batched query per tree depth."""
    todo = {i for i in ids if i not in _row_cache}
    while todo:
        if len(_row_cache) > 500_000:
            _row_cache.clear()
        ids_list = list(todo)
        todo = set()
        for k in range(0, len(ids_list), 900):
            chunk = ids_list[k:k + 900]
            q = f"SELECT id, tag, op, c1, c2, c3 FROM expressions WHERE id IN ({','.join('?' * len(chunk))})"
            for eid, tag, op, c1, c2, c3 in conn.execute(q, chunk):
                # `op` has TEXT affinity, so the engine's integers come back as strings.
                _row_cache[eid] = (tag, int(op or 0), c1, c2, c3)
                kids = (c1,) if tag == "unary" else (c1, c2) if tag == "binary" else (c1, c2, c3) if tag == "select" else ()
                todo.update(c for c in kids if c is not None and c not in _row_cache)


def fmt_const(v):
    v &= 0xFFFFFFFF
    return str(v) if v <= 64 else hex(v)


def render(eid, top=True):
    """Returns (text, cost) for an expression whose rows are cached."""
    row = _row_cache.get(eid)
    if row is None:
        return f"#{eid}?", 0
    tag, op, c1, c2, c3 = row
    if tag == "variable":
        return VARS[op] if 0 <= op < len(VARS) else f"v{op}", 0
    if tag == "constant":
        return fmt_const(op), 0
    if tag == "unary":
        a, ca = render(c1, False)
        name = UNOPS[op] if 0 <= op < len(UNOPS) else f"un{op}"
        txt = f"-{a}" if name == "neg" else f"~{a}" if name == "not" else f"{name}({a})"
        return txt, ca + 1
    if tag == "binary":
        a, ca = render(c1, False)
        b, cb = render(c2, False)
        sym = BIN_SYM[op] if 0 <= op < len(BIN_SYM) else f"op{op}"
        txt = f"{a} {sym} {b}"
        return (txt if top else f"({txt})"), ca + cb + 1
    if tag == "select":
        a, ca = render(c1, False)
        b, cb = render(c2, False)
        c, cc = render(c3, False)
        txt = f"{a} ? {b} : {c}"
        return (txt if top else f"({txt})"), ca + cb + cc + 1
    return f"?{tag}", 0


RE_TOK = re.compile(r"\s*([A-Za-z_]+|\d+|[(),])")


def pretty_expr(text):
    """Re-renders the engine's format_expr output ("((x add y) mul 3)") in the dashboard's style."""
    toks = RE_TOK.findall(text)
    pos = 0

    def take():
        nonlocal pos
        pos += 1
        return toks[pos - 1]

    def expr(top):
        t = take()
        if t == "(":
            a = expr(False)
            op = take()
            b = expr(False)
            take()  # ")"
            txt = f"{a} {BIN_SYM[BINOPS.index(op)] if op in BINOPS else op} {b}"
            return txt if top else f"({txt})"
        if t == "select":
            take()
            c = expr(False)
            take()
            a = expr(False)
            take()
            b = expr(False)
            take()
            txt = f"{c} ? {a} : {b}"
            return txt if top else f"({txt})"
        if t in UNOPS:
            take()
            a = expr(t not in ("neg", "not"))  # a call's own parentheses already group it
            take()
            return f"-{a}" if t == "neg" else f"~{a}" if t == "not" else f"{t}({a})"
        return fmt_const(int(t)) if t.isdigit() else t

    try:
        return expr(True)
    except (IndexError, ValueError):
        return text


class ClassIndex:
    """Per-class facts scone.db does not store (member lists, sizes, costs, the cheapest rewrite),
    rebuilt in the background whenever the number of classes or expressions changes. Expression ids
    are assigned bottom-up, so one ordered pass computes every cost."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ready = threading.Event()
        self.key = None      # (classes, expressions) of the built index
        self.wanted = None
        self.building = False
        self.d = None
        self.orders = {}

    def ensure(self, key):
        with self.lock:
            if key in (self.key, self.wanted) or self.building:
                self.wanted = key
                return
            self.wanted, self.building = key, True
        threading.Thread(target=self._build, args=(key,), daemon=True).start()

    def _build(self, key):
        try:
            d = self._load()
            with self.lock:
                self.d, self.key, self.orders = d, key, {}
            self.ready.set()
        except sqlite3.Error:
            with self.lock:
                self.wanted = None  # let the next refresh retry
        finally:
            with self.lock:
                self.building = False
                again = self.wanted != self.key and self.wanted is not None
            if again:
                self.ensure(self.wanted)

    @staticmethod
    def _load():
        from array import array
        with db_connect() as conn:
            max_e = conn.execute("SELECT coalesce(max(id), 0) FROM expressions").fetchone()[0]
            max_c = conn.execute("SELECT coalesce(max(id), 0) FROM classes").fetchone()[0]
            cost = bytearray(max_e + 1)
            owner = array("I", bytes(4 * (max_e + 1)))
            for eid, cid, tag, c1, c2, c3 in conn.execute("SELECT id, class_id, tag, c1, c2, c3 FROM expressions ORDER BY id"):
                if tag == "binary":
                    c = cost[c1] + cost[c2] + 1
                elif tag == "unary":
                    c = cost[c1] + 1
                elif tag == "select":
                    c = cost[c1] + cost[c2] + cost[c3] + 1
                else:
                    c = 0
                cost[eid] = c if c < 255 else 255
                owner[eid] = cid or 0
            canon = array("I", bytes(4 * (max_c + 1)))
            unverified = set()
            ids = array("I")
            for cid, ce, st in conn.execute("SELECT id, canonical_expr_id, status FROM classes ORDER BY id"):
                ids.append(cid)
                canon[cid] = ce or 0
                if st == "unverified":
                    unverified.add(cid)
        size = array("I", bytes(4 * (max_c + 1)))
        best = array("I", bytes(4 * (max_c + 1)))   # cheapest non-canonical member
        worst = bytearray(max_c + 1)                 # most expensive member's cost
        for eid in range(1, max_e + 1):
            c = owner[eid]
            if not c or c > max_c:
                continue
            size[c] += 1
            if eid != canon[c]:
                b = best[c]
                if not b or cost[eid] < cost[b]:
                    best[c] = eid
                if cost[eid] > worst[c]:
                    worst[c] = cost[eid]
        # members of class c are members[start[c]:start[c+1]], cheapest first
        start = array("I", bytes(4 * (max_c + 2)))
        for c in range(1, max_c + 1):
            start[c + 1] = start[c] + size[c]
        fill = array("I", start)
        members = array("I", bytes(4 * start[max_c + 1]))
        for eid in range(1, max_e + 1):
            c = owner[eid]
            if c and c <= max_c:
                members[fill[c]] = eid
                fill[c] += 1
        ccost = bytearray(max_c + 1)
        for c in ids:
            ccost[c] = cost[canon[c]]
        facets = collections.Counter(ccost[c] for c in ids)
        with_rules = sum(1 for c in ids if size[c] > 1)
        return {"cost": cost, "canon": canon, "ids": ids, "unverified": unverified, "size": size, "best": best,
                "worst": worst, "start": start, "members": members, "ccost": ccost,
                "facets": {"costs": {str(k): v for k, v in sorted(facets.items())}, "classes": len(ids),
                           "with_rules": with_rules, "rules": sum(size[c] for c in ids) - len(ids),
                           "unverified": len(unverified)}}

    def get(self, wait=0.0):
        if self.d is None and wait:
            self.ready.wait(wait)
        return self.d

    def order(self, d, kind, cost, order):
        """Class ids for a filter and order, cached until the next rebuild."""
        k = (kind, cost, order)
        with self.lock:
            hit = self.orders.get(k) if d is self.d else None
        if hit is not None:
            return hit
        size, ccost, worst = d["size"], d["ccost"], d["worst"]
        ids = d["ids"]
        if kind == "rules":
            ids = [c for c in ids if size[c] > 1]
        elif kind == "unverified":
            ids = [c for c in ids if c in d["unverified"]]
        if cost != "":
            want = int(cost)
            ids = [c for c in ids if ccost[c] == want]
        if order == "asc":
            out = list(ids)
        elif order == "size":
            out = sorted(ids, key=lambda c: (-size[c], -c))
        elif order == "savings":
            out = sorted((c for c in ids if size[c] > 1), key=lambda c: (ccost[c] - worst[c], -size[c], -c))
        else:
            out = list(reversed(ids))
        with self.lock:
            if d is self.d:
                if len(self.orders) > 24:
                    self.orders.clear()
                self.orders[k] = out
        return out


CLASS_INDEX = ClassIndex()


def class_row(d, cid):
    eid = d["canon"][cid]
    txt, cost = render(eid)
    b = d["best"][cid]
    row = {"id": cid, "canonical": txt, "cost": cost, "status": "unverified" if cid in d["unverified"] else "verified",
           "size": d["size"][cid]}
    if b:
        btxt, bcost = render(b)
        row.update(best=btxt, best_cost=bcost, max_cost=d["worst"][cid])
    return row


def api_classes(q):
    page = max(1, int(q.get("page", ["1"])[0]))
    size = min(200, max(10, int(q.get("size", ["50"])[0])))
    kind = q.get("filter", ["all"])[0]
    cost = q.get("cost", [""])[0]
    cost = cost if cost.isdigit() else ""
    order = q.get("order", ["desc"])[0]
    jump = q.get("id", [""])[0]
    text = "".join(q.get("q", [""])[0].split())
    d = CLASS_INDEX.get(wait=15)
    if d is None:
        return {"error": "Still indexing scone.db, try again in a moment"}
    if jump:
        cid = int(jump)
        ids = [cid] if 0 < cid < len(d["canon"]) and d["canon"][cid] else []
    else:
        ids = CLASS_INDEX.order(d, kind, cost, order)
    base = {"page": page, "size": size, "facets": d["facets"]}
    if text:
        return {**base, **search_classes(d, ids, text, page, size)}
    chosen = ids[(page - 1) * size: page * size]
    with db_connect() as conn:
        load_rows(conn, [x for c in chosen for x in (d["canon"][c], d["best"][c]) if x])
    return {**base, "total": len(ids), "rows": [class_row(d, c) for c in chosen]}


def search_classes(d, ids, text, page, size, budget_s=1.5):
    """Substring search over the canonical form and the cheapest rewrite (spaces ignored), scanning
    the filtered, ordered ids until there are enough hits for this page or the time budget runs out."""
    want = page * size
    hits, scanned, deadline = [], 0, time.time() + budget_s
    canon, best = d["canon"], d["best"]
    with db_connect() as conn:
        while len(hits) < want and scanned < len(ids) and time.time() < deadline:
            chunk = ids[scanned: scanned + 2000]
            scanned += len(chunk)
            load_rows(conn, [x for c in chunk for x in (canon[c], best[c]) if x])
            for c in chunk:
                if text in render(canon[c])[0].replace(" ", "") or (best[c] and text in render(best[c])[0].replace(" ", "")):
                    hits.append(c)
            if len(_row_cache) > 400_000:
                _row_cache.clear()
        chosen = hits[(page - 1) * size: page * size]
        load_rows(conn, [x for c in chosen for x in (canon[c], best[c]) if x])
    done = scanned >= len(ids)
    return {"total": len(hits) if done else None, "rows": [class_row(d, c) for c in chosen], "searched": True,
            "scanned": scanned, "classes": len(ids), "complete": done, "more": len(hits) >= want and not done}


def api_class(q):
    cid = int(q["id"][0])
    limit = min(5000, max(50, int(q.get("limit", ["300"])[0])))
    d = CLASS_INDEX.get(wait=15)
    if d is None or not (0 < cid < len(d["canon"])) or not d["canon"][cid]:
        return {"error": "no such class" if d is not None else "Still indexing scone.db"}
    ce, cost = d["canon"][cid], d["cost"]
    members = [m for m in d["members"][d["start"][cid]: d["start"][cid + 1]] if m != ce]
    members.sort(key=lambda m: (cost[m], m))
    shown = members[:limit]
    with db_connect() as conn:
        load_rows(conn, [ce, *shown])
    canon, ccost = render(ce)
    rendered = sorted((render(m) + (m,) for m in shown), key=lambda r: (r[1], len(r[0])))
    by_cost = collections.Counter(cost[m] for m in members)
    return {"id": cid, "status": "unverified" if cid in d["unverified"] else "verified", "canonical": canon, "cost": ccost,
            "count": len(members) + 1, "by_cost": {str(k): v for k, v in sorted(by_cost.items())},
            "members": [{"id": m, "expr": t, "cost": c} for t, c, m in rendered]}


def api_recent_rules(q):
    """The newest non-canonical expressions, each shown as a rewrite to its class's canonical form."""
    n = min(50, max(1, int(q.get("n", ["8"])[0])))
    with db_connect() as conn:
        rows = conn.execute("SELECT e.id, c.id, c.canonical_expr_id, c.status FROM expressions e JOIN classes c ON c.id = e.class_id "
                            "WHERE e.id != c.canonical_expr_id ORDER BY e.id DESC LIMIT ?", (n,)).fetchall()
        load_rows(conn, [x for r in rows for x in (r[0], r[2])])
    out = []
    for eid, cid, canon, status in rows:
        (txt, cost), (ctxt, ccost) = render(eid), render(canon)
        out.append({"id": cid, "expr": txt, "cost": cost, "canonical": ctxt, "ccost": ccost, "status": status})
    return {"rows": out}


# ----------------------------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        try:
            if url.path == "/":
                self.send(200, page(), "text/html; charset=utf-8")
            elif url.path == "/api/events":
                self.events()
            elif url.path == "/api/classes":
                self.send(200, api_classes(q))
            elif url.path == "/api/recent_rules":
                self.send(200, api_recent_rules(q))
            elif url.path == "/api/class":
                self.send(200, api_class(q))
            elif url.path == "/api/z3log":
                self.send(200, {"enabled": bool(RUN.meta.get("z3_log")), **Z3LOG.summary()})
            elif url.path.startswith("/assets/") and (f := static_file(url.path)):
                self.send(200, f[0], f[1])
            else:
                self.send(404, {"error": "not found"})
        except (sqlite3.Error, ValueError, KeyError) as e:
            self.send(400, {"error": str(e)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            self.send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_POST(self):
        # Only same-origin JSON requests may control the engine: a cross-site form cannot send
        # application/json without a preflight, and the Origin check covers the rest.
        origin = self.headers.get("Origin", "")
        host = self.headers.get("Host", "")
        if self.headers.get("Content-Type", "").split(";")[0] != "application/json" or (origin and urlparse(origin).netloc != host):
            return self.send(403, {"error": "forbidden"})
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            opts = json.loads(body or b"{}")
            action = urlparse(self.path).path.removeprefix("/api/")
            if action == "start":
                RUN.start(opts)
            elif action in ("queue", "restart"):
                RUN.queue(opts, action == "restart")
            elif action == "unqueue":
                RUN.unqueue()
            elif action == "client_error":
                # The page reports its uncaught errors so a frozen view leaves a trace here.
                print(time.strftime("%H:%M:%S"), "UI error:", str(opts.get("message", ""))[:500], "|",
                      str(opts.get("where", ""))[:200], "|", str(opts.get("stack", ""))[:1500].replace("\n", " <- "),
                      file=sys.stderr, flush=True)
            elif action in ("stop", "pause", "resume"):
                if action == "stop":
                    RUN.unqueue()  # an explicit stop means stop everything
                RUN.signal(action)
            else:
                return self.send(404, {"error": "not found"})
            self.send(200, {"ok": True})
        except (ValueError, OSError) as e:
            self.send(400, {"error": str(e)})

    def events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        seen_version, seen_log, seen_rate = -1, 0, 0
        try:
            while True:
                with RUN.cond:
                    RUN.cond.wait_for(lambda: RUN.version != seen_version, timeout=15)
                    if RUN.version == seen_version:
                        # a real event (not an SSE comment), so the page can tell a quiet server
                        # from a dead connection
                        msg = b"event: ping\ndata: {}\n\n"
                    else:
                        seen_version = RUN.version
                        state = RUN.snapshot()
                        if RUN.log and RUN.log[0][0] > seen_log + 1:
                            state["log_reset"] = True
                        state["log"] = [t for s, t in RUN.log if s > seen_log]
                        state["rates"] = [[t, p, lv, r] for s, t, p, lv, r in RUN.rates if s > seen_rate]
                        if RUN.log:
                            seen_log = RUN.log[-1][0]
                        if RUN.rates:
                            seen_rate = RUN.rates[-1][0]
                        msg = b"data: " + json.dumps(state, separators=(",", ":")).encode() + b"\n\n"
                self.wfile.write(msg)
                self.wfile.flush()
                time.sleep(0.25)  # coalesce bursts into at most 4 messages per second
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


# ----------------------------------------------------------------------------------------------
# Page
# ----------------------------------------------------------------------------------------------

UI_DIST = ROOT / "dashboard-ui" / "dist"  # Svelte UI (`npm run build` in dashboard-ui/)
STATIC_TYPES = {".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".map": "application/json"}


def page():
    """The UI, read on every request so a rebuild shows up on refresh."""
    try:
        return (UI_DIST / "index.html").read_bytes()
    except OSError:
        return (b"<!doctype html><title>SCONE</title><p>The dashboard UI is not built yet: run "
                b"<code>npm install && npm run build</code> in <code>dashboard-ui/</code>.</p>")


def static_file(url_path):
    """A built asset under dashboard-ui/dist, or None. Paths cannot escape that folder."""
    target = (UI_DIST / url_path.lstrip("/")).resolve()
    if UI_DIST.resolve() not in target.parents or not target.is_file():
        return None
    return target.read_bytes(), STATIC_TYPES.get(target.suffix, "application/octet-stream")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass  # browsers drop keep-alive and event-stream connections all the time


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1", help="interface to bind (default: localhost only)")
    args = ap.parse_args()
    RUN.attach_existing()
    RUN.refresh_db(force=True)
    threading.Thread(target=background_loop, daemon=True).start()
    threading.Thread(target=z3log_loop, daemon=True).start()
    server = Server((args.host, args.port), Handler)
    print(f"SCONE dashboard on http://{args.host}:{args.port}  (engine keeps running if you close this)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
