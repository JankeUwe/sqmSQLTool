# SQL Version Detection Helper
# Used by all job scripts to handle TrustServerCertificate on SQL 2022+

function Get-SqlVersionWithoutError {
	param([string]$ConnectionString)
	try {
		$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
		$conn.Open()
		$cmd = $conn.CreateCommand()
		$cmd.CommandText = "SELECT SERVERPROPERTY('ProductVersion')"
		$version = $cmd.ExecuteScalar()
		$conn.Close()
		return $version
	}
	catch { return $null }
}

function Initialize-SqlTrustServerCertificate {
	param([string]$SqlInstance)

	$connStringBase = "Server=$SqlInstance;Integrated Security=SSPI;Timeout=5"
	$version = Get-SqlVersionWithoutError -ConnectionString $connStringBase

	if (-not $version) {
		$connStringWithTrust = $connStringBase + ";TrustServerCertificate=True"
		$version = Get-SqlVersionWithoutError -ConnectionString $connStringWithTrust
		Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Scope Session -Force -ErrorAction SilentlyContinue
	}

	if (-not $version) {
		throw "Verbindung zu $SqlInstance fehlgeschlagen."
	}

	return $version
}
