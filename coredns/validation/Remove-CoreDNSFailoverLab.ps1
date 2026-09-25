[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Context = "aks01day2",
    [string]$Namespace = "coredns-failover-validation"
)

$ErrorActionPreference = "Stop"
$currentContext = (& kubectl config current-context).Trim()

if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the current kubectl context."
}

if ($currentContext -ne $Context) {
    throw "Current kubectl context is '$currentContext'. Switch to '$Context' before removing the lab."
}

if ($PSCmdlet.ShouldProcess($Namespace, "Delete CoreDNS failover validation namespace")) {
    & kubectl delete namespace $Namespace --ignore-not-found
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete namespace '$Namespace'."
    }
}
