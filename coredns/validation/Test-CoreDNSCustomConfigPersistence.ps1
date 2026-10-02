[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][switch]$ApproveCustomDnsChange,
    [string]$Context = "aks01day2",
    [string]$ClientNamespace = "coredns-failover-validation",
    [string]$ClientResource = "deployment/dns-client"
)

$ErrorActionPreference = "Stop"
if (-not $ApproveCustomDnsChange) { throw "Explicit approval is required." }
. (Join-Path $PSScriptRoot "CoreDNSCustomConfig.Helpers.ps1") -Context $Context
if (Test-Path -LiteralPath $EvidenceDirectory) { throw "Use a new evidence directory." }
$null = New-Item -ItemType Directory -Path $EvidenceDirectory
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
$token = [guid]::NewGuid().ToString("N").Substring(0, 12)
$testKey = "sp16-$token.server"
$queryName = "answer.sp16-$token.test."
$expectedAddress = "192.0.2.123"
$testRule = @"
sp16-$token.test:53 {
    errors
    hosts {
        $expectedAddress $($queryName.TrimEnd('.'))
        ttl 1
        no_reverse
    }
}
"@
$record = [ordered]@{
    CaseId = "SP-16-CUSTOM-CONFIG-PATCH-PERSISTENCE"
    Status = "RUNNING"
    StartedUtc = [DateTimeOffset]::UtcNow.ToString("o")
    Context = $Context
    TestKey = $testKey
    QueryName = $queryName
    ExpectedAddress = $expectedAddress
    Rule = $testRule
    Samples = [System.Collections.Generic.List[object]]::new()
    Queries = [System.Collections.Generic.List[object]]::new()
    Rollouts = [System.Collections.Generic.List[object]]::new()
    Errors = [System.Collections.Generic.List[string]]::new()
}
$patchAttempted = $false
$failure = $null
$cleanupFailure = $null

function Save-Evidence {
    $record | ConvertTo-Json -Depth 25 |
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory "result.json") -Encoding utf8
}

function Read-CustomConfig {
    Invoke-LifecycleKubectl -Arguments @(
        "get", "configmap", "coredns-custom", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
}

function Assert-OriginalData {
    param($Config, [bool]$IncludesTestKey)
    if ($Config.metadata.uid -cne $original.metadata.uid) { throw "Custom ConfigMap was recreated." }
    foreach ($field in @("data", "binaryData")) {
        $expectedKeys = @()
        if ($original[$field]) { $expectedKeys = @($original[$field].Keys) }
        $actualKeys = @()
        if ($Config[$field]) { $actualKeys = @($Config[$field].Keys) }
        if ($IncludesTestKey -and $field -eq "data") {
            if ($Config.data[$testKey] -cne $testRule) { throw "The test key is missing or changed." }
            $actualKeys = @($actualKeys | Where-Object { $_ -cne $testKey })
        }
        if ($actualKeys.Count -ne $expectedKeys.Count) { throw "Unrelated $field keys changed." }
        foreach ($key in $expectedKeys) {
            if ($actualKeys -cnotcontains $key -or $Config[$field][$key] -cne $original[$field][$key]) {
                throw "Unrelated $field value changed: $key"
            }
        }
    }
}

function Get-ReadyDnsPods {
    $deployment = Invoke-LifecycleKubectl -Arguments @(
        "get", "deployment", "coredns", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $pods = Invoke-LifecycleKubectl -Arguments @(
        "get", "pods", "-n", "kube-system", "-l", "k8s-app=kube-dns", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $active = @($pods.items | Where-Object { -not $_.metadata.deletionTimestamp })
    if ($deployment.spec.replicas -lt 2 -or $active.Count -ne $deployment.spec.replicas) {
        throw "Expected at least two managed replicas and exactly one active pod per desired replica."
    }
    foreach ($pod in $active) {
        if (-not $pod.status.podIP -or
            @($pod.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -ne 1) {
            throw "CoreDNS pod is not Ready: $($pod.metadata.name)"
        }
    }
    $active
}

function Invoke-DnsCheck {
    param([string]$Stage, [string]$Server, [string]$Target, [string]$Name,
          [string]$ExpectedStatus, [string]$Address = "", [int]$ExpectedTtl = -1)
    $output = Invoke-LifecycleKubectl -Arguments @(
        "exec", "-n", $ClientNamespace, $ClientResource, "--",
        "dig", "@$Server", $Name, "A", "+time=5", "+tries=1", "+comments", "+answer", "+stats"
    )
    $statusMatch = [regex]::Match($output, 'status:\s+([A-Z]+),')
    $timeMatch = [regex]::Match($output, 'Query time:\s+(\d+)\s+msec')
    $answers = @([regex]::Matches($output, '(?m)^(\S+)\s+(\d+)\s+IN\s+A\s+(\S+)\s*$'))
    $record.Queries.Add([pscustomobject]@{
        Stage = $Stage
        Target = $Target
        ObservedUtc = [DateTimeOffset]::UtcNow.ToString("o")
        Query = $Name
        Status = $statusMatch.Groups[1].Value
        QueryMilliseconds = if ($timeMatch.Success) { [int]$timeMatch.Groups[1].Value } else { $null }
        Output = $output.Replace($Server, "[DNS server IP]")
    })
    Save-Evidence
    if (-not $statusMatch.Success -or $statusMatch.Groups[1].Value -cne $ExpectedStatus) {
        throw "$Stage DNS status failed for $Target."
    }
    if ($Address -and ($answers.Count -ne 1 -or $answers[0].Groups[3].Value -cne $Address -or
        $answers[0].Groups[1].Value -ine $Name)) {
        throw "$Stage DNS answer failed for $Target."
    }
    if ($ExpectedTtl -ge 0 -and ($answers.Count -ne 1 -or
        [int]$answers[0].Groups[2].Value -ne $ExpectedTtl)) {
        throw "Test answer TTL did not match $ExpectedTtl."
    }
    if ($ExpectedStatus -eq "NXDOMAIN" -and $answers.Count -ne 0) { throw "Unexpected A answer." }
}

function Check-DnsPaths {
    param([string]$Stage, [bool]$RulePresent)
    $pods = @(Get-ReadyDnsPods)
    $targets = @([pscustomobject]@{ Server = $dnsService.spec.clusterIP; Name = "kube-dns Service" })
    $targets += @($pods | ForEach-Object {
        [pscustomobject]@{ Server = $_.status.podIP; Name = $_.metadata.name }
    })
    foreach ($target in $targets) {
        if ($RulePresent) {
            Invoke-DnsCheck $Stage $target.Server $target.Name $queryName "NOERROR" $expectedAddress -ExpectedTtl 1
        } else {
            Invoke-DnsCheck $Stage $target.Server $target.Name $queryName "NXDOMAIN"
        }
        Invoke-DnsCheck $Stage $target.Server $target.Name "kubernetes.default.svc.cluster.local." "NOERROR" $apiService.spec.clusterIP
    }
    @($pods | ForEach-Object { $_.metadata.uid })
}

function Restart-DnsAndVerify {
    param([string]$Stage)
    $oldUids = @(Get-ReadyDnsPods | ForEach-Object { $_.metadata.uid })
    $start = [DateTimeOffset]::UtcNow
    Invoke-LifecycleKubectl -Arguments @("rollout", "restart", "deployment/coredns", "-n", "kube-system") | Write-Host
    Invoke-LifecycleKubectl -Arguments @(
        "rollout", "status", "deployment/coredns", "-n", "kube-system", "--timeout=240s", "--request-timeout=300s"
    ) | Write-Host
    $newUids = @(Get-ReadyDnsPods | ForEach-Object { $_.metadata.uid })
    if (@($newUids | Where-Object { $oldUids -contains $_ }).Count -ne 0) {
        throw "$Stage did not replace all CoreDNS pods."
    }
    $record.Rollouts.Add([pscustomobject]@{
        Stage = $Stage
        StartedUtc = $start.ToString("o")
        CompletedUtc = [DateTimeOffset]::UtcNow.ToString("o")
        OldPodUids = $oldUids
        NewPodUids = $newUids
    })
    Save-Evidence
}

function Test-IsolatedRule {
    $name = "sp16-$token-syntax"
    $configCreated = $false
    $podCreated = $false
    try {
        Invoke-LifecycleKubectl -Arguments @(
            "create", "configmap", $name, "-n", $ClientNamespace, "--from-literal=Corefile=$testRule"
        ) | Write-Host
        $configCreated = $true
        $pod = @{
            apiVersion = "v1"
            kind = "Pod"
            metadata = @{ name = $name; namespace = $ClientNamespace; labels = @{ "sp16-run" = $token } }
            spec = @{
                restartPolicy = "Never"
                containers = @(@{
                    name = "coredns"
                    image = $record.Before.CoreDnsImages[0]
                    args = @("-conf", "/etc/coredns/Corefile")
                    readinessProbe = @{ tcpSocket = @{ port = 53 }; initialDelaySeconds = 1; periodSeconds = 2 }
                    resources = @{ requests = @{ cpu = "10m"; memory = "20Mi" }; limits = @{ cpu = "100m"; memory = "64Mi" } }
                    securityContext = @{
                        runAsNonRoot = $true; runAsUser = 65532; allowPrivilegeEscalation = $false
                        readOnlyRootFilesystem = $true
                        capabilities = @{ drop = @("ALL"); add = @("NET_BIND_SERVICE") }
                        seccompProfile = @{ type = "RuntimeDefault" }
                    }
                    volumeMounts = @(@{ name = "config"; mountPath = "/etc/coredns"; readOnly = $true })
                })
                volumes = @(@{ name = "config"; configMap = @{ name = $name } })
            }
        }
        $podPath = Join-Path $EvidenceDirectory "syntax-pod.json"
        $pod | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $podPath -Encoding utf8
        Invoke-LifecycleKubectl -Arguments @("create", "-f", $podPath) | Write-Host
        $podCreated = $true
        Invoke-LifecycleKubectl -Arguments @(
            "wait", "--for=condition=Ready", "pod/$name", "-n", $ClientNamespace,
            "--timeout=90s", "--request-timeout=120s"
        ) | Write-Host
        $running = Invoke-LifecycleKubectl -Arguments @(
            "get", "pod", $name, "-n", $ClientNamespace, "-o", "json"
        ) | ConvertFrom-Json -AsHashtable
        if (-not $running.status.podIP) { throw "The syntax-validation pod has no IP." }
        Invoke-DnsCheck "isolated-syntax-validation" $running.status.podIP $name $queryName "NOERROR" $expectedAddress -ExpectedTtl 1
        $record.SyntaxValidation = "PASS: same image served the exact rule before managed DNS was changed."
    }
    finally {
        if ($podCreated) {
            Invoke-LifecycleKubectl -Arguments @(
                "delete", "pod", $name, "-n", $ClientNamespace, "--wait=true",
                "--timeout=90s", "--request-timeout=120s"
            ) | Write-Host
        }
        if ($configCreated) {
            Invoke-LifecycleKubectl -Arguments @("delete", "configmap", $name, "-n", $ClientNamespace) | Write-Host
        }
    }
}

try {
    $original = Read-CustomConfig
    if (-not $original.data -or $original.data.Contains($testKey)) {
        throw "Expected an existing nonempty custom ConfigMap without the unique test key."
    }
    if (@($original.data.Keys | Where-Object { $_ -match '^sp16-[a-f0-9]+\.server$' }).Count -gt 0) {
        throw "Another SP-16 test key exists. Wait for that run or investigate its cleanup; do not overlap runs."
    }
    $original | ConvertTo-Json -Depth 25 |
        Set-Content -LiteralPath (Join-Path $EvidenceDirectory "private-original-configmap.json") -Encoding utf8
    $record.Before = Get-CustomDnsSnapshot
    Assert-CustomDnsPreserved $record.Before $record.Before
    if ($record.Before.CustomResourceVersion -cne $original.metadata.resourceVersion) {
        throw "ConfigMap changed during baseline collection; stop before writing."
    }
    $managedBefore = Invoke-LifecycleKubectl -Arguments @(
        "get", "configmap", "coredns", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $record.ManagedCorefileResourceVersionBefore = $managedBefore.metadata.resourceVersion
    $dnsService = Invoke-LifecycleKubectl -Arguments @(
        "get", "service", "kube-dns", "-n", "kube-system", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $apiService = Invoke-LifecycleKubectl -Arguments @(
        "get", "service", "kubernetes", "-n", "default", "-o", "json"
    ) | ConvertFrom-Json -AsHashtable
    $null = Check-DnsPaths "before-patch" $false
    Test-IsolatedRule
    $patch = @(
        @{ op = "test"; path = "/metadata/resourceVersion"; value = $original.metadata.resourceVersion },
        @{ op = "add"; path = "/data/$testKey"; value = $testRule }
    )
    $patchPath = Join-Path $EvidenceDirectory "add-test-key.json"
    ConvertTo-Json -InputObject $patch -Depth 10 |
        Set-Content -LiteralPath $patchPath -Encoding utf8
    $patchArgs = @("patch", "configmap", "coredns-custom", "-n", "kube-system",
        "--type=json", "--patch-file=$patchPath")
    Invoke-LifecycleKubectl -Arguments ($patchArgs + "--dry-run=server") | Write-Host
    $patchAttempted = $true
    Invoke-LifecycleKubectl -Arguments $patchArgs | Write-Host
    Assert-OriginalData (Read-CustomConfig) $true
    Restart-DnsAndVerify "activation"
    $null = Check-DnsPaths "after-activation" $true
    $record.Patched = Get-CustomDnsSnapshot
    Restart-DnsAndVerify "persistence-restart"
    $null = Check-DnsPaths "after-second-restart" $true
    $observationBase = Get-CustomDnsSnapshot
    Assert-CustomDnsPreserved $record.Patched $observationBase
    $record.Samples.Add($observationBase)
    Save-Evidence
    Write-Host "Observation started: 31 snapshots, 30-second sleeps, minimum 900 seconds."
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    for ($index = 1; $index -le 30; $index++) {
        Start-Sleep -Seconds 30
        $sample = Get-CustomDnsSnapshot
        $record.Samples.Add($sample)
        Save-Evidence
        Assert-CustomDnsPreserved $observationBase $sample
        if ($sample.KubernetesVersion -cne $observationBase.KubernetesVersion -or
            ($sample.CoreDnsImages -join ",") -cne ($observationBase.CoreDnsImages -join ",")) {
            throw "An upgrade overlapped the observation."
        }
    }
    $clock.Stop()
    $record.ObservationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
    if ($clock.Elapsed.TotalSeconds -lt 900) { throw "Observation was shorter than 900 seconds." }
    Assert-OriginalData (Read-CustomConfig) $true
    $null = Check-DnsPaths "after-observation" $true
}
catch {
    $failure = $_
    $record.Errors.Add($_.Exception.Message)
    Write-Warning "SP-16 stopped: $($_.Exception.Message)"
}
finally {
    if ($patchAttempted) {
        try {
            $current = Read-CustomConfig
            if ($current.metadata.uid -cne $original.metadata.uid) {
                throw "Cleanup refused: custom ConfigMap identity changed."
            }
            if ($current.data.Contains($testKey)) {
                if ($current.data[$testKey] -cne $testRule) {
                    throw "Cleanup refused: another writer changed the test key."
                }
                $remove = @(
                    @{ op = "test"; path = "/metadata/resourceVersion"; value = $current.metadata.resourceVersion },
                    @{ op = "test"; path = "/data/$testKey"; value = $testRule },
                    @{ op = "remove"; path = "/data/$testKey" }
                )
                $removePath = Join-Path $EvidenceDirectory "remove-test-key.json"
                ConvertTo-Json -InputObject $remove -Depth 10 |
                    Set-Content -LiteralPath $removePath -Encoding utf8
                Invoke-LifecycleKubectl -Arguments @(
                    "patch", "configmap", "coredns-custom", "-n", "kube-system",
                    "--type=json", "--patch-file=$removePath"
                ) | Write-Host
            } else {
                throw "Cleanup found the test key already missing; another change occurred."
            }
            # Recovery also works if an invalid rule left replacement pods unready.
            Invoke-LifecycleKubectl -Arguments @("rollout", "restart", "deployment/coredns", "-n", "kube-system") | Write-Host
            Invoke-LifecycleKubectl -Arguments @(
                "rollout", "status", "deployment/coredns", "-n", "kube-system", "--timeout=240s", "--request-timeout=300s"
            ) | Write-Host
            Assert-OriginalData (Read-CustomConfig) $false
            $record.AfterCleanup = Get-CustomDnsSnapshot
            Assert-CustomDnsPreserved $record.Before $record.AfterCleanup
            $null = Check-DnsPaths "after-cleanup" $false
            $managedAfter = Invoke-LifecycleKubectl -Arguments @(
                "get", "configmap", "coredns", "-n", "kube-system", "-o", "json"
            ) | ConvertFrom-Json -AsHashtable
            if ($managedBefore.metadata.resourceVersion -cne $managedAfter.metadata.resourceVersion -or
                $managedBefore.data.Corefile -cne $managedAfter.data.Corefile) {
                throw "Managed Corefile changed; investigate the other writer."
            }
            $record.ManagedCorefileResourceVersionAfter = $managedAfter.metadata.resourceVersion
            $record.Cleanup = "PASS: test key removed, original data/UID restored, fresh pods and DNS verified."
        }
        catch {
            $cleanupFailure = $_
            $record.Errors.Add("Cleanup: $($_.Exception.Message)")
            $record.Cleanup = "FAILED: manual investigation required; do not overwrite other writers."
            Write-Warning $record.Cleanup
        }
    }
    $record.Status = if ($null -eq $failure -and $null -eq $cleanupFailure) { "PASS" } else { "FAIL" }
    $record.CompletedUtc = [DateTimeOffset]::UtcNow.ToString("o")
    Save-Evidence
}
if ($null -ne $failure) { throw $failure }
if ($null -ne $cleanupFailure) { throw $cleanupFailure }
Write-Output "PASS: SP-16, $($record.Samples.Count) snapshots, $($record.ObservationSeconds) seconds; cleanup verified."
