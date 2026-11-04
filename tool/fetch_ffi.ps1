<#
Fetch libbdl_ffi.so for Android ABIs from the bdl fork's rolling "ffi" release,
verify against SHA256SUMS, and place them under android/app/src/main/jniLibs/<abi>/.
Run from the Flutter project root.
#>
param(
  [string]$Repo = "42419/bdl",
  [string]$Dest = "android/app/src/main/jniLibs"
)
$ErrorActionPreference = 'Stop'
$base = "https://github.com/$Repo/releases/download/ffi"
$abis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')
$sumsPath = Join-Path $env:TEMP ('bdffi-SHA256SUMS-' + [guid]::NewGuid() + '.txt')
Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sumsPath -UseBasicParsing
$sums = @{}
foreach ($line in Get-Content $sumsPath) {
  if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$') {
    $sums[($matches[2] -split '/')[-1]] = $matches[1].ToLower()
  }
}
foreach ($abi in $abis) {
  $asset = "libbdl_ffi-$abi.so"
  $outDir = Join-Path $Dest $abi
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $out = Join-Path $outDir 'libbdl_ffi.so'
  Invoke-WebRequest -Uri "$base/$asset" -OutFile $out -UseBasicParsing
  $hash = (Get-FileHash -Algorithm SHA256 -Path $out).Hash.ToLower()
  if ($sums[$asset] -and $sums[$asset] -ne $hash) { throw "SHA256 mismatch for $asset" }
  Write-Host ("ok  {0} -> {1}" -f $asset, $out)
}
