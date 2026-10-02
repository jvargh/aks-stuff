[CmdletBinding()]
param([string]$Context = "aks01day2")

$lifecycleContext = $Context

function Invoke-LifecycleKubectl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & kubectl "--context=$lifecycleContext" --request-timeout=20s @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed: $($output -join "`n")"
    }
    $output -join "`n"
}

function Get-CustomDnsSnapshot {
    $custom = Invoke-LifecycleKubectl -Arguments @(
        "get", "configmap", "coredns-custom", "-n", "kube-system",
        "-o", "json", "--show-managed-fields=true"
    ) | ConvertFrom-Json -AsHashtable
    $namespace = Invoke-LifecycleKubectl -Arguments @(
        "get", "namespace", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $version = Invoke-LifecycleKubectl -Arguments @("version", "-o", "json") |
        ConvertFrom-Json -AsHashtable
    $deployment = Invoke-LifecycleKubectl -Arguments @(
        "get", "deployment", "coredns", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable

    $payload = [ordered]@{}
    foreach ($field in @("data", "binaryData")) {
        $values = [System.Collections.Generic.SortedDictionary[string,string]]::new(
            [System.StringComparer]::Ordinal
        )
        if ($null -ne $custom[$field]) {
            foreach ($key in $custom[$field].Keys) {
                $values.Add($key, $custom[$field][$key])
            }
        }
        $payload[$field] = $values
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        ($payload | ConvertTo-Json -Depth 10 -Compress)
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    }
    finally { $sha.Dispose() }
    if (-not $custom.metadata.uid -or -not $namespace.metadata.uid -or
        -not $version.serverVersion.gitVersion) {
        throw "Incomplete cluster identity or ConfigMap snapshot."
    }
    [pscustomobject]@{
        ObservedUtc = [DateTimeOffset]::UtcNow.ToString("o")
        Context = $lifecycleContext
        NamespaceUid = $namespace.metadata.uid
        KubernetesVersion = $version.serverVersion.gitVersion
        CustomUid = $custom.metadata.uid
        CustomResourceVersion = $custom.metadata.resourceVersion
        PayloadSha256 = $hash
        DataKeys = @($payload.data.Keys)
        BinaryDataKeys = @($payload.binaryData.Keys)
        Labels = $custom.metadata.labels
        Owners = @($custom.metadata.ownerReferences)
        FieldManagers = @($custom.metadata.managedFields | ForEach-Object {
            [pscustomobject]@{
                Manager = $_.manager
                Operation = $_.operation
                Time = $_.time
            }
        })
        CoreDnsImages = @($deployment.spec.template.spec.containers | ForEach-Object { $_.image })
        ManagedDeploymentResourceVersion = $deployment.metadata.resourceVersion
        DesiredReplicas = [int]$deployment.spec.replicas
        AvailableReplicas = [int]$deployment.status.availableReplicas
    }
}

function Assert-CustomDnsPreserved {
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )
    foreach ($field in @("Context", "NamespaceUid", "CustomUid", "PayloadSha256")) {
        if ([string]::IsNullOrWhiteSpace([string]$Before.$field) -or
            [string]::IsNullOrWhiteSpace([string]$After.$field)) {
            throw "Missing comparison field: $field"
        }
        if ($Before.$field -cne $After.$field) {
            throw "Persistence check failed: $field changed. Inspect the saved evidence."
        }
    }
    if ($After.DesiredReplicas -lt 1 -or
        $After.AvailableReplicas -lt $After.DesiredReplicas) {
        throw "Managed CoreDNS is not fully Available at the observation point."
    }
}
