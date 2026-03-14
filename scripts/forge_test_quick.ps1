$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' + [Environment]::GetEnvironmentVariable('PATH','Machine')
Set-Location (Split-Path $PSScriptRoot -Parent)
forge test 2>&1 | Select-Object -Last 5
