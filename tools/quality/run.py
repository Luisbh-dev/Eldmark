#!/usr/bin/env python
"""Quality capture bench (TEC-50): one command per area.

    python tools/quality/run.py <area> [--out folder] [--port 24711] [options]

Areas: animacion, mapa, interfaz, mundo, combate, video, todo (all six), indice (only regenerates indice.md) and listar.
Each area launches what it needs (the sandbox, or a Vado Gris dedicated server, bots and the `online_driver.gd`
capture client), saves the captures in the output folder (by default build/calidad, which Git ignores), joins the
strips into grids and regenerates <output>/indice.md. When it finishes, or if interrupted, it closes all the Godot processes
it launched (and only those). It needs a window and a GPU (it does not work in headless), Pillow (`pip install pillow`) and uses no accounts
or passwords: the server runs with --debug-commands and the client joins with an ephemeral character.

Main options:
  --out <folder>        output folder (by default build/calidad)
  --port <port>         UDP port of the server that is launched (by default 24711, or ELDMARK_QUALITY_PORT)
  --resolution WxH      capture resolution (by default 1920x1080)
  --steps a,b           only some steps of the area (see `listar`)
  --only a,b            animacion: only the actions with those ids (see `listar`)
  --phases a,b          combate (npc step): only those phases: hueco, capitan, guardia, guardian
  --bots N              siege bots per realm in mapa, interfaz and brawls (by default 6; in mundo, 0)
  --seconds N           video: duration of the script (by default 60)
  --movie-resolution    video: window size when recording (by default 1600x900, the one the engine uses for video)
  --mp4                 video: additionally converts the AVI to MP4 with ffmpeg if available
  --sin-capsulas        mundo: the review cameras without the scale capsules
  --clean-raw           deletes the loose frames in raw/ when done (keeps the meta.json files the index uses)
  --godot <path>        Godot executable (or GODOT in the environment; otherwise the winget one or `godot` on the PATH)
"""
import argparse
import atexit
import contextlib
import datetime
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import make_index  # noqa: E402  (no necesita Pillow; compose_strips y crops sí, y se cargan al usarlos)

AREAS = ("animacion", "mapa", "interfaz", "mundo", "combate", "video")
STEPS = {
    "animacion": ("jugador", "pnj"),
    "mapa": ("mapa",),
    "interfaz": ("hud", "marcador", "reino", "titulo", "galeria", "chat"),
    "mundo": ("vardheim", "solmarch", "camaras", "demo"),
    "combate": ("refriegas", "refriegas_b", "bot", "bloqueo", "pnj"),
    "video": ("video",),
}
DRIVER = "res://tools/quality/online_driver.gd"
SCENARIO = "res://tools/quality/%s"
DEFAULT_PORT = 24711

_STARTED = []
_FAILED = []


# ---------------------------------------------------------------------------------------------
# Godot and processes
# ---------------------------------------------------------------------------------------------
def find_godot(explicit=None):
    for cand in (explicit, os.environ.get("GODOT"), os.environ.get("GODOT_BIN")):
        if cand and Path(cand).exists():
            return str(cand)
    local = os.environ.get("LOCALAPPDATA")
    if local:
        found = sorted(glob.glob(os.path.join(local, "Microsoft", "WinGet", "Packages", "GodotEngine.GodotEngine_*",
                                              "Godot_v4*_console.exe")))
        if found:
            return found[-1]
    for name in ("godot", "godot4", "Godot"):
        path = shutil.which(name)
        if path:
            return path
    sys.exit("No encuentro Godot: pasa --godot <ruta> o define GODOT con el ejecutable (en Windows, el de consola).")


def kill_tree(proc):
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass


def _cleanup():
    for proc in list(_STARTED):
        kill_tree(proc)


atexit.register(_cleanup)


class Ctx:
    """What the steps share: output folder, port, Godot and options."""

    def __init__(self, args):
        self.args = args
        self.out = Path(args.out).resolve()
        self.raw = self.out / "raw"
        self.logs = self.out / "logs"
        self.port = args.port
        self.godot = find_godot(args.godot)
        self.res = args.resolution
        self.steps = [s for s in (args.steps or "").split(",") if s]
        for folder in (self.out, self.raw, self.logs, self.out / "indices"):
            folder.mkdir(parents=True, exist_ok=True)

    def want(self, step):
        return not self.steps or step in self.steps

    def posix(self, path):
        return Path(path).as_posix()


def spawn(ctx, name, args, cwd=ROOT):
    log_path = ctx.logs / ("%s.log" % name)
    log = open(log_path, "wb")
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    # Never capture the user's mouse: the bench clients always start with the cursor free.
    env = dict(os.environ)
    env["ELDMARK_SIN_RATON"] = "1"
    proc = subprocess.Popen([ctx.godot] + [str(a) for a in args], cwd=str(cwd), stdout=log, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, env=env, **kwargs)
    proc.log_path = log_path
    proc.log_handle = log
    proc.proc_name = name
    _STARTED.append(proc)
    return proc


def release(proc):
    kill_tree(proc)
    try:
        proc.log_handle.close()
    except OSError:
        pass
    if proc in _STARTED:
        _STARTED.remove(proc)


def read_log(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def wait_log(proc, needle, timeout, count=1):
    """Waits for the log of [proc] to contain [count] occurrences of [needle]. False if the deadline passes or the process dies."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if read_log(proc.log_path).count(needle) >= count:
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------------------------
# Server, bots and capture client
# ---------------------------------------------------------------------------------------------
# Believable names for the bench bots, one list per realm (northern for Vardheim, southern for Solmarch), so that the
# captures do not give the bench away with "Botaaab". Valid for NameRules, none reserved.
BOT_NAMES = {
    "vardheim": ("Hakon", "Brenna", "Torvald", "Sigrid", "Ulfar", "Ragna", "Leif", "Astrid", "Bjorn", "Freya",
                 "Gunnar", "Ingrid", "Halvard", "Solveig", "Eirik", "Thora", "Arvid", "Runa", "Orm", "Yrsa"),
    "solmarch": ("Rodrigo", "Lucía", "Mateo", "Inés", "Alonso", "Beatriz", "Tomás", "Elena", "Gonzalo", "Marcela",
                 "Íñigo", "Catalina", "Bastián", "Valeria", "Ramiro", "Olalla", "Dario", "Ximena", "Nuño", "Aurelia"),
}


def swarms(ctx, per_realm):
    """Two siege swarms (one per realm) with [per_realm] bots each."""
    if per_realm <= 0:
        return []
    return [
        {"kind": "swarm", "n": per_realm, "realm": "vardheim", "seed": 100, "brain": "siege"},
        {"kind": "swarm", "n": per_realm, "realm": "solmarch", "seed": 200, "brain": "siege"},
    ]


def bot_names_arg(realm, count):
    """The --bot-names argument with [count] names of the realm's list (without repeating them)."""
    return "--bot-names=%s" % ",".join(BOT_NAMES.get(realm, ())[:count])


def single_bot(realm="solmarch", brain="combat", seed=300, name="Esgrimista"):
    """A single full bot (uses the whole kit: abilities, block, dodge, bow)."""
    return [{"kind": "bot", "n": 1, "realm": realm, "seed": seed, "brain": brain, "name": name}]


@contextlib.contextmanager
def server(ctx, name, extra=(), bots=()):
    stop_file = ctx.logs / ("%s.stop" % name)
    if stop_file.exists():
        stop_file.unlink()
    args = ["--headless", "--path", ROOT, "--", "--server", "--zone=vado_gris", "--port=%d" % ctx.port,
            "--debug-commands", "--max-per-ip=64", "--stop-file=%s" % ctx.posix(stop_file), *extra]
    print("[banco] servidor %s en el puerto %d %s" % (name, ctx.port, " ".join(extra)))
    proc = spawn(ctx, "servidor_" + name, args)
    helpers = []
    try:
        if not wait_log(proc, "escuchando en el puerto UDP", 240):
            raise RuntimeError("el servidor no arrancó (mira %s)" % proc.log_path)
        expected = 0
        for i, bot in enumerate(bots):
            bargs = ["--headless", "--path", ROOT, "--"]
            if bot["kind"] == "swarm":
                bargs += ["--bots=%d" % bot["n"], bot_names_arg(bot["realm"], bot["n"])]
            else:
                bargs += ["--bot", "--name=%s" % bot.get("name", "Esgrimista")]
            bargs += ["--connect=127.0.0.1:%d" % ctx.port, "--realm=%s" % bot["realm"],
                      "--bot-brain=%s" % bot["brain"], "--bot-seed=%d" % bot["seed"]]
            helpers.append(spawn(ctx, "bots_%s_%d" % (name, i), bargs))
            expected += bot["n"]
        if expected and not wait_log(proc, "Alta de ", 180, count=expected + 0):
            print("[banco] aviso: no entraron todos los bots (%d esperados)" % expected)
        if expected:
            time.sleep(4.0)
        yield proc
    finally:
        for helper in helpers:
            release(helper)
        try:
            stop_file.write_text("1")
            proc.wait(timeout=25)
        except (subprocess.TimeoutExpired, OSError):
            pass
        release(proc)


def run_godot(ctx, name, args, timeout=1800, ok_text=None):
    """Launches Godot (with a window unless [args] says otherwise), waits for it to finish and returns True if it exited successfully."""
    proc = spawn(ctx, name, args)
    start = time.monotonic()
    ok = False
    try:
        proc.wait(timeout=timeout)
        text = read_log(proc.log_path)
        ok = proc.returncode == 0 and (ok_text is None or ok_text in text)
    except subprocess.TimeoutExpired:
        print("[banco] %s: pasó el plazo (%d s), se cierra" % (name, timeout))
    finally:
        release(proc)
    print("[banco] %s: %s en %d s (registro: %s)" % (name, "bien" if ok else "FALLÓ", time.monotonic() - start, proc.log_path))
    if not ok:
        _FAILED.append(name)
    return ok


def driver(ctx, scenario, tag, realm="vardheim", name="Capturador", connect=True, extra=(), godot_args=(),
           timeout=1500, resolution=None):
    """A run of online_driver.gd with the scenario [scenario] (a file in tools/quality)."""
    args = ["--path", ROOT, "--resolution", resolution or ctx.res, *godot_args, "-s", DRIVER, "--"]
    if connect:
        args.append("--connect=127.0.0.1:%d" % ctx.port)
    if realm:
        args.append("--realm=%s" % realm)
    if name:
        args.append("--name=%s" % name)
    args += ["--scenario=" + SCENARIO % scenario, "--out=%s" % ctx.posix(ctx.out), "--tag=%s" % tag,
             "--raw=%s" % ctx.posix(ctx.raw), *extra]
    return run_godot(ctx, "cliente_" + tag, args, timeout=timeout, ok_text="[driver] terminado")


def compose_all(*args, **kwargs):
    try:
        import compose_strips
    except ImportError as err:
        sys.exit("Falta Pillow para juntar las tiras (pip install pillow): %s" % err)
    return compose_strips.compose_all(*args, **kwargs)


def make_crops(*args, **kwargs):
    try:
        import crops
    except ImportError as err:
        sys.exit("Falta Pillow para los recortes (pip install pillow): %s" % err)
    return crops.make_crops(*args, **kwargs)


# ---------------------------------------------------------------------------------------------
# Areas
# ---------------------------------------------------------------------------------------------
def area_animacion(ctx):
    only = ["--only=%s" % ctx.args.only] if ctx.args.only else []
    for step, set_name in (("jugador", "player"), ("pnj", "npc")):
        if not ctx.want(step):
            continue
        args = ["--path", ROOT, "--resolution", ctx.res, "--fixed-fps", "30", "-s", "res://tools/quality/anim_strips.gd",
                "--", "--raw=%s" % ctx.posix(ctx.raw), "--set=%s" % set_name, *only]
        run_godot(ctx, "tiras_" + step, args, timeout=3600, ok_text="[strips] terminado")
    compose_only = set(ctx.args.only.split(",")) if ctx.args.only else None
    compose_all(str(ctx.raw), str(ctx.out), only=compose_only)


def area_mapa(ctx):
    with server(ctx, "mapa", bots=swarms(ctx, ctx.bots(6))):
        driver(ctx, "sc_mapa.gd", "mapa")
    maps = ROOT / "assets" / "maps" / "vado_gris.png"
    if maps.exists():
        (ctx.out / "mapa").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(maps, ctx.out / "mapa" / "imagen_horneada_vado_gris.png")


def area_interfaz(ctx):
    online = [s for s in ("hud", "marcador", "reino") if ctx.want(s)]
    if online:
        with server(ctx, "interfaz", bots=swarms(ctx, ctx.bots(6))):
            if ctx.want("hud"):
                driver(ctx, "sc_interfaz.gd", "interfaz")
            if ctx.want("marcador"):
                driver(ctx, "sc_extras.gd", "extras", name="Marcador")
            if ctx.want("reino"):
                # Without --realm: the client shows the realm selection screen.
                driver(ctx, "sc_realm.gd", "realm", realm=None, name="Elector")
    if ctx.want("titulo"):
        driver(ctx, "sc_front.gd", "front", realm=None, name=None, connect=False, extra=["--front"], timeout=300)
    if ctx.want("galeria"):
        driver(ctx, "sc_gallery.gd", "galeria", realm=None, name=None, connect=False,
               extra=["--scene=res://scenes/tests/ui_gallery.tscn"], timeout=300)
    if ctx.want("chat"):
        folder = ctx.out / "interfaz" / "chat_preview"
        folder.mkdir(parents=True, exist_ok=True)
        run_godot(ctx, "chat_preview", ["--path", ROOT, "--resolution", ctx.res, "res://scenes/tests/chat_preview.tscn",
                                        "--", "--shots=%s" % ctx.posix(folder)], timeout=300)
    made = make_crops(str(ctx.out))
    if made:
        print("[banco] recortes de la interfaz: %d" % len(made))


def area_mundo(ctx):
    online = [s for s in ("vardheim", "solmarch") if ctx.want(s)]
    if online:
        # No NPCs or dummies: none block the scene.
        with server(ctx, "mundo", extra=("--no-npcs", "--no-dummies"), bots=swarms(ctx, ctx.bots(0))):
            if ctx.want("vardheim"):
                driver(ctx, "sc_mundo.gd", "mundo_vardheim", realm="vardheim", name="Recorredor")
            if ctx.want("solmarch"):
                driver(ctx, "sc_mundo.gd", "mundo_solmarch", realm="solmarch", name="Caminante")
    if ctx.want("camaras"):
        cams = ctx.out / "mundo" / "camaras_revision"
        cams.mkdir(parents=True, exist_ok=True)
        args = ["--path", ROOT, "--resolution", ctx.res, "-s", "res://tools/render/render_screenshot_points.gd", "--",
                "--out=%s" % ctx.posix(cams)]
        if ctx.args.sin_capsulas:
            args.append("--no-capsules")
        run_godot(ctx, "camaras_revision", args, timeout=900)
    if ctx.want("demo"):
        demo = ctx.out / "mundo" / "demo_sandbox"
        demo.mkdir(parents=True, exist_ok=True)
        run_godot(ctx, "demo_sandbox", ["--path", ROOT, "--resolution", ctx.res, "--", "--zone=vado_gris", "--demo",
                                        "--shots=%s" % ctx.posix(demo), "--quit-after-demo"], timeout=900)


def area_combate(ctx):
    refriegas = [s for s in ("refriegas", "refriegas_b") if ctx.want(s)]
    if refriegas:
        with server(ctx, "combate", bots=swarms(ctx, ctx.bots(6))):
            if ctx.want("refriegas"):
                driver(ctx, "sc_combate.gd", "combate", name="Combatiente")
            if ctx.want("refriegas_b"):
                driver(ctx, "sc_combate.gd", "combate_b", name="Combatiente")
    if ctx.want("bot") or ctx.want("bloqueo"):
        # A single bot, no NPCs or dummies: nobody else blocks the followed one.
        with server(ctx, "aislado", extra=("--no-npcs", "--no-dummies"), bots=single_bot()):
            if ctx.want("bot"):
                driver(ctx, "sc_remotos_bot.gd", "remotos_bot", name="Aprendiz", timeout=900)
            if ctx.want("bloqueo"):
                driver(ctx, "sc_bloqueo.gd", "bloqueo", name="Escudero", timeout=600)
    if ctx.want("pnj"):
        with server(ctx, "pnj", extra=("--no-dummies",)):
            phases = ["--phases=%s" % ctx.args.phases] if ctx.args.phases else []
            driver(ctx, "sc_remotos_pnj.gd", "remotos_pnj", name="Sparring", timeout=1800, extra=phases)
    compose_all(str(ctx.raw), str(ctx.out), prefix="rem_")
    compose_all(str(ctx.raw), str(ctx.out), prefix="com_bloqueo_recibir")


def area_video(ctx):
    video = ctx.out / "video"
    video.mkdir(parents=True, exist_ok=True)
    avi = video / "combate.avi"
    seconds = ctx.args.seconds
    start = time.monotonic()
    with server(ctx, "video", extra=("--no-dummies",), bots=single_bot()):
        ok = driver(ctx, "sc_video.gd", "video", name="Cronista", resolution=ctx.args.movie_resolution,
                    godot_args=["--write-movie", ctx.posix(avi), "--fixed-fps", "60"],
                    extra=["--seconds=%d" % seconds], timeout=seconds * 20 + 300)
    log = read_log(ctx.logs / "cliente_video.log")
    # The engine records at the project window size (window_width_override), not at --resolution.
    size = re.search(r"recording movie in (\d+)\D+(\d+) @ (\d+) FPS", log)
    speed = re.search(r"\((\d+)% of real-time speed\)", log)
    info = {"segundos_de_guion": seconds, "resolucion": "%sx%s" % (size.group(1), size.group(2)) if size else ctx.args.movie_resolution,
            "fps": int(size.group(3)) if size else 60, "velocidad_de_grabacion": "%s %% del tiempo real" % speed.group(1) if speed else "?",
            "tiempo_de_grabacion_s": int(time.monotonic() - start), "correcto": ok}
    if avi.exists():
        info["avi_mb"] = round(avi.stat().st_size / 1e6, 1)
        if ctx.args.mp4:
            ffmpeg = shutil.which("ffmpeg")
            if ffmpeg:
                mp4 = video / "combate.mp4"
                subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(avi), "-c:v", "libx264", "-crf", "20",
                                "-pix_fmt", "yuv420p", "-c:a", "aac", str(mp4)], check=False)
                if mp4.exists():
                    info["mp4_mb"] = round(mp4.stat().st_size / 1e6, 1)
            else:
                print("[banco] --mp4: no hay ffmpeg en el PATH")
    else:
        print("[banco] no se grabó el vídeo (%s)" % avi)
        _FAILED.append("video")
    (video / "video.json").write_text(json.dumps(info, indent=2, ensure_ascii=False), encoding="utf-8")


AREA_FUNCS = {
    "animacion": area_animacion, "mapa": area_mapa, "interfaz": area_interfaz, "mundo": area_mundo,
    "combate": area_combate, "video": area_video,
}


# ---------------------------------------------------------------------------------------------
# Run log and index
# ---------------------------------------------------------------------------------------------
def git_rev():
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=str(ROOT), capture_output=True, text=True, timeout=20)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def record_run(ctx, area, seconds):
    path = ctx.out / "run_info.json"
    try:
        info = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        info = {}
    info["commit"] = git_rev()
    info["resolution"] = ctx.res
    if not info.get("godot"):
        try:
            result = subprocess.run([ctx.godot, "--version"], capture_output=True, text=True, timeout=60)
            info["godot"] = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
        except (OSError, subprocess.SubprocessError):
            pass
    for log in sorted(glob.glob(str(ctx.logs / "*.log"))):
        match = re.search(r"Using Device #\d+: (.+)", read_log(log))
        if match:
            info["gpu"] = match.group(1).strip()
            break
    info.setdefault("areas", {})[area] = {"when": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), "seconds": int(seconds)}
    path.write_text(json.dumps(info, indent=2, ensure_ascii=False), encoding="utf-8")


def prune_raw(ctx):
    for png in glob.glob(str(ctx.raw / "*" / "*" / "*.png")):
        try:
            os.remove(png)
        except OSError:
            pass


def list_everything():
    print("Áreas y pasos (--steps a,b):")
    for area in AREAS:
        print("  %-10s %s" % (area, ", ".join(STEPS[area])))
    print("\nOrden: python tools/quality/run.py <área> [--out carpeta] [--port N]")
    print("Para ver los ids de las tiras del sandbox: godot --headless --path . -s res://tools/quality/anim_strips.gd -- --set=all --list")


def build_parser():
    parser = argparse.ArgumentParser(description="Banco de capturas de calidad (TEC-50)", add_help=True)
    parser.add_argument("area", choices=AREAS + ("todo", "indice", "listar"))
    parser.add_argument("--out", default=str(ROOT / "build" / "calidad"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("ELDMARK_QUALITY_PORT", DEFAULT_PORT)))
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--steps", default="")
    parser.add_argument("--only", default="")
    parser.add_argument("--phases", default="")
    parser.add_argument("--bots", type=int, default=None)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--movie-resolution", default="1600x900")
    parser.add_argument("--mp4", action="store_true")
    parser.add_argument("--sin-capsulas", action="store_true")
    parser.add_argument("--clean-raw", action="store_true")
    parser.add_argument("--godot", default=None)
    return parser


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    args = build_parser().parse_args(argv)
    if args.area == "listar":
        list_everything()
        return 0
    if args.area == "indice":
        make_index.build(args.out)
        return 0
    ctx = Ctx(args)
    ctx.bots = lambda default: default if args.bots is None else args.bots
    if not (ROOT / "override.cfg").exists():
        print("[banco] aviso: no hay override.cfg en la raíz del proyecto; las ventanas se abrirán en la pantalla principal.")
    areas = AREAS if args.area == "todo" else (args.area,)
    try:
        for area in areas:
            print("\n[banco] === %s ===" % area)
            start = time.monotonic()
            AREA_FUNCS[area](ctx)
            record_run(ctx, area, time.monotonic() - start)
            make_index.build(str(ctx.out))
    except KeyboardInterrupt:
        print("\n[banco] interrumpido")
        return 130
    except RuntimeError as err:
        print("[banco] error: %s" % err)
        return 1
    finally:
        _cleanup()
    if args.clean_raw:
        prune_raw(ctx)
    if _FAILED:
        print("\n[banco] pasos que fallaron: %s" % ", ".join(_FAILED))
        return 1
    print("\n[banco] listo: %s" % (ctx.out / "indice.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
