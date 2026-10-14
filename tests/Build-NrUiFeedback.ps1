param(
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$C0RepairRoot
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
$root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
$allowed = Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'
if (!$root.StartsWith($allowed + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Product outputs must remain under current task-owned evidence'
}
$out = Join-Path $root 'p'
if (Test-Path -LiteralPath $out) { throw 'Refuse to overwrite an existing product attempt' }
New-Item -ItemType Directory -Path "$out/o","$out/bin" | Out-Null
$env:TEMP = Join-Path $root 'tmp'
$env:TMP = $env:TEMP
$env:VSCMD_SKIP_SENDTELEMETRY = '1'
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
$vc = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207'
$compiler = "$vc/bin/Hostx86/x64/cl.exe"
$linker = "$vc/bin/Hostx86/x64/link.exe"
$rc = 'C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/rc.exe'
$env:PATH = (Split-Path $rc) + ';' + (Split-Path $linker) + ';' + $env:PATH
$oldRepo = 'C:/omo-research/optiscaler-nr-present-addon-options-wt-wave-c'
$c0 = (Resolve-Path -LiteralPath $C0RepairRoot).Path
$expected = @{
    'Build-Mfg-2.ps1'='D3AD5C7B04668300735497A013E8E6BADE384CA81D93172E1C45846F9CC3A5FC'
    'mfg-2/obj/compile.rsp'='20575E847ABAD6760D0EF85F8E40E542E219160506365BAEA9A303A989DFA6FF'
    'mfg-2/obj/link.rsp'='349D0AF559C73E2A67CB41E52E3E1161146C9CA7467D89AF65CCF4F2F0793E30'
}
foreach ($relative in $expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $c0 $relative)).Hash -ne $expected[$relative]) {
        throw "C0 recipe drift: $relative"
    }
}
function BindFile([string]$Path) {
    [ordered]@{path=[IO.Path]::GetFullPath($Path);bytes=(Get-Item -LiteralPath $Path).Length;
        sha256=(Get-FileHash -LiteralPath $Path).Hash}
}
$recipe = Get-Content -LiteralPath "$c0/Build-Mfg-2.ps1" -Raw
foreach ($variable in @('INCLUDE','LIB')) {
    $match = [regex]::Match($recipe, '\$env:' + $variable + " = '([^']+)'")
    if (!$match.Success) { throw "Exact C0 environment missing: $variable" }
    $value = $match.Groups[1].Value.Replace($oldRepo, $repo.Replace('\','/'))
    [Environment]::SetEnvironmentVariable($variable, $value, 'Process')
}
$env:INCLUDE = "$root/m;" + $env:INCLUDE
$project = Join-Path $repo 'OptiScaler/OptiScaler.vcxproj'
[xml]$xml = Get-Content -LiteralPath $project -Raw
$ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
$ns.AddNamespace('p', $xml.DocumentElement.NamespaceURI)
$sources = @($xml.SelectNodes('/p:Project/p:ItemGroup/p:ClCompile[@Include]', $ns) | Where-Object {
    $_.ParentNode.Condition -ne "'`$(OptiScalerNrSelfTest)'=='true'"
} | ForEach-Object {
    [ordered]@{source=[IO.Path]::GetFullPath((Join-Path "$repo/OptiScaler" $_.Include));
        stem=[IO.Path]::GetFileNameWithoutExtension($_.Include);
        pch=$(if($_.Include -ieq 'pch.cpp'){'Create'}elseif($_.OuterXml -match 'NotUsing'){'NotUsing'}else{'Use'})}
})
if ($sources.Count -ne 232 -or @($sources.stem | Sort-Object -Unique).Count -ne 232) {
    throw 'Exact ordinary C0/current source closure changed'
}
$compileTemplate = Get-Content -LiteralPath "$c0/mfg-2/obj/compile.rsp" -Raw
if ($compileTemplate -notmatch '(?:^|\s)/MD(?:\s|$)' -or
    $compileTemplate -match 'OPTISCALER_NR_SELF_TEST' -or
    $compileTemplate -notmatch 'OPTISCALER_RTX40_MFG') { throw 'Ordinary MFG compiler recipe mismatch' }
$base = [regex]::Replace($compileTemplate, '\s+/sourceDependencies\s+"[^"]+"\s+"[^"]+"\s*$', '')
$base = [regex]::Replace($base, '\s+/(?:Yu|Fp|Fo|Fd)"[^"]+"', '')
$pch = "$out/o/OptiScaler.pch"
$pdb = "$out/o/VC143.pdb"
$linkTemplate = Get-Content -LiteralPath "$c0/mfg-2/obj/link.rsp" -Raw
$tokens = @([regex]::Matches($linkTemplate, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value })
$oldObjects = @($tokens | Where-Object { $_ -match '(?i)\.obj"?$' })
$oldStems = @($oldObjects | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Trim('"')) })
if (@(Compare-Object $sources.stem $oldStems).Count) { throw 'C0 link object set differs from current ordinary project' }
$pins = @($sources | ForEach-Object { BindFile $_.source })
$inputs = [ordered]@{schema=1;kind='limitedCpuOrdinaryBuildInputs';project=(BindFile $project);
    compiler=(BindFile $compiler);linker=(BindFile $linker);resourceCompiler=(BindFile $rc);
    recipes=@($expected.Keys | ForEach-Object { BindFile (Join-Path $c0 $_) });
    metadata=@(BindFile "$root/m/resource_build_commit.h";BindFile "$root/m/resource_build_date.h");
    sourceUnits=$pins;include=$env:INCLUDE;lib=$env:LIB;hooksExecuted=$false;historicalObjectsReused=0}
$inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$out/inputs.json" -Encoding UTF8
$commands = @()
$compileExit = $null
$resourceExit = $null
$linkExit = $null
Start-Transcript -LiteralPath "$root/product-build.log" | Out-Null
Push-Location "$repo/OptiScaler"
try {
    foreach ($unit in @($sources | Where-Object {$_.pch -eq 'Create'}) + @($sources | Where-Object {$_.pch -ne 'Create'})) {
        $object = "$out/o/$($unit.stem).obj"
        $dependencies = "$out/o/$($unit.stem).j"
        $response = "$out/o/$($unit.stem).rsp"
        $pchFlag = if ($unit.pch -eq 'Create') { '/Yc"pch.h"' } elseif ($unit.pch -eq 'Use') { '/Yu"pch.h"' } else { '' }
        $args = $base + " $pchFlag /Fp`"$pch`" /Fo`"$object`" /Fd`"$pdb`" /sourceDependencies `"$dependencies`" `"$($unit.source)`""
        [IO.File]::WriteAllText($response, $args + [Environment]::NewLine, [Text.Encoding]::ASCII)
        Write-Host "PRODUCT_COMPILE=$($unit.source)"
        & $compiler "@$response"
        $compileExit = $LASTEXITCODE
        $commands += [ordered]@{kind='compile';source=$unit.source;object=$object;dependencies=$dependencies;
            response=$response;responseSha256=(Get-FileHash -LiteralPath $response).Hash;
            exe=$compiler;arguments="@`"$response`"";nativeExit=$compileExit;pch=$unit.pch}
        $commands | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/commands.json" -Encoding UTF8
        Write-Host "PRODUCT_COMPILE_EXIT=$compileExit source=$($unit.stem)"
        if ($compileExit -ne 0) { throw "Native compiler failed: $($unit.source): $compileExit" }
    }
    foreach ($pin in $pins) {
        if ((Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.sha256) { throw "Source drift during build: $($pin.path)" }
    }
    $resource = "$out/o/OptiScaler.res"
    & $rc /nologo /d OPTISCALER_BUILD_METADATA /l 0x0409 /fo $resource "$repo/OptiScaler/OptiScaler.rc"
    $resourceExit = $LASTEXITCODE
    Write-Host "PRODUCT_RESOURCE_EXIT=$resourceExit"
    if ($resourceExit -ne 0) { throw "Native resource compiler failed: $resourceExit" }
    $newTokens = @($tokens | ForEach-Object {
        $token = $_
        if ($token -match '(?i)\.obj"?$') {
            '"' + "$out/o/$([IO.Path]::GetFileNameWithoutExtension($token.Trim('"'))).obj" + '"'
        } elseif ($token -match '(?i)\.res"?$') {
            '"' + $resource + '"'
        } elseif ($token -match '(?i)^/(OUT|PDB|LTCGOUT|IMPLIB):') {
            $option = $matches[1]
            $extension = switch ($option.ToUpperInvariant()) { 'OUT' {'.dll'} 'PDB' {'.pdb'} 'LTCGOUT' {'.iobj'} 'IMPLIB' {'.lib'} }
            '/' + $option + ':"' + "$out/bin/OptiScaler$extension" + '"'
        } else { $token }
    })
    $linkResponse = "$out/link.rsp"
    [IO.File]::WriteAllText($linkResponse, ($newTokens -join ' ') + ' /VERBOSE:LIB' + [Environment]::NewLine, [Text.Encoding]::ASCII)
    & $linker "@$linkResponse"
    $linkExit = $LASTEXITCODE
    $commands += [ordered]@{kind='link';exe=$linker;arguments="@`"$linkResponse`"";
        response=$linkResponse;responseSha256=(Get-FileHash -LiteralPath $linkResponse).Hash;nativeExit=$linkExit}
    $commands | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/commands.json" -Encoding UTF8
    Write-Host "PRODUCT_LINK_EXIT=$linkExit"
    if ($linkExit -ne 0) { throw "Native linker failed: $linkExit" }
    [ordered]@{schema=1;compileExit=$compileExit;compileCommands=$sources.Count;resourceExit=$resourceExit;
        linkExit=$linkExit;candidate=(BindFile "$out/bin/OptiScaler.dll");pch=(BindFile $pch);pdb=(BindFile $pdb);
        hooksExecuted=$false;payloadLaunched=$false;historicalObjectsReused=0} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
} catch {
    [ordered]@{schema=1;failure=$_.Exception.Message;compileExit=$compileExit;resourceExit=$resourceExit;
        linkExit=$linkExit;completedCommands=$commands.Count;payloadLaunched=$false} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/failure.json" -Encoding UTF8
    throw
} finally { Pop-Location; Stop-Transcript | Out-Null }
