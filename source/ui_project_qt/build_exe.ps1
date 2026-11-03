# Build the portable Windows package into ui_project_qt/output/.
#
# Environment (source distribution does NOT include a venv):
#     py -3.11 -m venv .venv
#     .venv\Scripts\activate
#     python -m pip install -r requirements-build.txt
#
# Run from ui_project_qt:
#     powershell -ExecutionPolicy Bypass -File build_exe.ps1
#     powershell -ExecutionPolicy Bypass -File build_exe.ps1 -Python C:\Python311\python.exe
#
# Output layout:
#     output/
#       J280上位机控制系统.exe
#       runtime/                 PyInstaller runtime (Python/Qt/QtWebEngine)
#       res/                     HTML/CSS/JS/model assets
#       data/config0.json        default parameters (editable)
#       data/ui_state.json       clean initial UI state
#       启动说明.txt
param(
    [string]$Python = ""
)
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 不依赖随源码分发的 venv：优先项目 .venv，找不到则使用 PATH 里的 python
if ([string]::IsNullOrWhiteSpace($Python)) {
    $candidate = Join-Path $Root ".venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $candidate) {
        $Python = $candidate
    }
}
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = "python"
}
$PythonPath = $null
if (Test-Path -LiteralPath $Python) {
    $PythonPath = (Resolve-Path -LiteralPath $Python).Path
} else {
    $cmd = Get-Command $Python -ErrorAction SilentlyContinue
    if ($cmd) { $PythonPath = $cmd.Source }
}
if (-not $PythonPath) {
    throw "未找到可用的 Python：$Python。请先按 README 创建 .venv 并安装依赖。"
}
Write-Host "使用解释器：$PythonPath"
$Python = $PythonPath

$Output = Join-Path $Root "output"
$Work = Join-Path (Split-Path -Parent $Root) "_dev\build\pyinstaller"
$SpecDir = Join-Path (Split-Path -Parent $Root) "_dev\build"
$Name = "J280上位机控制系统"

# 只清理本脚本自己的输出目录，避免误删其它文件
if (Test-Path $Output) {
    Get-ChildItem -LiteralPath $Output -Force | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $Output | Out-Null
}
New-Item -ItemType Directory -Path $Work -Force | Out-Null
New-Item -ItemType Directory -Path $SpecDir -Force | Out-Null

$BuildLog = Join-Path $Work "build.log"
$ErrorActionPreference = "Continue"
& $Python -m PyInstaller `
    --noconfirm --clean --windowed --onedir `
    --name $Name `
    --contents-directory "runtime" `
    --icon (Join-Path $Root "res\icon.ico") `
    --distpath $Output `
    --workpath $Work `
    --specpath $SpecDir `
    (Join-Path $Root "main.py") *> $BuildLog
$BuildCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"
Get-Content -LiteralPath $BuildLog -Tail 20
if ($BuildCode -ne 0) {
    throw "PyInstaller 构建失败，退出码 $BuildCode（日志：$BuildLog）"
}

# PyInstaller onedir 默认输出 output/<Name>/，把 exe 与 runtime 提到 output 根目录
$Bundle = Join-Path $Output $Name
if (Test-Path -LiteralPath $Bundle) {
    Get-ChildItem -LiteralPath $Bundle -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $Output -Force
    }
    Remove-Item -LiteralPath $Bundle -Recurse -Force
}

# 外部资源目录：便于替换 HTML/参数，不塞进 runtime
Copy-Item -LiteralPath (Join-Path $Root "res") -Destination (Join-Path $Output "res") -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $Output "data") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Root "data\config0.json") -Destination (Join-Path $Output "data\config0.json") -Force
@'
{
  "ui_version": 3,
  "port": "COM9",
  "plot_window": "10 秒",
  "display_mode": "趋势",
  "trend_ms": "40 ms",
  "cards": {}
}
'@ | Set-Content -LiteralPath (Join-Path $Output "data\ui_state.json") -Encoding UTF8

$readme = @"
J280 上位机控制系统 — 便携版

启动：双击 J280上位机控制系统.exe

目录说明：
  J280上位机控制系统.exe   主程序
  runtime\                 Python / Qt / QtWebEngine 运行时，请勿删除或改名
  res\                     HTML / CSS / JS / three.js，可整体替换
  data\config0.json        默认参数（GUI 启动与 FPGA 上电默认一致），可编辑
  data\ui_state.json       上次端口/曲线/卡片布局；删除可恢复默认布局

注意：
  - 需要 Windows 10/11 x64，建议 1600x1000 或 1280x800 以上分辨率；
  - 串口 115200 8N1；无硬件时界面可正常打开；
  - 通信异常时请使用实体急停，软件按钮不能替代硬件保护；
  - 自检（无界面验证）：
      J280上位机控制系统.exe --selftest selftest.json --selftest-shot selftest.png
"@
Set-Content -LiteralPath (Join-Path $Output "启动说明.txt") -Value $readme -Encoding UTF8

Write-Host ""
Write-Host "构建完成：$Output"
Get-ChildItem -LiteralPath $Output -Force | Select-Object Name, Mode, Length | Format-Table -AutoSize
