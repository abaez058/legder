$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$showcaseDir = Join-Path $repoRoot 'showcase'
$walPath = Join-Path ([System.IO.Path]::GetTempPath()) ("legder-wal-{0}.dat" -f [guid]::NewGuid().ToString('N'))
$executable = Join-Path $showcaseDir 'bin\showcase.exe'

Push-Location $showcaseDir
try {
    alr build
    if ($LASTEXITCODE -ne 0) {
        throw "Alire showcase build failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path $executable)) {
        throw "Showcase executable was not produced at $executable"
    }

    & $executable write $walPath
    if ($LASTEXITCODE -ne 0) {
        throw "WAL append process failed with exit code $LASTEXITCODE"
    }

    & $executable verify $walPath
    if ($LASTEXITCODE -ne 0) {
        throw "WAL recovery process failed with exit code $LASTEXITCODE"
    }

    Write-Output 'PASS: WAL append, disk persistence, process restart, and replay'
}
finally {
    Pop-Location
    if (Test-Path $walPath) {
        Remove-Item $walPath -Force
    }
}
