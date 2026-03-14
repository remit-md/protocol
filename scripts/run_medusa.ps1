# Run Medusa stateful fuzzer for remit-protocol (Windows/PowerShell)
# Usage: scripts/run_medusa.ps1 [-ConfigFile <file>] [-ContractName <name>] [-TestLimit <n>] [-Timeout <s>]
#
#   ConfigFile:   medusa config JSON (default: medusa.json)
#                 Campaign configs: medusa.json (Escrow), medusa-tab.json (Tab), medusa-cross.json (Cross)
#   ContractName: override target contract (e.g. EscrowStateful, TabStateful, CrossContractStateful)
#   TestLimit:    number of transactions (default: 10000)
#   Timeout:      seconds (default: 0 = unlimited)
#
# Requires: medusa.exe in ~/.local/bin, forge in ~/.foundry/bin
# For CI: use the audit-repo GH Actions workflow instead.

param(
    [string]$ConfigFile = "medusa.json",
    [string]$ContractName = "",
    [int]$TestLimit = 10000,
    [int]$Timeout = 0
)

$env:PATH = [Environment]::GetEnvironmentVariable('PATH','User') + ';' + [Environment]::GetEnvironmentVariable('PATH','Machine')
$env:FOUNDRY_PROFILE = 'medusa'

Set-Location (Split-Path $PSScriptRoot -Parent)

$args_list = @('fuzz', '--config', $ConfigFile)
if ($ContractName) { $args_list += @('--target-contracts', $ContractName) }
if ($TestLimit -gt 0) { $args_list += @('--test-limit', $TestLimit.ToString()) }
if ($Timeout -gt 0) { $args_list += @('--timeout', $Timeout.ToString()) }

& "$env:USERPROFILE\.local\bin\medusa.exe" @args_list
