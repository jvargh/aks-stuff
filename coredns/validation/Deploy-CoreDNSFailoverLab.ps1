[CmdletBinding()]
param(
    [string]$Context = "aks01day2",
    [string]$Namespace = "coredns-failover-validation"
)

$ErrorActionPreference = "Stop"
$manifest = Join-Path $PSScriptRoot "coredns-failover-lab.yaml"
$currentContext = (& kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the current kubectl context."
}

if ($currentContext -ne $Context) {
    throw "Current kubectl context is '$currentContext'. Switch to '$Context' before deploying the lab."
}

& kubectl apply -f $manifest
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply $manifest."
}

$primaryIp = (& kubectl get service upstream-primary -n $Namespace -o jsonpath="{.spec.clusterIP}").Trim()
if ($LASTEXITCODE -ne 0 -or -not $primaryIp) {
    throw "Unable to read the primary upstream service IP."
}

$secondaryIp = (& kubectl get service upstream-secondary -n $Namespace -o jsonpath="{.spec.clusterIP}").Trim()
if ($LASTEXITCODE -ne 0 -or -not $secondaryIp) {
    throw "Unable to read the secondary upstream service IP."
}

function Set-ResolverConfig {
    param(
        [string]$Name,
        [string]$Policy,
        [switch]$FailoverOnServfail
    )

    $failoverLine = if ($FailoverOnServfail) { "        failover SERVFAIL`n" } else { "" }
    $corefile = @"
.:53 {
    errors
    log
    ready
    health
    prometheus :9153
    forward . $primaryIp $secondaryIp {
        policy $Policy
        max_fails 1
        health_check 500ms
$failoverLine    }
}
"@

    & kubectl create configmap $Name -n $Namespace "--from-literal=Corefile=$corefile" `
        --dry-run=client -o yaml |
        & kubectl apply -f - | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure resolver '$Name'."
    }
}

Set-ResolverConfig -Name "resolver-round-robin" -Policy "round_robin"
Set-ResolverConfig -Name "resolver-sequential" -Policy "sequential"
Set-ResolverConfig -Name "resolver-rcode-failover" -Policy "sequential" -FailoverOnServfail

$resolvers = @(
    "resolver-round-robin",
    "resolver-sequential",
    "resolver-rcode-failover"
)

foreach ($resolver in $resolvers) {
    & kubectl rollout restart "deployment/$resolver" -n $Namespace | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart resolver '$resolver'."
    }
}

$deployments = @(
    "upstream-primary",
    "upstream-secondary",
    "resolver-round-robin",
    "resolver-sequential",
    "resolver-rcode-failover",
    "dns-client"
)

foreach ($deployment in $deployments) {
    & kubectl rollout status "deployment/$deployment" -n $Namespace --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment '$deployment' did not become ready."
    }
}

& kubectl get pods,services -n $Namespace
if ($LASTEXITCODE -ne 0) {
    throw "The lab deployed, but its final status could not be read."
}

Write-Host ""
Write-Host "CoreDNS failover lab is ready in namespace '$Namespace'."
Write-Host "Run .\Test-CoreDNSFailover.ps1 to execute the validation suite."
