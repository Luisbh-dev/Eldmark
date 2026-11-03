# Graba las tiras de fotogramas de los efectos de golpe (ART-09) y las compone en hojas.
#
# Abre la vista previa (scenes/tests/vfx_preview.tscn) en ventana, una vez por efecto, con
# --fixed-fps 60 para que sea determinista, y después une los fotogramas con compose_strips.py.
# Las ventanas salen en la segunda pantalla si hay un override.cfg en la raíz (no se sube al repo).
#
# Uso, desde la raíz del proyecto:
#   powershell -File tools/vfx/render_strips.ps1 [-Out build/vfx/strips] [-Strips metal,flesh,...] [-Realms]
#
# Con -Realms graba además la estela y el aura en los cuatro reinos (carpetas trail_r1..r4 y aura_r1..r4)
# y compone las hojas de comparación. Al final siempre compone resumen.png (un fotograma de cada efecto;
# necesita las carpetas de -Realms para sus casillas de estela y aura).
param(
	[string]$Out = "build/vfx/strips",
	[string[]]$Strips = @("metal", "flesh", "block", "parry", "dust", "dodge", "trail", "aura", "showcase"),
	[switch]$Realms
)

$godot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
if (-not (Test-Path $godot)) {
	Write-Error "No encuentro Godot en $godot"
	exit 1
}

function Invoke-Strip([string]$Name, [string]$Folder, [int]$Realm) {
	$arguments = @("--path", ".", "res://scenes/tests/vfx_preview.tscn", "--fixed-fps", "60", "--",
		"--strip=$Name", "--out=$Out", "--realm=$Realm")
	# Para las pruebas por reino se graba en <efecto>_r<n> sin pisar la tira normal.
	if ($Folder -ne $Name) {
		$arguments += "--folder=$Folder"
	}
	$process = Start-Process -FilePath $godot -ArgumentList $arguments -PassThru -WindowStyle Minimized
	if (-not $process.WaitForExit(180000)) {
		$process.Kill()
		Write-Warning "Tiempo agotado grabando $Folder"
	}
}

foreach ($name in $Strips) {
	Write-Host "Grabando $name"
	Invoke-Strip $name $name 0
}
if ($Realms) {
	foreach ($name in @("trail", "aura")) {
		foreach ($realm in 1..4) {
			Write-Host "Grabando $name (reino $realm)"
			Invoke-Strip $name "${name}_r$realm" $realm
		}
	}
}
$compose = @("tools/vfx/compose_strips.py", $Out, "--summary")
if ($Realms) {
	$compose += "--realms"
}
python @compose
