# scripts/build.ps1 — Build gobot with version injection
# Usage: .\scripts\build.ps1

$VERSION = git describe --tags --always --dirty 2>$null
if (-not $VERSION) { $VERSION = "v0.1.0-dev" }
$COMMIT = git rev-parse --short HEAD
$BUILD_TIME = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
$LDFLAGS = "-X main.version=$VERSION -X main.commitHash=$COMMIT -X main.buildTime=$BUILD_TIME"

Write-Host "Building gobot $VERSION ($COMMIT)..."
go build -mod=vendor -ldflags $LDFLAGS -o gobot.exe ./cmd/gobot
if ($LASTEXITCODE -eq 0) {
    Write-Host "Build successful: gobot.exe"
} else {
    Write-Error "Build failed"
    exit 1
}
