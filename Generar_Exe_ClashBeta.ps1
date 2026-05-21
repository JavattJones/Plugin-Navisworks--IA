# ============================================================
# Genera Instalar_ClashAI_Beta.exe desde el PS1 de la Beta
# El EXE lleva el instalador embebido: solo hay que hacer doble clic
# Ejecutar en el mismo directorio que Instalar_Plugin_ClashBeta.ps1
# ============================================================

$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$ps1Path   = Join-Path $scriptDir "Instalar_Plugin_ClashBeta.ps1"
$exePath   = Join-Path $scriptDir "Instalar_ClashAI_Beta.exe"

if (-not (Test-Path $ps1Path)) {
    Write-Host "ERROR: No se encuentra Instalar_Plugin_ClashBeta.ps1" -ForegroundColor Red
    Write-Host "       Ejecuta este script desde la misma carpeta."
    Read-Host "Pulse Enter para salir"; exit 1
}

# -------------------------------------------------------
# Leer, comprimir y codificar el PS1
# -------------------------------------------------------
Write-Host "[1/3] Leyendo y comprimiendo el instalador..."
$ps1Bytes = [System.IO.File]::ReadAllBytes($ps1Path)

$msOut = New-Object System.IO.MemoryStream
$gz    = New-Object System.IO.Compression.GZipStream($msOut, [System.IO.Compression.CompressionMode]::Compress)
$gz.Write($ps1Bytes, 0, $ps1Bytes.Length)
$gz.Close()
$compressed = $msOut.ToArray()
$b64        = [Convert]::ToBase64String($compressed)

$origKB  = [math]::Round($ps1Bytes.Length   / 1KB, 1)
$compKB  = [math]::Round($compressed.Length / 1KB, 1)
$b64Len  = $b64.Length
Write-Host "      Original: $origKB KB  ->  Comprimido: $compKB KB  ->  Base64: $b64Len chars"

if ($b64Len -gt 65000) {
    Write-Host "AVISO: Base64 supera 65000 chars. Contacta con el desarrollador." -ForegroundColor Yellow
}

# -------------------------------------------------------
# Codigo C# del launcher (embebe el PS1 comprimido)
# -------------------------------------------------------
Write-Host "[2/3] Generando y compilando launcher..."
$csharp = @"
using System;
using System.IO;
using System.IO.Compression;
using System.Diagnostics;

class ClashAIBetaInstaller
{
    static int Main(string[] args)
    {
        const string B64 = "$b64";

        // Descomprimir GZip -> bytes del PS1 original
        byte[] compressed = Convert.FromBase64String(B64);
        byte[] script;
        using (var ms  = new MemoryStream(compressed))
        using (var gz  = new GZipStream(ms, CompressionMode.Decompress))
        using (var buf = new MemoryStream())
        {
            gz.CopyTo(buf);
            script = buf.ToArray();
        }

        // Escribir PS1 en carpeta temporal y ejecutar
        string tmp = Path.Combine(Path.GetTempPath(),
            "ClashAIBeta_" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
        File.WriteAllBytes(tmp, script);
        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + tmp + "\"")
            { UseShellExecute = false };
            var proc = Process.Start(psi);
            proc.WaitForExit();
            return proc.ExitCode;
        }
        finally { try { File.Delete(tmp); } catch {} }
    }
}
"@

# -------------------------------------------------------
# Compilar con csc.exe del .NET Framework
# -------------------------------------------------------
$fxDir  = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$csc    = Join-Path $fxDir "csc.exe"

if (-not (Test-Path $csc)) {
    Write-Host "ERROR: No se encuentra csc.exe en:" -ForegroundColor Red
    Write-Host "       $fxDir"
    Read-Host "Pulse Enter para salir"; exit 1
}

$csTemp = Join-Path $env:TEMP ("ClashAILauncher_" + [Guid]::NewGuid().ToString("N").Substring(0,8) + ".cs")
[System.IO.File]::WriteAllText($csTemp, $csharp, [System.Text.Encoding]::UTF8)

if (Test-Path $exePath) { Remove-Item $exePath -Force }
$result = & $csc /nologo /target:exe /optimize+ "/out:$exePath" "$csTemp" 2>&1
Remove-Item $csTemp -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exePath)) {
    Write-Host "ERROR compilando el EXE:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Read-Host "Pulse Enter para salir"; exit 1
}

$exeKB = [math]::Round((Get-Item $exePath).Length / 1KB, 1)

Write-Host "[3/3] EXE generado correctamente"
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " LISTO: Instalar_ClashAI_Beta.exe ($exeKB KB)" -ForegroundColor Green
Write-Host "============================================"
Write-Host ""
Write-Host " Ubicacion: $exePath"
Write-Host ""
Write-Host " Instrucciones para tus companeros:"
Write-Host "   1. Copiar el EXE en cualquier carpeta"
Write-Host "   2. Doble clic para instalar"
Write-Host "   3. Reiniciar Navisworks"
Write-Host "   4. Pestana [ClashAI Beta] -> Agrupar clashes"
Write-Host ""
Read-Host "Pulse Enter para salir"
