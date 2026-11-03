# Graba las tiras de fotogramas de los efectos de golpe (ART-09), la prueba a la sombra, la medición de una
# refriega y el vídeo de demostración, y compone las hojas.
#
# Abre la vista previa (scenes/tests/vfx_preview.tscn) en ventana, una vez por efecto, con
# --fixed-fps 60 para que sea determinista, y después une los fotogramas con compose_strips.py.
# Las ventanas salen en la segunda pantalla si hay un override.cfg en la raíz (no se sube al repo).
#
# Uso, desde la raíz del proyecto:
#   powershell -File tools/vfx/render_strips.ps1 [-Out build/vfx/strips] [-Camera game|demo] [-Field]
#       [-Strips metal_side,flesh,...] [-Realms] [-Shade] [-Bench] [-Reel 60]
#
# Por defecto graba con la CÁMARA DEL JUEGO (campo de visión de 72 grados, por encima del hombro, a la
# distancia de juego) sobre el terreno del Vado Gris, con su sol, sus sombras y su niebla: es lo que pide el
# listón de docs/calidad.md. Con -Camera demo y sin -Field graba los primeros planos de siempre (campo de
# visión de 40 grados sobre un suelo liso), útiles para revisar el detalle.
# -Realms graba además la estela y el aura en los cuatro reinos (carpetas trail_r1..r4 y aura_r1..r4) y compone
# las hojas de comparación. -Shade repite el polvo, la esquiva y la tela a la sombra de un techo que solo
# proyecta sombra (carpeta shade) y compone sombra_vs_sol.png. -Bench mide una refriega de diez efectos
# (bench.json). -Reel 60 graba el vídeo de demostración de 60 s (reel.avi, con Movie Maker; conviértelo con
# ffmpeg -i reel.avi -c:v libx264 -crf 20 -pix_fmt yuv420p reel.mp4). Al final compone resumen.png.
param(
	[string]$Out = "build/vfx/strips",
	[ValidateSet("game", "demo")][string]$Camera = "game",
	[switch]$Field,
	[string[]]$Strips = @("metal_side", "flesh", "cloth", "block", "parry", "dust", "dust_soft", "dodge", "melee", "showcase"),
	[switch]$Realms,
	[switch]$Shade,
	[switch]$Bench,
	[int]$Reel = 0
)

$godot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
if (-not (Test-Path $godot)) {
	Write-Error "No encuentro Godot en $godot"
	exit 1
}
$scene = "res://scenes/tests/vfx_preview.tscn"
$scenario = @("--camera=$Camera")
if ($Field -or $Camera -eq "game") {
	$scenario += "--field"
}

function Invoke-Preview([string[]]$PreviewArgs, [string[]]$EngineArgs = @()) {
	$arguments = @("--path", ".", $scene, "--fixed-fps", "60") + $EngineArgs + @("--") + $PreviewArgs
	$process = Start-Process -FilePath $godot -ArgumentList $arguments -PassThru -WindowStyle Minimized
	if (-not $process.WaitForExit(600000)) {
		$process.Kill()
		Write-Warning "Tiempo agotado con $PreviewArgs"
	}
}

function Invoke-Strip([string]$Name, [string]$Folder, [int]$Realm, [string]$OutDir, [string[]]$Extra = @()) {
	$previewArgs = @("--strip=$Name", "--out=$OutDir", "--realm=$Realm") + $scenario + $Extra
	# Para las pruebas por reino se graba en <efecto>_r<n> sin pisar la tira normal.
	if ($Folder -ne $Name) {
		$previewArgs += "--folder=$Folder"
	}
	Invoke-Preview $previewArgs
}

# Con "powershell -File" una lista separada por comas llega como un solo texto: se parte aquí.
$Strips = @($Strips | ForEach-Object { $_ -split "," })
$strips = $Strips
if ($Realms) {
	# La estela y el aura se graban por reino; la normal sobra.
	$strips = $Strips | Where-Object { $_ -ne "trail" -and $_ -ne "aura" }
}
foreach ($name in $strips) {
	Write-Host "Grabando $name"
	Invoke-Strip $name $name 0 $Out
}
if ($Realms) {
	foreach ($name in @("trail", "aura")) {
		foreach ($realm in 1..4) {
			Write-Host "Grabando $name (reino $realm)"
			Invoke-Strip $name "${name}_r$realm" $realm $Out
		}
	}
}
if ($Shade) {
	$shadeDir = Join-Path (Split-Path $Out -Parent) "shade"
	foreach ($name in @("dust", "dodge", "cloth")) {
		Write-Host "Grabando $name a la sombra"
		Invoke-Strip $name $name 0 $shadeDir @("--shade")
	}
}
if ($Bench) {
	Write-Host "Midiendo la refriega"
	Invoke-Preview @("--bench", "--out=$(Join-Path (Split-Path $Out -Parent) 'bench')")
}
if ($Reel -gt 0) {
	$videoDir = Join-Path (Split-Path $Out -Parent) "video"
	New-Item -ItemType Directory -Force $videoDir | Out-Null
	Write-Host "Grabando el vídeo de $Reel s"
	Invoke-Preview @("--reel=$Reel") @("--write-movie", (Join-Path (Resolve-Path $videoDir) "reel.avi"))
}
$compose = @("tools/vfx/compose_strips.py", $Out, "--summary")
if ($Realms) {
	$compose += "--realms"
}
python @compose
