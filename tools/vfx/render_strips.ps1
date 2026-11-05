# Records the frame strips of the hit effects (ART-09), the shadow test, the measurement of a
# brawl and the demo video, and composes the sheets.
#
# It opens the preview (scenes/tests/vfx_preview.tscn) in a window, once per effect, with
# --fixed-fps 60 so that it is deterministic, and then joins the frames with compose_strips.py.
# Windows go to the second screen if there is an override.cfg in the root (not pushed to the repo).
#
# Usage, from the project root:
#   powershell -File tools/vfx/render_strips.ps1 [-Out build/vfx/strips] [-Camera game|demo] [-Field]
#       [-Strips metal_side,flesh,...] [-Realms] [-Shade] [-Bench] [-Reel 60]
#
# By default it records with the GAME CAMERA (72 degree field of view, over the shoulder, at the
# game distance) over the Vado Gris terrain, with its sun, its shadows and its fog: it is what the
# bar in docs/quality.md asks for. With -Camera demo and without -Field it records the usual close-ups (40 degree
# field of view over a plain ground), useful for reviewing detail.
# -Realms also records the trail and the aura in the four realms (folders trail_r1..r4 and aura_r1..r4) and composes
# the comparison sheets. -Shade repeats the dust, the dodge and the cloth in the shade of a roof that only
# casts shadow (folder shade) and composes sombra_vs_sol.png. -Bench measures a brawl of ten effects
# (bench.json). -Reel 60 records the 60 s demo video (reel.avi, with Movie Maker; convert it with
# ffmpeg -i reel.avi -c:v libx264 -crf 20 -pix_fmt yuv420p reel.mp4). At the end it composes resumen.png.
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
	# For the per-realm tests it records into <effect>_r<n> without overwriting the normal strip.
	if ($Folder -ne $Name) {
		$previewArgs += "--folder=$Folder"
	}
	Invoke-Preview $previewArgs
}

# With "powershell -File" a comma-separated list arrives as a single string: it is split here.
$Strips = @($Strips | ForEach-Object { $_ -split "," })
$strips = $Strips
if ($Realms) {
	# The trail and the aura are recorded per realm; the normal one is redundant.
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
