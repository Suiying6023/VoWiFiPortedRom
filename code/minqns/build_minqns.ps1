$ErrorActionPreference = 'Stop'
if (-not $env:MINQNS_KEYSTORE_PASSWORD) {
    throw 'Set MINQNS_KEYSTORE_PASSWORD before building; signing material stays local.'
}

$root = $PSScriptRoot
$jdk  = 'D:\Code\Claude Code\ksu-work\jdk\jdk-21.0.12+8\bin'
$sdk  = 'C:\Users\26928\AppData\Local\Android\Sdk'
$bt   = Join-Path $sdk 'build-tools\37.0.0'
$jar  = Join-Path $sdk 'platforms\android-36.1\android.jar'
$build = Join-Path $root 'build'

# Put JDK on PATH so d8.bat/apksigner.bat find java.
$env:Path = "$jdk;$env:Path"

foreach ($d in @('build\stub_classes','build\classes','build\dex','build')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
}

Write-Output '=== 1/6 compile stub QualifiedNetworksService ==='
& "$jdk\javac.exe" -source 8 -target 8 -bootclasspath $jar `
    -d (Join-Path $build 'stub_classes') `
    (Join-Path $root 'stub\android\telephony\data\QualifiedNetworksService.java')

Write-Output '=== 2/6 compile MinQnsService ==='
& "$jdk\javac.exe" -source 8 -target 8 -bootclasspath $jar `
    -classpath "$(Join-Path $build 'stub_classes');$jar" `
    -d (Join-Path $build 'classes') `
    (Join-Path $root 'src\com\voxi\minqns\MinQnsService.java')

Write-Output '=== 3/6 d8 dex ==='
$classFiles = @(Get-ChildItem -Path (Join-Path $build 'classes') -Recurse -Filter *.class | ForEach-Object { $_.FullName })
if ($classFiles.Count -eq 0) { throw 'No class files to dex' }
& "$bt\d8.bat" --release --lib $jar `
    --output (Join-Path $build 'dex') `
    @classFiles

Write-Output '=== 4/6 aapt2 link ==='
& "$bt\aapt2.exe" link -o (Join-Path $build 'minqns-unsigned.apk') `
    -I $jar `
    --manifest (Join-Path $root 'AndroidManifest.xml') `
    --min-sdk-version 32 `
    --target-sdk-version 36

Write-Output '=== 5/6 add classes.dex + zipalign ==='
& "$jdk\jar.exe" uf (Join-Path $build 'minqns-unsigned.apk') -C (Join-Path $build 'dex') classes.dex
& "$bt\zipalign.exe" -f 4 (Join-Path $build 'minqns-unsigned.apk') (Join-Path $build 'minqns-aligned.apk')

Write-Output '=== 6/6 sign ==='
$ks = Join-Path $root 'qns.keystore'
if (-not (Test-Path $ks)) {
    & "$jdk\keytool.exe" -genkeypair -keystore $ks -alias qns -storepass:env MINQNS_KEYSTORE_PASSWORD -keypass:env MINQNS_KEYSTORE_PASSWORD `
        -dname "CN=MinQns" -keyalg RSA -keysize 2048 -validity 3650
}
& "$bt\apksigner.bat" sign --ks $ks --ks-key-alias qns --ks-pass env:MINQNS_KEYSTORE_PASSWORD --key-pass env:MINQNS_KEYSTORE_PASSWORD `
    --out (Join-Path $build 'minqns.apk') (Join-Path $build 'minqns-aligned.apk')

Write-Output '=== verify ==='
& "$bt\apksigner.bat" verify --print-certs (Join-Path $build 'minqns.apk')
Get-Item (Join-Path $build 'minqns.apk') | Select-Object FullName,Length,LastWriteTime
