## -------------------------------------------------------------------------
## sqmSQLTool Debug & Validation Script
## -------------------------------------------------------------------------

$moduleRoot = $PSScriptRoot
$publicFolder = Join-Path $moduleRoot "Public"

Write-Host "--- Validiere sqmSQLTool Public Functions ---" -ForegroundColor Cyan

if (-not (Test-Path $publicFolder))
{
	Write-Error "Ordner 'Public' nicht gefunden!"
	return
}

$files = Get-ChildItem -Path $publicFolder -Filter *.ps1

foreach ($file in $files)
{
	# 1. Check: Praefix im Dateinamen
	if ($file.BaseName -notlike "sqm*")
	{
		Write-Host "[FEHLER] Dateiname '$($file.Name)' fehlt das 'sqm'-Praefix." -ForegroundColor Red
		continue
	}
	
	# 2. Check: Inhalt parsen (Funktionsname extrahieren)
	try
	{
		$ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-Content $file.FullName -Raw), [ref]$null, [ref]$null)
		$functionDef = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
		
		if ($null -eq $functionDef)
		{
			Write-Host "[WARNUNG] Keine Funktion in '$($file.Name)' gefunden." -ForegroundColor Yellow
		}
		else
		{
			foreach ($func in $functionDef)
			{
				$funcName = $func.Name
				
				# Pruefen, ob Dateiname == Funktionsname
				if ($funcName -ne $file.BaseName)
				{
					Write-Host "[FEHLER] Dateiname '$($file.BaseName)' passt nicht zu Funktionsname '$funcName'!" -ForegroundColor Red
				}
				else
				{
					Write-Host "[OK] $funcName" -ForegroundColor Green
				}
			}
		}
	}
	catch
	{
		Write-Host "[FEHLER] Konnte Datei '$($file.Name)' nicht parsen." -ForegroundColor Red
	}
}

Write-Host "`n--- Validierung abgeschlossen ---" -ForegroundColor Cyan