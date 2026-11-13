# publicar.ps1 - publica una version nueva del buscador para que la app de tus amigos se actualice sola.
# Uso: doble clic en "Publicar actualizacion.bat" (o: powershell -File publicar.ps1 -Notes "que cambio")
# Pasos: sube el numero de version, firma el indice con tu clave privada, rearma el zip y sube todo a GitHub.
param([string]$Notes, [switch]$NoPush)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$keyFile = Join-Path $env:LOCALAPPDATA 'l4d2-finder\update-key.xml'
if (-not (Test-Path $keyFile)) { throw "No encuentro la clave para firmar ($keyFile). Sin ella tus amigos rechazan las actualizaciones." }
$files = @('finder.ps1', 'ui.ps1', 'vpk.ps1', 'lobbies.ps1', 'Buscar versus.bat')

# Direccion de GitHub (sale del repositorio)
$remote = (git remote get-url origin 2>$null)
if (-not $remote) { throw 'Este repositorio no tiene GitHub configurado (git remote add origin ...).' }
if ($remote -notmatch 'github\.com[:/]([^/]+)/([^/.]+?)(\.git)?$') { throw "No reconozco la direccion de GitHub: $remote" }
$base = "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/main"

if ($null -eq $Notes -or $PSBoundParameters.Count -eq 0) { $Notes = Read-Host 'Qué cambió en esta versión (una línea, opcional)' }

# 1) Subir la version (y dejar anotada la direccion de GitHub)
$finder = Join-Path $here 'finder.ps1'
$t = [IO.File]::ReadAllText($finder)
if ($t -notmatch '(?m)^\$AppVersion = (\d+)') { throw 'No encuentro $AppVersion en finder.ps1' }
$ver = [int]$Matches[1] + 1
$t = [regex]::Replace($t, '(?m)^\$AppVersion = \d+', "`$AppVersion = $ver")
$t = [regex]::Replace($t, "(?m)^\`$updateBase = '[^']*'", "`$updateBase = '$base'")
[IO.File]::WriteAllText($finder, $t, (New-Object Text.UTF8Encoding($true)))

# 2) Indice con la huella de cada archivo, firmado
$sha = [Security.Cryptography.SHA256]::Create()
$hashes = [ordered]@{}
foreach ($f in $files) { $hashes[$f] = -join ($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $here $f))) | ForEach-Object { $_.ToString('x2') }) }
$man = [ordered]@{ version = $ver; notes = "$Notes"; date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); files = $hashes }
$manBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($man | ConvertTo-Json -Depth 3))
[IO.File]::WriteAllBytes((Join-Path $here 'update.json'), $manBytes)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.FromXmlString([IO.File]::ReadAllText($keyFile))
[IO.File]::WriteAllText((Join-Path $here 'update.sig'), [Convert]::ToBase64String($rsa.SignData($manBytes, 'SHA256')))

# 3) Zip para pasarle a amigos nuevos (sin la API key ni tu configuracion)
Compress-Archive -Path $files -DestinationPath (Join-Path $here 'buscador-para-amigos.zip') -Force

# 4) Subir a GitHub
git add -- $files update.json update.sig .gitignore .gitattributes publicar.ps1 'Publicar actualizacion.bat'
git commit -q -m "Version $ver$(if ($Notes) { ": $Notes" })"
if (-not $NoPush) { git push -q origin main; if ($LASTEXITCODE) { throw 'No se pudo subir a GitHub (git push fallo).' } }
Write-Host ''
Write-Host "Listo: versión $ver publicada. Tus amigos la reciben la próxima vez que abran la app (o en menos de 6 horas)." -ForegroundColor Green
