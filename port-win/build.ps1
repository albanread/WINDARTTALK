# WINDART build driver (arch-parameterised — WINDARTARM AS1).
#
# Activates the matching MSVC toolchain (vcvars64 / vcvarsarm64), configures the
# CMake project with Ninja, and builds it — teeing all output to the build dir's
# build.log. Paths are repo-relative (no drive pins): with the repo cloned at
# <workroot>\WINDARTTALK, the build lands in <workroot>\build-<arch> and the
# extracted tree is expected at <workroot>\tree (see extract.py).
#
# Usage (from any normal PowerShell):
#   powershell -ExecutionPolicy Bypass -File ...\port-win\build.ps1                 # host arch
#   ...\build.ps1 -Arch arm64 -Clean       # wipe the arch's build dir first
#   ...\build.ps1 -Arch x64 -Target dart   # cross-arch dirs coexist side by side
#
# cl.exe is only on PATH after vcvars, so cmake+ninja run INSIDE the same
# `cmd /c` that sources vcvars (the env does not survive back to PowerShell).
# cmake/ninja themselves are addressed by FULL PATH (the VS-bundled copies), so
# the build does not depend on what vcvars adds to PATH.
[CmdletBinding()]
param(
  [ValidateSet('arm64', 'x64')]
  [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
  [switch]$Clean,
  [string]$Target = "",
  [string]$Config = "Debug",
  [string]$Tree = ""     # override -DWINDART_TREE (default: <workroot>\tree)
)

$ErrorActionPreference = "Stop"

$SrcDir   = $PSScriptRoot                          # ...\WINDARTTALK\port-win
$RepoRoot = Split-Path -Parent $SrcDir             # ...\WINDARTTALK
$WorkRoot = Split-Path -Parent $RepoRoot           # e.g. C:\projects\WINDARTARM
$BuildDir = Join-Path $WorkRoot "build-$Arch"
$LogFile  = Join-Path $BuildDir "build.log"

$VsRoot = "C:\Program Files\Microsoft Visual Studio\18\Professional"
# Pick the host_target vcvars. On an arm64 host, targeting x64 uses the NATIVE
# arm64 cross tools (vcvarsarm64_amd64) rather than running the x64 toolchain
# under emulation — same output, far faster. The resulting x64 binaries then run
# under WoA's x64 emulation, which is exactly what makes the x64 build usable
# here as a CONTROL for arm64-specific behaviour.
$HostIsArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')
$VcVars = switch ("$Arch/$HostIsArm") {
  'arm64/True'  { "$VsRoot\VC\Auxiliary\Build\vcvarsarm64.bat" }
  'arm64/False' { "$VsRoot\VC\Auxiliary\Build\vcvarsamd64_arm64.bat" }
  'x64/True'    { "$VsRoot\VC\Auxiliary\Build\vcvarsarm64_amd64.bat" }
  default       { "$VsRoot\VC\Auxiliary\Build\vcvars64.bat" }
}
$CMakeExe = "$VsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$NinjaExe = "$VsRoot\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"

foreach ($p in @($VcVars, $CMakeExe, $NinjaExe)) {
  if (-not (Test-Path $p)) { throw "not found: $p" }
}

if ($Clean -and (Test-Path $BuildDir)) {
  Write-Host "build.ps1: cleaning $BuildDir"
  Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# Build the ninja target argument (empty = default = all).
$NinjaTarget = ""
if ($Target -ne "") { $NinjaTarget = " $Target" }

$TreeArg = ""
if ($Tree -ne "") { $TreeArg = " -DWINDART_TREE=`"$Tree`"" }

# One cmd invocation: vcvars -> cmake configure -> ninja build, chained with
# `&&` so a failed step aborts the rest. MUST be a SINGLE-LINE command string
# (cmd misparses PS-mangled multi-line strings). `-k 0` keeps ninja going after
# an error so a failing build yields a full burn-down list.
$Inner = "call `"$VcVars`" && " +
         "`"$CMakeExe`" -G Ninja -S `"$SrcDir`" -B `"$BuildDir`" " +
         "-DCMAKE_BUILD_TYPE=$Config -DCMAKE_MAKE_PROGRAM=`"$NinjaExe`" " +
         "-DWINDART_ARCH=$Arch$TreeArg && " +
         "`"$NinjaExe`" -C `"$BuildDir`" -k 0$NinjaTarget"

# Redirect the WHOLE chain to the log INSIDE cmd (parenthesized group): cmd's
# `>` writes ANSI (grep-able), and all native stderr stays out of PowerShell's
# NativeCommandError promotion. $LASTEXITCODE is then ninja's real exit code.
$Full = "( $Inner ) > `"$LogFile`" 2>&1"

Write-Host "build.ps1: [$Arch/$Config] configuring + building -> $LogFile"
$ErrorActionPreference = "Continue"
& cmd /c $Full
$rc = $LASTEXITCODE
if (Test-Path $LogFile) { Get-Content -Path $LogFile -Tail 30 }

Write-Host "build.ps1: exit code $rc (full log: $LogFile)"
exit $rc
