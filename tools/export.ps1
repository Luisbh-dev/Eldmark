<#
.SYNOPSIS
Exporta Eldmark con los presets de export_presets.cfg (TEC-12). Es el equivalente en PowerShell de
tools/export.sh.

.DESCRIPTION
Destinos:
  client  "Cliente Windows"  -> exports\windows\Eldmark.exe (y su .pck)
  server  "Servidor Linux"   -> exports\server\eldmark-server.x86_64 (y su .pck), servidor dedicado con
                                los modelos, materiales, audio y animaciones recortados, más
                                run-server.sh, que lo lanza con --headless
  all     los dos (por defecto)

Requisitos (ver README, «Exportación»):
  - Godot 4.7.2: la variable de entorno GODOT, `godot` en el PATH o la instalación de winget.
  - Salvo con -PackOnly, las plantillas de exportación de la misma versión (Editor > Administrar
    plantillas de exportación > Descargar e instalar).
  - Los objetos de Git LFS descargados (git lfs pull): el terreno y las texturas van por LFS.

Códigos de salida: 0 bien, 1 fallo, 2 falta Godot, sus plantillas o los objetos LFS.

.PARAMETER Target
client, server o all (por defecto).

.PARAMETER DebugBuild
Exporta con las plantillas de depuración en lugar de las de lanzamiento.

.PARAMETER PackOnly
Solo el .pck de cada preset (godot --export-pack): NO necesita las plantillas de exportación y sirve
para comprobar los filtros y el recorte de recursos.

.PARAMETER Zip
Comprime cada carpeta exportada (exports\Eldmark-windows.zip, exports\Eldmark-server.zip).

.PARAMETER DryRun
Muestra lo que haría sin exportar nada.

.EXAMPLE
tools\export.ps1 -Target client

.EXAMPLE
tools\export.ps1 -PackOnly -Zip
#>
[CmdletBinding()]
param(
	[ValidateSet('client', 'server', 'all')]
	[string]$Target = 'all',
	[switch]$DebugBuild,
	[switch]$PackOnly,
	[switch]$Zip,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Writes the message to the error output and exits with that code (Write-Error with 'Stop' would
# always exit with 1).
function Fail {
	param([string]$Message, [int]$Code)
	[Console]::Error.WriteLine($Message)
	exit $Code
}

# Preset names (those in export_presets.cfg; test_export_config.gd checks that they match).
$ClientPreset = 'Cliente Windows'
$ServerPreset = 'Servidor Linux'
$ClientOut = 'exports/windows/Eldmark.exe'
$ServerOut = 'exports/server/eldmark-server.x86_64'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root
$Mode = if ($DebugBuild) { 'debug' } else { 'release' }

# Finds the Godot executable: GODOT, the PATH and the winget install (4.7.2 console).
function Find-Godot {
	if ($env:GODOT) { return $env:GODOT }
	$command = Get-Command godot -ErrorAction SilentlyContinue
	if ($command) { return $command.Source }
	$winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe'
	if (Test-Path $winget) { return $winget }
	return $null
}

$Godot = Find-Godot
if (-not $Godot) {
	Fail 'No se encuentra Godot. Instala Godot 4.7.2 o indica su ruta con la variable de entorno GODOT.' 2
}

# Godot version ("4.7.2.stable.official.xxxx" -> "4.7.2.stable") and its templates folder.
$GodotVersion = (& $Godot --version | Select-Object -First 1).Trim()
$TemplateVersion = ($GodotVersion -split '\.')[0..3] -join '.'
# (In Windows PowerShell 5.1 $IsLinux and $IsMacOS do not exist and are $null: falls through to Windows.)
if ($IsLinux) {
	$DataBase = $env:XDG_DATA_HOME
	if (-not $DataBase) { $DataBase = Join-Path $HOME '.local/share' }
	$DataHome = Join-Path $DataBase 'godot'
} elseif ($IsMacOS) {
	$DataHome = Join-Path $HOME 'Library/Application Support/Godot'
} else {
	$DataHome = Join-Path $env:APPDATA 'Godot'
}
$TemplatesDir = Join-Path $DataHome "export_templates/$TemplateVersion"

# Runs a command (or only prints it with -DryRun) and fails if it exits with an error.
function Invoke-Step {
	param([string]$Exe, [string[]]$Arguments)
	$shown = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
	Write-Host "+ $Exe $shown"
	if (-not $DryRun) {
		& $Exe @Arguments
		if ($LASTEXITCODE -ne 0) {
			Fail "Falló: $Exe $shown (código $LASTEXITCODE)" 1
		}
	}
}

function Test-Templates {
	param([string]$Pattern, [string]$Platform)
	if (-not (Get-ChildItem -Path $TemplatesDir -Filter $Pattern -ErrorAction SilentlyContinue)) {
		Fail @"
Faltan las plantillas de exportación de $Platform para Godot $TemplateVersion.
Instálalas desde el editor (Editor > Administrar plantillas de exportación > Descargar e instalar,
o Instalar desde archivo con el .tpz de la versión $TemplateVersion). Se esperan en:
  $TemplatesDir
Para comprobar solo los filtros de los presets, sin plantillas: tools\export.ps1 -PackOnly
"@ 2
	}
}

# The terrain .res files go through Git LFS: if they are pointers, the export would come out broken.
$Sample = Join-Path $Root 'scenes/world/zones/vado_gris/terrain/terrain3d_00_00.res'
if (Test-Path $Sample) {
	$head = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Sample)[0..63])
	if ($head -like '*version https://git-lfs*') {
		Fail 'Los objetos de Git LFS no están descargados (el terreno es un puntero). Ejecuta: git lfs pull' 2
	}
}

if (-not $PackOnly -and -not $DryRun) {
	if ($Target -in 'client', 'all') { Test-Templates "windows_${Mode}_x86_64*" 'Windows' }
	if ($Target -in 'server', 'all') { Test-Templates "linux_${Mode}*" 'Linux' }
}

# Build identifier (git describe), stored next to the exported files.
try { $BuildId = (git describe --tags --always --dirty 2>$null) } catch { $BuildId = $null }
if (-not $BuildId) { $BuildId = 'desconocido' }
Write-Host "Godot $GodotVersion · compilación $BuildId · destino: $Target ($Mode)"

# Imports the resources (brings the .godot/ cache that the export uses up to date).
Invoke-Step $Godot @('--headless', '--path', $Root, '--import')

function Export-Preset {
	param([string]$Preset, [string]$Out)
	$dir = Split-Path $Out -Parent
	if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
	if ($PackOnly) {
		$pack = [System.IO.Path]::ChangeExtension($Out, '.pck')
		Invoke-Step $Godot @('--headless', '--path', $Root, '--export-pack', $Preset, $pack)
	} else {
		Invoke-Step $Godot @('--headless', '--path', $Root, "--export-$Mode", $Preset, $Out)
	}
	if (-not $DryRun) { Set-Content -Path (Join-Path $dir 'BUILD_ID') -Value $BuildId -Encoding ascii }
}

function Compress-Export {
	param([string]$Dir, [string]$Name)
	Write-Host "+ Compress-Archive $Dir\* exports\$Name"
	if (-not $DryRun) {
		Remove-Item -Force -ErrorAction SilentlyContinue "exports/$Name"
		Compress-Archive -Path "$Dir/*" -DestinationPath "exports/$Name"
	}
}

if ($Target -in 'client', 'all') {
	Export-Preset $ClientPreset $ClientOut
	if ($Zip) { Compress-Export 'exports/windows' 'Eldmark-windows.zip' }
}

if ($Target -in 'server', 'all') {
	Export-Preset $ServerPreset $ServerOut
	if (-not $DryRun) {
		# The dedicated server always runs without a window: the launcher adds --headless and passes the
		# remaining options (--zone, --port, --max-players...) after --server. With LF line endings,
		# which is what bash expects.
		$launcher = @'
#!/usr/bin/env bash
# Launches the Eldmark dedicated server: ./run-server.sh --zone=vado_gris --port=24600
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./eldmark-server.x86_64 --headless -- --server "$@"
'@
		$launcher = $launcher -replace "`r`n", "`n"
		[System.IO.File]::WriteAllText((Join-Path $Root 'exports/server/run-server.sh'), $launcher)
	}
	if ($Zip) { Compress-Export 'exports/server' 'Eldmark-server.zip' }
}

Write-Host "Listo. Lo exportado está en $Root\exports\"
