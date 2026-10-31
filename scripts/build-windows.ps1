# 构建 Windows x64 桌面安装包与免安装 ZIP，必须提供真实网关。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GatewaySource,
    [string]$OutputDir = "dist-single"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
if (-not $IsWindows) { throw "请在 Windows PowerShell 7 上构建安装包" }
$gateway = (Resolve-Path $GatewaySource).Path
$out = [IO.Path]::GetFullPath((Join-Path $root $OutputDir))
if ($out -eq $root -or $out -eq (Join-Path $root "dist") -or
    $out.StartsWith((Join-Path $root "dist") + [IO.Path]::DirectorySeparatorChar)) {
    throw "输出目录不能是仓库根或 dist 前端资源目录"
}
if ((Get-Item $gateway).Length -le 1MB) { throw "网关文件过小，无法被核心构建脚本内嵌" }
$previousGateway = $env:WB_SWITCH_GATEWAY_BIN
Push-Location $root
try {
    $env:WB_SWITCH_GATEWAY_BIN = $gateway
    npm ci --registry=https://registry.npmjs.org --replace-registry-host=always --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm ci 失败" }
    # 无 updater 私钥也能生成普通安装包；不生成未经正确签名的更新产物。
    $releaseConfig = Join-Path $root "src-tauri/tauri.release.conf.json"
    npm run tauri -- build --ci --bundles nsis,msi --config $releaseConfig -- --locked
    if ($LASTEXITCODE -ne 0) { throw "Tauri 安装包构建失败" }
    $version = (Get-Content package.json -Raw | ConvertFrom-Json).version
    $prefix = "WorkBuddy_Switch_Gateway_${version}_x64"
    $portable = Join-Path $out "${prefix}_portable"
    New-Item -ItemType Directory -Force $out | Out-Null
    if (Test-Path $portable) { Remove-Item -Recurse -Force $portable }
    New-Item -ItemType Directory $portable | Out-Null
    Copy-Item target/release/wb-switch-rust.exe (Join-Path $portable "WorkBuddy-Switch-Gateway.exe")
    Copy-Item src-tauri/WebView2Loader.dll $portable
    @"
双击 WorkBuddy-Switch-Gateway.exe 启动；Go 网关已内嵌。
需要 Microsoft Edge WebView2 Runtime（安装包会引导安装，免安装版需自行安装）。
这是免安装版；账号和配置仍保存在用户目录 ~/.wb-switch，并非目录隔离模式。
"@ | Set-Content (Join-Path $portable "使用说明.txt") -Encoding utf8
    Compress-Archive -Path "$portable/*" -DestinationPath (Join-Path $out "${prefix}_portable.zip") -Force
    $nsis = @(Get-ChildItem target/release/bundle/nsis/*-setup.exe)
    $msi = @(Get-ChildItem target/release/bundle/msi/*.msi)
    if ($nsis.Count -ne 1 -or $msi.Count -ne 1) { throw "预期各生成一个 NSIS 和 MSI 安装包" }
    Copy-Item $nsis[0].FullName (Join-Path $out "${prefix}-setup.exe")
    Copy-Item $msi[0].FullName (Join-Path $out "${prefix}.msi")
    $names = @("${prefix}-setup.exe", "${prefix}.msi", "${prefix}_portable.zip")
    $lines = foreach ($name in $names) {
        $hash = (Get-FileHash (Join-Path $out $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    $lines | Set-Content (Join-Path $out "SHA256SUMS.txt") -Encoding ascii
    Write-Host "安装包、免安装 ZIP 和 SHA256SUMS.txt 已生成到 $out"
} finally {
    $env:WB_SWITCH_GATEWAY_BIN = $previousGateway
    Pop-Location
}
