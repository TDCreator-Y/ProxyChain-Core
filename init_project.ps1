$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"

# Check if flutter is installed
if (!(Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "===========================================================" -ForegroundColor Red
    Write-Host "Error: Flutter environment variable is not configured." -ForegroundColor Red
    Write-Host "Please ensure D:\TechEnv\flutter_windows_3.44.0-stable\flutter\bin is added to Path and restart terminal." -ForegroundColor Yellow
    Write-Host "===========================================================" -ForegroundColor Red
    exit 1
}

$PROJECT_NAME = "flutter_rust_app"

Write-Host "1. Initializing Flutter host project..." -ForegroundColor Green
if (!(Test-Path "pubspec.yaml")) {
    flutter create --project-name $PROJECT_NAME .
} else {
    Write-Host "Flutter project already exists, skipping initialization." -ForegroundColor Yellow
}

Write-Host "2. Replacing main.dart..." -ForegroundColor Green
if (Test-Path "lib\main_frb.dart") {
    Move-Item -Path "lib\main_frb.dart" -Destination "lib\main.dart" -Force
}

Write-Host "3. Installing flutter_rust_bridge dependencies..." -ForegroundColor Green
flutter pub add flutter_rust_bridge
flutter pub add -d flutter_rust_bridge_codegen
flutter pub add -d build_runner
flutter pub add -d ffigen

Write-Host "4. Installing frb_codegen CLI tool (This may take a few minutes)..." -ForegroundColor Green
cargo install flutter_rust_bridge_codegen@^2.0.0

Write-Host "5. Generating bidirectional communication bridge code..." -ForegroundColor Green
flutter_rust_bridge_codegen generate

Write-Host "===========================================================" -ForegroundColor Green
Write-Host "Initialization completed!" -ForegroundColor Green
Write-Host "You can run the project on Windows desktop using:" -ForegroundColor Yellow
Write-Host "flutter run -d windows" -ForegroundColor Yellow
Write-Host "===========================================================" -ForegroundColor Green
