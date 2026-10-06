param(
   [Parameter(Mandatory = $true)][string]$Bin,
   [Parameter(Mandatory = $true)][ValidateSet("usage", "invalidate")][string]$Action,
   [Parameter(Mandatory = $true)][string]$Output,
   [Parameter(Mandatory = $true)][int]$TimeoutMs
)

$ErrorActionPreference = "Stop"
$result = @{ status = -1; stdout = ""; stderr = ""; timed_out = $false }
$process = New-Object System.Diagnostics.Process
try {
   $process.StartInfo.FileName = $Bin
   $process.StartInfo.Arguments = if ($Action -eq "invalidate") {
      "usage invalidate --no-extensions"
   } else {
      "usage --json --no-extensions"
   }
   $process.StartInfo.UseShellExecute = $false
   $process.StartInfo.CreateNoWindow = $true
   $process.StartInfo.RedirectStandardOutput = $true
   $process.StartInfo.RedirectStandardError = $true
   $process.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
   $process.StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
   $process.StartInfo.EnvironmentVariables["NO_COLOR"] = "1"
   [void]$process.Start()
   $stdout = $process.StandardOutput.ReadToEndAsync()
   $stderr = $process.StandardError.ReadToEndAsync()
   if (-not $process.WaitForExit($TimeoutMs)) {
      $result.timed_out = $true
      $process.Kill()
      $process.WaitForExit()
   } else {
      $result.status = $process.ExitCode
      $text = $stdout.GetAwaiter().GetResult()
      $errorText = $stderr.GetAwaiter().GetResult()
      if ($text.Length -gt 4MB) {
         $result.status = 1
      } elseif ($result.status -eq 0) {
         $result.stdout = $text
      }
      if ($errorText.Contains("No credentials found")) {
         $result.stderr = "No credentials found"
      } elseif ($errorText.Contains("providers without a usage endpoint")) {
         $result.stderr = "providers without a usage endpoint"
      }
   }
} catch {
   $result.status = -1
} finally {
   $process.Dispose()
}

$json = ConvertTo-Json -InputObject $result -Compress
[System.IO.File]::WriteAllText($Output, $json, (New-Object System.Text.UTF8Encoding($false)))
