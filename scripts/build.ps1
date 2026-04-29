# scripts/build.ps1 — Build gobot with version injection
# Usage: .\scripts\build.ps1

$VERSION = git describe --tags --always --dirty 2>$null
if (-not $VERSION) { $VERSION = "v0.1.0-dev" }
$COMMIT = git rev-parse --short HEAD
$BUILD_TIME = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
$LDFLAGS = "-X main.version=$VERSION -X main.commitHash=$COMMIT -X main.buildTime=$BUILD_TIME"

if (Get-Command goversioninfo -ErrorAction SilentlyContinue) {
    Write-Host "Generating Windows version resources..."
    goversioninfo -platform-specific -o resource.syso versioninfo.json
}

$MOD_FLAG = ""
if (Test-Path "vendor") {
    Write-Host "Using vendor directory..."
    $MOD_FLAG = "-mod=vendor"
} else {
    Write-Host "Vendor directory missing. Downloading modules..."
    go mod download
}

if (-not (Test-Path "bin")) { New-Item -ItemType Directory -Path "bin" | Out-Null }
Write-Host "Building gobot $VERSION ($COMMIT)..."
go build $MOD_FLAG -ldflags $LDFLAGS -o bin/gobot.exe ./cmd/gobot
$EXIT_CODE = $LASTEXITCODE

if (Test-Path resource.syso) {
    Remove-Item resource.syso
}

if ($EXIT_CODE -eq 0) {
    Write-Host "Build successful: bin/gobot.exe"
} else {
    Write-Error "Build failed"
    exit 1
}
