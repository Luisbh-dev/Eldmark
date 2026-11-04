#!/usr/bin/env python
"""Generates <output>/indice.md from what is in the capture bench folder.

Reads the strips' meta.json (<output>/raw/<accion>/<ventana>/meta.json), the logs written by the scenarios
(<output>/indices/<tag>.json) and run_info.json (which areas were regenerated, when and with what). It only lists what exists on
disk, so the index of a folder with only some areas can be regenerated.

Usage: python make_index.py <output>
"""
import glob
import json
import os
import sys

# strip prefix -> table title
CATS = [
    ("loc_", "Locomoción (sandbox, personaje del jugador, espada y escudo)"),
    ("com_", "Combate (espada y escudo): golpes, bloqueo, esquiva, controles, muerte, derribado, habilidades, poción"),
    ("arc_", "Arco"),
    ("npc_", "PNJ en el sandbox (arma, ticks y clips del PNJ con el aspecto del jugador): Hueco, Capitán, guardia de reino y Guardián de la Puerta"),
    ("rem_", "Personajes vistos desde otro cliente de verdad (servidor real; carpetas animacion/remoto y animacion/remoto_lado)"),
]
# combat actions that count towards clip coverage
ACTION_STATES = {"LIGHT", "HEAVY", "CHARGE", "BLOCK", "DODGE", "STAGGER", "STUN", "DEAD", "ABILITY", "SWAP", "DOWNED",
                 "REVIVE", "EXECUTE"}
# scenario log tags, per area
TAGS = {
    "mapa": ["mapa"],
    "interfaz": ["interfaz", "extras", "extras_boss", "realm", "front", "galeria"],
    "mundo_jugador": ["mundo_vardheim", "mundo_solmarch"],
    "combate": ["combate", "combate_b"],
}
BOT_NOTE_TAGS = ["remotos_bot", "remotos_pnj", "bloqueo"]

ORDEN = [
    ("animacion", "`python tools/quality/run.py animacion`", "Tiras de 12 fotogramas del personaje y de los PNJ en el sandbox, con tres cámaras."),
    ("mapa", "`python tools/quality/run.py mapa`", "Mapa M, minimapa y brújula en seis posiciones del Vado Gris."),
    ("interfaz", "`python tools/quality/run.py interfaz`", "HUD, ventanas, título, selección y creación de personaje, galería de la interfaz y chat."),
    ("mundo", "`python tools/quality/run.py mundo`", "66 vistas a altura de jugador, las cámaras de revisión de la zona y la demo del sandbox."),
    ("combate", "`python tools/quality/run.py combate`", "Refriegas, golpes recibidos en bloqueo y tiras de remotos aislados (bot, Huecos, Capitán, guardias y Guardianes)."),
    ("video", "`python tools/quality/run.py video`", "Vídeo de combate con el modo Movie Maker del motor (`--write-movie`)."),
]


def exists(base, rel):
    return os.path.exists(os.path.join(base, rel))


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def records(base, tag):
    data = read_json(os.path.join(base, "indices", tag + ".json"))
    if not data:
        return [], []
    return data.get("records", []), data.get("notes", [])


def table(out, base, recs):
    out.append("| Archivo | Qué muestra | Cómo se obtuvo |")
    out.append("|---|---|---|")
    n = 0
    for r in recs:
        if not exists(base, r["file"]):
            continue
        out.append("| `%s` | %s | %s |" % (r["file"], r["desc"].replace("|", "/"), r.get("how", "").replace("|", "/")))
        n += 1
    if n == 0:
        out.append("| (ninguno todavía) | | |")


def dedupe(recs):
    seen = {}
    for r in recs:
        seen[r["file"]] = r
    return sorted(seen.values(), key=lambda r: r["file"])


def clip_summary(meta):
    """Distinct clips shown by the animation layer and combat-action frames with and without a clip."""
    clips = []
    in_action = 0
    with_clip = 0
    for fr in meta["frames"]:
        clip = (fr.get("clip") or "").split("/")[-1]
        if clip and clip not in clips:
            clips.append(clip)
        if fr.get("action") in ACTION_STATES:
            in_action += 1
            if clip:
                with_clip += 1
    return clips, in_action, with_clip


def anim_section(out, base):
    raw = os.path.join(base, "raw")
    metas = {}
    for path in glob.glob(os.path.join(raw, "*", "*", "meta.json")):
        m = read_json(path)
        if m:
            metas[(m["id"], m["name"])] = m
    out.append("## 1. animacion/\n")
    if not metas:
        out.append("Sin tiras en esta carpeta (`python tools/quality/run.py animacion` o `combate`).\n")
        return
    out.append("Cada archivo es **una sola PNG** con una rejilla de 4 x 3 = 12 fotogramas repartidos a lo largo del clip (los ciclos de "
               "locomoción cubren exactamente un ciclo medido en vivo con la escala del animador; las demás acciones cubren la ventana indicada). "
               "Cada celda lleva su rótulo: nº, tiempo en segundos, acción de combate de la simulación (`NONE`, `LIGHT`...) y, en la segunda línea, "
               "el clip de combate que está enseñando la capa de animación con su instante y su velocidad (`clip@t xV`), o la velocidad del personaje (`v=`) "
               "o la fase de aire. «Sin clip de combate» en un fotograma de acción es justo lo que busca esta revisión: el personaje hace el golpe con la pose de locomoción.\n")
    out.append("Vistas (`animacion/<vista>/<archivo>`):\n")
    out.append("- `camara_juego/`: la cámara real del juego (`CameraRig`, por encima del hombro) recortada a 480x540 alrededor del personaje.\n"
               "- `lado/` y `frente/`: cuerpo entero de lado y de frente (cámara a 5-7 m, FOV 42, 400x520) sobre un suelo a cuadros de 1 m que delata el patinaje de los pies. Solo en las tiras del sandbox y en las del jugador local en red (`lado`).\n"
               "- `remoto/` y `remoto_lado/`: tiras `rem_*` de personajes vistos desde otro cliente de verdad: la cámara del juego recortada alrededor del remoto, y una cámara lateral propia a 5 m que ningún cuerpo puede tapar. "
               "El `meta.json` de cada una guarda por fotograma el clip de la capa de animación del remoto, y el rótulo `TAPADO` marca los fotogramas con otro cuerpo delante.\n")
    out.append("**Cómo se obtuvo:** el sandbox con `tools/quality/anim_strips.gd` (zona `test_world`, `PlayerCharacter` + `HumanoidVisual` + `CameraRig` + `LocalPlayerController`, un guion de entradas por acción en `anim_actions.gd`; "
               "lo que en el juego impone el servidor, como tambalear, aturdir, morir o derribar, se impone con `ActionMachine.impose_*` en el tick del guion). Las tiras `rem_*` y `com_bloqueo_recibir_golpe` salen del juego en red "
               "(`sc_remotos_bot.gd`, `sc_remotos_pnj.gd`, `sc_bloqueo.gd`): `strip_recorder.gd` guarda cada 50 ms los últimos 4,5 s del personaje seguido y, cuando ocurre la acción buscada, "
               "saca la tira con unos fotogramas de antes. Los fotogramas sueltos están en `raw/`.\n")
    keys = sorted(metas.keys())
    for prefix, title in CATS:
        rows = [k for k in keys if k[0].startswith(prefix)]
        # com_bloqueo_recibir_golpe comes from the networked game, but is listed with the rest of com_
        if prefix == "com_":
            rows = [k for k in rows]
        if not rows:
            continue
        out.append("\n### %s\n" % title)
        out.append("| Archivo (nombre en cada carpeta de vista) | Qué muestra | Intervalo (s) | Vistas | Clips de la capa de combate | Acción con clip | Notas |")
        out.append("|---|---|---|---|---|---|---|")
        for (aid, win) in rows:
            m = metas[(aid, win)]
            name = aid if win in ("ciclo", "") else "%s__%s" % (aid, win)
            views = []
            for v in ("camara_juego", "lado", "frente", "remoto", "remoto_lado"):
                if exists(base, "animacion/%s/%s.png" % (v, name)):
                    views.append(v)
            if not views:
                continue
            fr = m["frames"]
            title_text = m.get("title", aid) + ("" if win in ("ciclo", "") else " [%s]" % win)
            desc = (m.get("desc") or "").strip()
            weapon = (" (arma `%s`)" % m["weapon"]) if m.get("weapon") else ""
            clips, in_action, with_clip = clip_summary(m)
            clips_text = ", ".join("`%s`" % c for c in clips) if clips else "ninguno"
            cover = "%d/%d" % (with_clip, in_action) if in_action else "-"
            note = (m.get("note") or "").strip()
            out.append("| `%s.png` | %s%s. %s | %.2f-%.2f | %s | %s | %s | %s |" % (
                name, title_text, weapon, desc, fr[0]["t"], fr[-1]["t"], ", ".join(views), clips_text, cover, note))
    out.append("")


def simple_area(out, base, number, folder, title, intro, tags):
    out.append("## %s. %s\n" % (number, title))
    out.append(intro + "\n")
    allrec = []
    for tag in tags:
        r, _ = records(base, tag)
        allrec.extend(r)
    allrec = [r for r in dedupe(allrec) if r["file"].startswith(folder + "/")]
    if not allrec:
        out.append("Sin capturas todavía (`python tools/quality/run.py %s`).\n" % folder)
        return
    table(out, base, allrec)
    out.append("")


def list_files(out, base, rel_dir, pattern="*.png", limit=None):
    files = sorted(glob.glob(os.path.join(base, rel_dir, pattern)))
    if not files:
        return False
    if limit and len(files) > limit:
        head = files[:limit]
        for f in head:
            out.append("- `%s`" % os.path.relpath(f, base).replace("\\", "/"))
        out.append("- ... y %d más en `%s/`" % (len(files) - limit, rel_dir))
    else:
        for f in files:
            out.append("- `%s`" % os.path.relpath(f, base).replace("\\", "/"))
    return True


def mundo_section(out, base):
    out.append("## 4. mundo/\n")
    out.append("**Vistas a altura de jugador con la cámara real** (`CameraRig` por encima del hombro, HUD oculto), una por punto: en `mundo/jugador_vardheim/` (como Vardheim, norte) y `mundo/jugador_solmarch/` "
               "(como Solmarch; las mismas posiciones reflejadas z -> -z y yaw -> 180 - yaw, así cada reino ve su campamento y su muralla). 33 vistas por reino, 66 en total: campamento, muralla y puerta, calzadas, "
               "pinar, río, puente, ladera, fuerte por fuera (esquina, puerta lejos y cerca) y por dentro (patio, torre, círculo de captura, rampa, pasarela), vado (tres posiciones), ruinas de Eld, bordes con montañas, capilla y franja central. "
               "Se hacen sin PNJ ni bots (`--no-npcs --no-dummies`) para que ninguno tape el escenario.\n")
    for tag, title in (("mundo_vardheim", "Vardheim"), ("mundo_solmarch", "Solmarch")):
        recs, _ = records(base, tag)
        recs = [r for r in recs if exists(base, r["file"])]
        if not recs:
            continue
        out.append("\n### %s\n" % title)
        out.append("| Archivo | Qué muestra |")
        out.append("|---|---|")
        for r in recs:
            out.append("| `%s` | %s |" % (r["file"], r["desc"].replace("|", "/")))
    out.append("\n**Cámaras de revisión de la zona** (grupo `screenshot_points`, 10 vistas, sin HUD) con `tools/render/render_screenshot_points.gd`; "
               "incluye `metricas.txt` con FPS, llamadas de dibujo y primitivas por vista:\n")
    if not list_files(out, base, "mundo/camaras_revision", "*"):
        out.append("(sin capturas todavía: `python tools/quality/run.py mundo`)")
    metrics = os.path.join(base, "mundo", "camaras_revision", "metricas.txt")
    if os.path.exists(metrics):
        out.append("\n```text")
        out.append(open(metrics, encoding="utf-8").read().strip())
        out.append("```")
    out.append("\n**Demo del sandbox** (`godot --path . --resolution 1920x1080 -- --zone=vado_gris --demo --shots=<carpeta> --quit-after-demo`, sin red): "
               "`mundo/demo_sandbox/shot_NNN.png` son capturas con HUD cada 90 ticks de la ruta guionizada de Vardheim y `zona_*.png` las cámaras de revisión que hace el propio sandbox al terminar.\n")
    list_files(out, base, "mundo/demo_sandbox", "*.png", limit=8)
    out.append("")


def combate_section(out, base):
    out.append("## 5. combate/\n")
    out.append("Escenario `sc_combate.gd`: el cliente (Vardheim) se teletransporta al punto más concurrido del fuerte, o a la puerta, y combate con `Input.action_press` "
               "(acercarse, ligeros, habilidades, esquiva, bloqueo) mientras los bots de los dos reinos (`--bot-brain=siege`), los Huecos y el capitán pelean alrededor; cada ~0,9 s guarda una captura con HUD. "
               "La ejecución `combate` (`pelea_NN`, `bloqueo_recibiendo_NN`) es sobre el fuerte tal y como lo dejan los bots; `combate_b` (`pelea_b_NN`) restablece el fuerte (comando de depuración 8) cada dos rondas para que vuelvan los Huecos y el capitán.\n")
    recs = []
    for tag in TAGS["combate"]:
        r, _ = records(base, tag)
        recs.extend(r)
    recs = [r for r in dedupe(recs) if r["file"].startswith("combate/")]
    if recs:
        table(out, base, recs)
    else:
        out.append("Sin capturas todavía (`python tools/quality/run.py combate`).\n")
    out.append("\nLas tiras de bots, PNJ y golpes recibidos en bloqueo vistos desde este cliente están en `animacion/remoto/`, `animacion/remoto_lado/` y `animacion/camara_juego/com_bloqueo_recibir_golpe*.png` (sección 1).\n")


def notes_section(out, base):
    lines = []
    for tag in TAGS["mapa"] + TAGS["interfaz"] + TAGS["mundo_jugador"] + TAGS["combate"] + BOT_NOTE_TAGS:
        _, notes = records(base, tag)
        for n in notes:
            lines.append("- `%s`: %s" % (tag, n))
    if not lines:
        return
    out.append("## Notas de los escenarios\n")
    out.append("Lo que dijo cada escenario al ejecutarse (tiras conseguidas y no vistas, tomas repetidas por tapadas, avisos):\n")
    out.extend(lines)
    out.append("")


def video_section(out, base):
    files = sorted(glob.glob(os.path.join(base, "video", "*")))
    out.append("## 6. video/\n")
    if not files:
        out.append("Sin vídeo todavía (`python tools/quality/run.py video`).\n")
        return
    out.append("Combate de unos 60 s grabado con el modo Movie Maker del motor (`--write-movie`, a tiempo real, con el audio del bus maestro) contra los PNJ del fuerte y un bot enemigo; sirve para juzgar el sonido, la parada de golpe y la fluidez, que las capturas no enseñan. "
               "Si el juego no tiene sonidos (`assets/audio/` vacío), la pista de audio sale en silencio.\n")
    for f in files:
        size = os.path.getsize(f)
        out.append("- `%s` (%.1f MB)" % (os.path.relpath(f, base).replace("\\", "/"), size / 1e6))
    meta = read_json(os.path.join(base, "video", "video.json"))
    if meta:
        out.append("\nDatos de la grabación: %s\n" % ", ".join("%s: %s" % (k, v) for k, v in meta.items()))
    out.append("")


def limitations(out):
    out.append("## Lo que el banco no cubre, y cómo leer sus capturas\n")
    out.append("- **Cuentas.** El banco no usa cuentas ni contraseñas: el servidor va con `--debug-commands` y el cliente entra con un personaje efímero. "
               "El título, la selección y la creación de personaje se capturan **forzando la pantalla desde el script con datos de mentira** (`CharacterSelect.set_data`, `CharacterCreate.setup`): son las pantallas reales, no un flujo real contra la plataforma.\n"
               "- **Estados impuestos.** En las tiras del sandbox el tambaleo, el aturdimiento, la muerte, el derribado, reanimar y rematar los impone el guion con `ActionMachine.impose_*` y duraciones elegidas por él (tambaleo 24 ticks, aturdimiento 100...). "
               "Las tiras `rem_*` y las de golpe en bloqueo son del juego en red y no imponen nada.\n"
               "- **Recortes de la cámara del juego.** En `camara_juego/` el recorte se fija al empezar la ventana: en los saltos la cabeza sale del recorte en el punto más alto (`lado` y `frente` ajustan la altura de la cámara).\n"
               "- **Tiras de otros clientes.** Dependen de que el servidor y el bot hagan lo que se busca; las acciones que no ocurrieron en el tiempo del escenario salen en las notas de arriba como «no se vieron». "
               "Un fotograma `TAPADO` es uno con otro cuerpo más cerca de la cámara y encima del seguido; una tira con más de un tercio de ellos se repite hasta tres veces antes de darla por buena.\n"
               "- **Pantalla de carga.** La zona carga en un hilo y el porcentaje de la pantalla de carga solo se actualiza por tramos: las capturas enseñan lo que hubiera en ese momento.\n"
               "- **Sonido y fluidez.** Las imágenes no sirven para juzgarlos: para eso está el vídeo (`run.py video`).\n"
               "- **Hora del día, clima, otras zonas.** El Vado Gris es la única zona y su luz y su niebla son fijas.\n"
               "- **El hardware cuenta.** Las capturas dependen de la GPU y del motor de dibujo del equipo (cifras de `mundo/camaras_revision/metricas.txt` incluidas): compara siempre capturas de la misma máquina.\n")


def build(base):
    base = os.path.abspath(base)
    info = read_json(os.path.join(base, "run_info.json")) or {}
    out = []
    out.append("# Índice de capturas de calidad (Eldmark, Vado Gris)\n")
    out.append("Generado con `tools/quality/` (banco de capturas, TEC-50). Las capturas se hacen con ventana y GPU reales a la resolución indicada, "
               "contra un servidor dedicado propio (`--zone=vado_gris --debug-commands`) y un cliente de verdad conducido por `online_driver.gd`; las del sandbox, con el sandbox del juego. "
               "`raw/` contiene los fotogramas sueltos de las tiras, `indices/*.json` los registros que escribe el conductor y `logs/` el registro de cada proceso.\n")
    if info:
        out.append("| Dato | Valor |")
        out.append("|---|---|")
        for key, label in (("commit", "Commit del juego"), ("godot", "Motor"), ("gpu", "GPU"), ("resolution", "Resolución")):
            if info.get(key):
                out.append("| %s | %s |" % (label, info[key]))
        out.append("")
    out.append("### Órdenes (desde la raíz del proyecto)\n")
    out.append("| Área | Orden | Qué regenera | Última ejecución |")
    out.append("|---|---|---|---|")
    areas = info.get("areas", {})
    for area, order, what in ORDEN:
        last = areas.get(area)
        text = "%s, %d s" % (last.get("when", "?"), int(last.get("seconds", 0))) if last else "-"
        out.append("| %s | %s | %s | %s |" % (area, order, what, text))
    out.append("")
    anim_section(out, base)
    simple_area(out, base, 2, "mapa", "mapa/",
                "Escenario `sc_mapa.gd` como Vardheim. Lo que tiene tres niveles de zoom (80, 160 y 320 m visibles, teclas `=` y `-`) es el **minimapa**; el mapa M, mientras no tenga zoom propio, "
                "se enseña tal cual. Están los tres niveles del minimapa (`minimapa_zoom_*`), el minimapa y la brújula en seis posiciones, el mapa M abierto en cuatro posiciones y con el fuerte de cada reino. "
                "Recortes del minimapa: x3 del rectángulo del control; de la brújula: x2.",
                TAGS["mapa"])
    if exists(base, "mapa/imagen_horneada_vado_gris.png"):
        out.append("`mapa/imagen_horneada_vado_gris.png` es la imagen horneada del mapa tal cual (copia de `assets/maps/vado_gris.png`).\n")
    simple_area(out, base, 3, "interfaz", "interfaz/",
                "Escenarios `sc_interfaz.gd` (HUD en reposo y en pelea, placas, ventanas, ajustes, muerte, captura del fuerte), `sc_extras.gd` (marcador y barra de jefe), `sc_realm.gd`, `sc_front.gd` (título, selección y creación con datos de mentira) y `sc_gallery.gd` (galería de la interfaz).",
                TAGS["interfaz"])
    if glob.glob(os.path.join(base, "interfaz", "recorte_*.png")):
        out.append("Recortes de elementos (`crops.py`, las mismas regiones de píxeles de la auditoría para poder comparar antes y después):\n")
        list_files(out, base, "interfaz", "recorte_*.png")
        out.append("")
    if glob.glob(os.path.join(base, "interfaz", "chat_preview", "*.png")):
        out.append("Herramienta `scenes/tests/chat_preview.tscn`:\n")
        list_files(out, base, "interfaz/chat_preview", "*.png")
        out.append("")
    mundo_section(out, base)
    combate_section(out, base)
    video_section(out, base)
    notes_section(out, base)
    limitations(out)
    path = os.path.join(base, "indice.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print("escrito", path)
    return path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    build(sys.argv[1])
