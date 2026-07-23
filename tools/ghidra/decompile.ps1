# Headless-decompile the IW2 engine binaries with Ghidra.
#   powershell -File tools/ghidra/decompile.ps1 iwar2.dll flux.dll ...
# Output: data/decomp/<name>.c  +  <name>.symbols.txt   (gitignored: derived
# from the user's own game install, like every other extracted asset)
param([string[]]$Binaries = @("iwar2.dll"))

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$game = "C:\Program Files (x86)\GOG Galaxy\Games\Independence War 2"
$ghidra = Join-Path $root "build\ghidra\ghidra_12.1.2_PUBLIC"
$jdk = (Get-ChildItem "C:\Program Files\Microsoft\jdk-21*" -Directory |
        Select-Object -First 1).FullName
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"

$proj = Join-Path $root "build\ghidra-proj"
$out = Join-Path $root "data\decomp"
# The knowledge layer (per-binary function/name/type maps that make each pass
# strictly better) is versioned in its OWN repo, never in iw2-remaster -- it is
# a map of the copyrighted binary. Clone/keep it here; the export no-ops without
# it. See docs/decompile.md and build\ghidra-knowledge\README.md.
$know = Join-Path $root "build\ghidra-knowledge"
# Ghidra's launcher .bat breaks on paths containing parentheses, and the GOG
# install lives under "Program Files (x86)" — stage the binaries somewhere clean
$stage = Join-Path $root "build\bin"
New-Item -ItemType Directory -Force $proj, $out, $stage | Out-Null

foreach ($b in $Binaries) {
    $path = if (Test-Path $b) { $b }
            elseif (Test-Path "$game\$b") { "$game\$b" }
            else { "$game\bin\release\$b" }
    if (-not (Test-Path $path)) { Write-Host "MISSING: $b"; continue }
    $staged = Join-Path $stage (Split-Path -Leaf $path)
    Copy-Item $path $staged -Force
    Write-Host "=== $b ==="
    & "$ghidra\support\analyzeHeadless.bat" $proj iw2 `
        -import $staged -overwrite `
        -scriptPath (Join-Path $root "tools\ghidra") `
        -postScript ExportDecomp.java $out $know 2>&1 |
        Select-String "DONE|decompiled |ERROR |Exception" |
        Select-Object -Last 6
}
Get-ChildItem $out | Select-Object Name, Length
