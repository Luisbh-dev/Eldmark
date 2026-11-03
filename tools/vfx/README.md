# Efectos de golpe (ART-09): cómo se hacen y cómo se comprueban

Todo es contenido propio, generado con código y versionado: texturas con numpy y PIL
(`make_vfx_textures.py`, semillas fijas), escenas y materiales con Godot (`build_vfx_scenes.gd`) y
sombreadores escritos a mano (`scenes/vfx/shaders/`). Lo único que se sube a Git son los resultados de
texto y los PNG (por LFS); lo demás se regenera.

## Regenerar

Desde la raíz del proyecto, con el editor cerrado:

```
python tools/vfx/make_vfx_textures.py
godot --headless --path . --import
godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd
godot --headless --path . --import
godot --headless --path . -s res://tests/run_tests.gd -- --filter=test_vfx
```

Los números de cada efecto (tamaños, tiempos, velocidades, colores) están en `build_vfx_scenes.gd`; no se
retoca nada a mano en los `.tscn`. El script de texturas no reescribe los `.import` que ya existen (Godot les
pone un uid propio y se lo cambiaría a todo lo que los referencia).

## Qué es cada cosa

| Efecto | Escena | Qué lo distingue |
|---|---|---|
| Chispa de metal | `hit_metal_spark` | Punto incandescente de 0,06 s, destello, chispas con cola en un cono que se inclina con el tajo (`direction_bias`) y frenan en 1,5 m, esquirlas que nacen al rojo. |
| Carne | `hit_flesh` | Dos chorros de una secuencia de cinco fotogramas (4 variantes por 2 reflejos), de 0,4 m y 0,2 s, orientados con la dirección del golpe; rojo oscuro con brillo. |
| Tela | `hit_cloth` | Bocanada clara con luz e hilachas que caen. |
| Bloqueo | `hit_block_wood` | Golpe sordo: destello apagado adelantado hacia la cámara, medio anillo aplanado sobre la cara del escudo, tablillas planas de dos tonos (máx. 1,5 m) y polvo pardo. |
| Parada | `parry_flash` | Estrella con rayos, destello de lente horizontal y una onda de choque fina sobre el plano del impacto. 0,25 s en total; no cubre la cara del rival. |
| Polvo | `dust_kick` | Aterrizaje: bocanadas bajas en anillo (y un anillo de 1,2 m solo en caídas fuertes). Esquiva: media luna pegada al suelo y rociada hacia atrás. Con luz y sombra; color del suelo (`VfxGround`), no del reino. |
| Estela | `weapon_trail` | Cinta que sigue el arco de la hoja alrededor de la mano, con tres muestras como mínimo, cola que se estrecha y se apaga, tomada al actualizarse el esqueleto. Colores por reino. |
| Aura de carga | `charge_aura` | En el arma, no en el cuerpo: brillo a lo largo de la hoja que crece con la carga, motas y brasas absorbidas, calor y la runa del suelo; destello y onda plana al llegar al máximo y al soltar. |

La arquitectura de reutilización (`VfxEffect`, `VfxPool`, metadatos `vfx_time`, `vfx_cue`, `vfx_tint`,
`vfx_variants`) está explicada en la cabecera de `scripts/client/vfx/vfx_effect.gd`. Nada de esto está
conectado al combate todavía.

## Comprobar (el listón de `docs/calidad.md`)

`render_strips.ps1` abre `scenes/tests/vfx_preview.tscn` en ventana, de forma determinista (`--fixed-fps 60`):

```
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips -Realms -Shade -Bench
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips_cerca -Camera demo -Strips metal_side,flesh,block,parry,dust,dodge,trail,aura
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips -Strips flesh -Reel 60
```

- **Cámara del juego** (por defecto): la `CameraRig` real (campo de visión de 72 grados, por encima del hombro),
  sobre el campamento de Vardheim del Vado Gris con su sol, sombras y niebla. Es lo que ve el jugador.
- **Primeros planos** (`-Camera demo`): campo de visión de 40 grados sobre un suelo liso, para revisar el detalle.
- **Sombra** (`-Shade`): el mismo polvo bajo un techo que solo proyecta sombra; `sombra_vs_sol.png` los compara.
- **Refriega** (`-Bench`): diez efectos a la vez más la estela y el aura, frente a la misma escena sin efectos;
  escribe `bench.json` con llamadas de dibujo, objetos, primitivas y tiempos de GPU y CPU.
- **Vídeo** (`-Reel 60`): un minuto con `--write-movie`, con los cuatro reinos, un tramo a la sombra y una refriega.
  Sin sonido (el juego aún no tiene audio).

Las pruebas (`tests/test_vfx.gd`) fijan los números de diseño: sin anillos de cara a la cámara ni relleno, tiempos
y tamaños de la parada y el bloqueo, alcance máximo de chispas, astillas y gotas, mínimo de tres muestras de la
estela, polvo del suelo y no del reino.
