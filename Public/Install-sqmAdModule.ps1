<#
.SYNOPSIS
    Stellt sicher dass das ActiveDirectory PowerShell-Modul (RSAT) installiert ist.

.DESCRIPTION
    Prueft zunaechst ob das ActiveDirectory-Modul bereits verfuegbar ist.
    Ist das nicht der Fall, versucht die Funktion die Installation ueber vier
    Methoden in folgender Reihenfolge (Fallback-Kette):

        1. Windows Capability  (Add-WindowsCapability)
           Ziel: Windows 10/11 Clients und Windows Server 2019+
           Paket: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        2. Windows Feature  (Install-WindowsFeature)
           Ziel: Windows Server (alle Versionen mit ServerManager)
           Feature: RSAT-AD-PowerShell

        3. DISM  (dism.exe /Online /Add-Capability)
           Ziel: aeltere Systeme oder Umgebungen ohne ServerManager/PS-Cmdlets
           Capability: Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

        4. PSGallery  (Install-Module ActiveDirectory)
           Ziel: Systeme mit Internetzugang und PSGallery-Zugriff, wenn alle
                 anderen Methoden nicht verfuegbar oder fehlgeschlagen sind.
           Scope: zunaechst CurrentUser, dann AllUsers.
           Voraussetzung: NuGet-Provider ? 2.8.5.201 (wird automatisch
           installiert falls fehlend).

    Jede Methode wird nur versucht, wenn die zustaendigen Cmdlets bzw.
    das Tool auf dem System vorhanden sind. Schlaegt eine Methode fehl,
    wird mit der naechsten fortgefahren.

    Nach erfolgreicher Installation wird Import-Module ActiveDirectory
    ausgefuehrt um das Modul in die aktuelle Session zu laden.

    Hinweis zur Berechtigung:
        Alle Installationsmethoden erfordern lokale Administratorrechte.
        Die Funktion prueft dies vorab und gibt einen sprechenden Fehler zurueck.

.PARAMETER SkipIfPresent
    Wenn $true (Standard) und das Modul bereits vorhanden ist, wird sofort
    $true zurueckgegeben ohne Installationsversuch.
    Auf $false setzen um einen Re-Import zu erzwingen.

.PARAMETER ContinueOnError
    Wenn gesetzt, gibt die Funktion bei fehlgeschlagener Installation $false
    zurueck statt einen Fehler auszuloesen.

.PARAMETER EnableException
    Wenn gesetzt, wirft die Funktion bei fehlgeschlagener Installation
    eine Ausnahme (ueberschreibt ContinueOnError).

.PARAMETER WhatIf
    Zeigt welche Installationsmethode versucht wuerde, ohne sie auszufuehren.

.PARAMETER Confirm
    Fordert vor der Installation eine Bestaetigung an.

.OUTPUTS
    [bool] - $true wenn das Modul am Ende verfuegbar und geladen ist,
             $false wenn Installation fehlgeschlagen und ContinueOnError gesetzt.

.EXAMPLE
    Install-sqmAdModule

    Prueft ob das AD-Modul vorhanden ist und installiert es falls noetig.

.EXAMPLE
    Install-sqmAdModule -ContinueOnError

    Gibt $false zurueck wenn Installation scheitert, statt eine Ausnahme zu werfen.

.EXAMPLE
    if (-not (Install-sqmAdModule -ContinueOnError))
    {
        Write-Warning "AD-Modul nicht verfuegbar - AD-Pruefung wird uebersprungen."
    }

.NOTES
    Voraussetzungen : Invoke-sqmLogging, lokale Administratorrechte
    Getestete Systeme: Windows 10/11, Windows Server 2016/2019/2022
    DISM-Fallback   : Benoetigt Internetzugang oder WSUS/SCCM-Quelle
                      (Windows Update muss erreichbar sein).
    PSGallery       : Benoetigt Internetzugang und Zugriff auf gallery.powershellgallery.com.
                      NuGet-Provider wird automatisch installiert falls fehlend.
                      In abgeschotteten Umgebungen schlaegt diese Methode erwartungsgemaess fehl.
    Neustart        : Keine der Methoden erfordert einen Neustart.
#>
function Install-sqmAdModule
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([bool])]
	param (
		[Parameter(Mandatory = $false)]
		[bool]$SkipIfPresent = $true,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$adCapabilityName = 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
		$adFeatureName = 'RSAT-AD-PowerShell'
		
		# Hilfsfunktion: strukturierter Fehlerrueckgabe
		function _Fail
		{
			param ([string]$Message)
			Invoke-sqmLogging -Message $Message -FunctionName $functionName -Level 'ERROR'
			if ($EnableException) { throw $Message }
			Write-Warning $Message
			return $false
		}
	}
	
	process
	{
		# ?? 1. Bereits vorhanden? ?????????????????????????????????????????????
		$alreadyAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
		
		if ($alreadyAvailable -and $SkipIfPresent)
		{
			Invoke-sqmLogging -Message "ActiveDirectory-Modul bereits vorhanden - kein Installationsversuch." `
							  -FunctionName $functionName -Level 'INFO'
			Import-Module ActiveDirectory -ErrorAction SilentlyContinue
			return $true
		}
		
		# ?? 2. Administratorrechte pruefen ?????????????????????????????????????
		$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
		$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
		
		if (-not $isAdmin)
		{
			return (_Fail "Keine lokalen Administratorrechte - RSAT-Installation nicht moeglich. Starte PowerShell als Administrator.")
		}
		
		Invoke-sqmLogging -Message "ActiveDirectory-Modul nicht gefunden - starte Installationsversuch." `
						  -FunctionName $functionName -Level 'INFO'
		
		$installed = $false
		
		# ??????????????????????????????????????????????????????????????????????
		# Methode 1: Windows Capability (Add-WindowsCapability)
		#            Windows 10/11 Clients und Windows Server 2019+
		# ??????????????????????????????????????????????????????????????????????
		$hasCapabilityCmd = [bool](Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue)
		
		if (-not $installed -and $hasCapabilityCmd)
		{
			$action = "RSAT AD-Modul via Add-WindowsCapability installieren ($adCapabilityName)"
			if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action))
			{
				try
				{
					Invoke-sqmLogging -Message "Methode 1 (Capability): $action" `
									  -FunctionName $functionName -Level 'INFO'
					
					# Pruefen ob Capability bereits im Installed-State ist
					$capState = Get-WindowsCapability -Online -Name $adCapabilityName -ErrorAction Stop
					
					if ($capState.State -eq 'Installed')
					{
						Invoke-sqmLogging -Message "Methode 1: Capability bereits installiert - nur Import." `
										  -FunctionName $functionName -Level 'INFO'
						$installed = $true
					}
					else
					{
						$capResult = Add-WindowsCapability -Online -Name $adCapabilityName -ErrorAction Stop
						if ($capResult.RestartNeeded -eq $false -or $null -eq $capResult.RestartNeeded)
						{
							Invoke-sqmLogging -Message "Methode 1 (Capability): Erfolgreich installiert." `
											  -FunctionName $functionName -Level 'INFO'
							$installed = $true
						}
						else
						{
							Invoke-sqmLogging -Message "Methode 1 (Capability): Installiert, aber Neustart empfohlen." `
											  -FunctionName $functionName -Level 'WARNING'
							Write-Warning "RSAT-Installation abgeschlossen, aber ein Neustart wird empfohlen."
							$installed = $true
						}
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Methode 1 (Capability) fehlgeschlagen: $($_.Exception.Message) - versuche Methode 2." `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}
			else
			{
				Invoke-sqmLogging -Message "WhatIf: Methode 1 (Capability) wuerde ausgefuehrt." `
								  -FunctionName $functionName -Level 'VERBOSE'
				return $true # WhatIf ? so tun als ob erfolgreich
			}
		}
		else
		{
			if (-not $hasCapabilityCmd)
			{
				Invoke-sqmLogging -Message "Methode 1 (Capability): Add-WindowsCapability nicht verfuegbar - uebersprungen." `
								  -FunctionName $functionName -Level 'INFO'
			}
		}
		
		# ??????????????????????????????????????????????????????????????????????
		# Methode 2: Windows Feature (Install-WindowsFeature)
		#            Windows Server (alle Versionen mit ServerManager)
		# ??????????????????????????????????????????????????????????????????????
		$hasFeatureCmd = [bool](Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)
		
		if (-not $installed -and $hasFeatureCmd)
		{
			$action = "RSAT AD-Modul via Install-WindowsFeature installieren ($adFeatureName)"
			if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action))
			{
				try
				{
					Invoke-sqmLogging -Message "Methode 2 (WindowsFeature): $action" `
									  -FunctionName $functionName -Level 'INFO'
					
					$featureResult = Install-WindowsFeature -Name $adFeatureName `
															-IncludeManagementTools -ErrorAction Stop
					
					if ($featureResult.Success)
					{
						Invoke-sqmLogging -Message "Methode 2 (WindowsFeature): Erfolgreich installiert." `
										  -FunctionName $functionName -Level 'INFO'
						$installed = $true
						
						if ($featureResult.RestartNeeded -eq 'Yes')
						{
							Write-Warning "RSAT-Installation abgeschlossen, aber ein Neustart wird empfohlen."
							Invoke-sqmLogging -Message "Methode 2: Neustart empfohlen." `
											  -FunctionName $functionName -Level 'WARNING'
						}
					}
					else
					{
						Invoke-sqmLogging -Message "Methode 2 (WindowsFeature): Install-WindowsFeature ohne Success-Flag - versuche Methode 3." `
										  -FunctionName $functionName -Level 'WARNING'
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Methode 2 (WindowsFeature) fehlgeschlagen: $($_.Exception.Message) - versuche Methode 3." `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}
		}
		else
		{
			if (-not $installed -and -not $hasFeatureCmd)
			{
				Invoke-sqmLogging -Message "Methode 2 (WindowsFeature): Install-WindowsFeature nicht verfuegbar - uebersprungen." `
								  -FunctionName $functionName -Level 'INFO'
			}
		}
		
		# ??????????????????????????????????????????????????????????????????????
		# Methode 3: DISM (dism.exe /Online /Add-Capability)
		#            Fallback fuer aeltere Systeme ohne PS-Cmdlets
		# ??????????????????????????????????????????????????????????????????????
		$dismPath = "$env:SystemRoot\System32\dism.exe"
		$hasDism = Test-Path $dismPath
		
		if (-not $installed -and $hasDism)
		{
			$action = "RSAT AD-Modul via DISM installieren ($adCapabilityName)"
			if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action))
			{
				try
				{
					Invoke-sqmLogging -Message "Methode 3 (DISM): $action" `
									  -FunctionName $functionName -Level 'INFO'
					
					$dismArgs = @(
						'/Online',
						'/Add-Capability',
						"/CapabilityName:$adCapabilityName",
						'/Quiet',
						'/NoRestart'
					)
					
					$dismProcess = Start-Process -FilePath $dismPath `
												 -ArgumentList $dismArgs `
												 -Wait -PassThru -NoNewWindow `
												 -ErrorAction Stop
					
					if ($dismProcess.ExitCode -eq 0)
					{
						Invoke-sqmLogging -Message "Methode 3 (DISM): Erfolgreich installiert (ExitCode 0)." `
										  -FunctionName $functionName -Level 'INFO'
						$installed = $true
					}
					elseif ($dismProcess.ExitCode -eq 3010)
					{
						# 3010 = Erfolg, aber Neustart erforderlich
						Write-Warning "RSAT via DISM installiert (ExitCode 3010) - Neustart empfohlen."
						Invoke-sqmLogging -Message "Methode 3 (DISM): ExitCode 3010 - Neustart empfohlen." `
										  -FunctionName $functionName -Level 'WARNING'
						$installed = $true
					}
					else
					{
						Invoke-sqmLogging -Message "Methode 3 (DISM): ExitCode $($dismProcess.ExitCode) - Installation fehlgeschlagen." `
										  -FunctionName $functionName -Level 'WARNING'
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Methode 3 (DISM) fehlgeschlagen: $($_.Exception.Message)" `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}
		}
		else
		{
			if (-not $installed -and -not $hasDism)
			{
				Invoke-sqmLogging -Message "Methode 3 (DISM): dism.exe nicht gefunden - uebersprungen." `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}
		
		# ??????????????????????????????????????????????????????????????????????
		# Methode 4: PSGallery (Install-Module ActiveDirectory)
		#            Letzter Ausweg - setzt NuGet-Provider und PSGallery-Zugang
		#            voraus. Nicht auf allen Umgebungen verfuegbar/erlaubt.
		#            Schreibt in den CurrentUser-Scope um ohne Admin auszukommen,
		#            versucht AllUsers wenn CurrentUser fehlschlaegt.
		# ??????????????????????????????????????????????????????????????????????
		$hasInstallModule = [bool](Get-Command Install-Module -ErrorAction SilentlyContinue)
		
		if (-not $installed -and $hasInstallModule)
		{
			$action = "ActiveDirectory-Modul via PSGallery installieren (Install-Module)"
			if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action))
			{
				try
				{
					Invoke-sqmLogging -Message "Methode 4 (PSGallery): $action" `
									  -FunctionName $functionName -Level 'INFO'
					
					# NuGet-Provider sicherstellen (PSGallery-Voraussetzung)
					$nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
					if (-not $nuget -or $nuget.Version -lt [Version]'2.8.5.201')
					{
						Invoke-sqmLogging -Message "Methode 4: NuGet-Provider wird installiert." `
										  -FunctionName $functionName -Level 'INFO'
						Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' `
												-Force -Scope CurrentUser -ErrorAction Stop | Out-Null
					}
					
					# PSGallery als vertrauenswuerdig setzen (temporaer fuer diese Session)
					$psGalleryTrusted = (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -eq 'Trusted'
					if (-not $psGalleryTrusted)
					{
						Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
						Invoke-sqmLogging -Message "Methode 4: PSGallery als Trusted gesetzt." `
										  -FunctionName $functionName -Level 'INFO'
					}
					
					# Erst CurrentUser versuchen (kein Admin noetig), dann AllUsers
					$installScopes = @('CurrentUser', 'AllUsers')
					foreach ($scope in $installScopes)
					{
						try
						{
							Invoke-sqmLogging -Message "Methode 4 (PSGallery): Install-Module Scope=$scope" `
											  -FunctionName $functionName -Level 'INFO'
							Install-Module -Name ActiveDirectory -Scope $scope `
										   -Force -AllowClobber -ErrorAction Stop
							$installed = $true
							Invoke-sqmLogging -Message "Methode 4 (PSGallery): Erfolgreich installiert (Scope=$scope)." `
											  -FunctionName $functionName -Level 'INFO'
							break
						}
						catch
						{
							Invoke-sqmLogging -Message "Methode 4 (PSGallery) Scope=$scope fehlgeschlagen: $($_.Exception.Message)" `
											  -FunctionName $functionName -Level 'WARNING'
						}
					}
					
					if (-not $installed)
					{
						Invoke-sqmLogging -Message "Methode 4 (PSGallery): Alle Scopes fehlgeschlagen." `
										  -FunctionName $functionName -Level 'WARNING'
					}
				}
				catch
				{
					Invoke-sqmLogging -Message "Methode 4 (PSGallery) fehlgeschlagen: $($_.Exception.Message)" `
									  -FunctionName $functionName -Level 'WARNING'
				}
			}
		}
		else
		{
			if (-not $installed -and -not $hasInstallModule)
			{
				Invoke-sqmLogging -Message "Methode 4 (PSGallery): Install-Module nicht verfuegbar - uebersprungen." `
								  -FunctionName $functionName -Level 'WARNING'
			}
		}
		
		# ?? 3. Abschlusspruefung ???????????????????????????????????????????????
		if (-not $installed)
		{
			return (_Fail ("Alle Installationsmethoden fehlgeschlagen (Capability, WindowsFeature, DISM, PSGallery). " +
					"RSAT AD-Modul konnte nicht installiert werden. " +
					"Installiere es manuell: " +
					"'Add-WindowsCapability -Online -Name $adCapabilityName' " +
					"oder ueber die Serverrollen-Verwaltung (RSAT-AD-PowerShell)."))
		}
		
		# Modul nach Installation in Session laden
		$verifyAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
		if (-not $verifyAvailable)
		{
			return (_Fail "Installation scheinbar erfolgreich, aber ActiveDirectory-Modul danach nicht auffindbar.")
		}
		
		try
		{
			Import-Module ActiveDirectory -ErrorAction Stop
			Invoke-sqmLogging -Message "ActiveDirectory-Modul erfolgreich geladen." `
							  -FunctionName $functionName -Level 'INFO'
			return $true
		}
		catch
		{
			return (_Fail "Installation erfolgreich, aber Import-Module ActiveDirectory fehlgeschlagen: $($_.Exception.Message)")
		}
	}
}