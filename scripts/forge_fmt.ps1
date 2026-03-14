$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' + [Environment]::GetEnvironmentVariable('PATH','Machine')
Set-Location (Split-Path $PSScriptRoot -Parent)
forge fmt 2>&1
Write-Host "Exit: $LASTEXITCODE"
