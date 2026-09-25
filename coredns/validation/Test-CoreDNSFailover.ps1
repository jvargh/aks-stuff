[CmdletBinding()]
param(
    [string]$Context = "aks01day2",
    [string]$Namespace = "coredns-failover-validation"
)

$ErrorActionPreference = "Stop"
$outageManifest = Join-Path $PSScriptRoot "primary-outage-networkpolicy.yaml"
$resultsDirectory = Join-Path $PSScriptRoot "results"
$results = [System.Collections.Generic.List[object]]::new()

function Add-TestResult {
    param(
        [string]$Id,
        [string]$Requirement,
        [bool]$Passed,
        [string]$Observed
    )

    $script:results.Add([pscustomobject]@{
        Id = $Id
        Requirement = $Requirement
        Passed = $Passed
        Observed = $Observed.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
    })
}

function Invoke-Dig {
    param(
        [string]$Server,
        [string]$Name,
        [int]$TimeoutSeconds = 5
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & kubectl exec -n $Namespace deployment/dns-client -- `
        dig "@$Server" $Name A "+time=$TimeoutSeconds" "+tries=1" "+comments" "+answer" "+stats" 2>&1
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()

    return [pscustomobject]@{
        ExitCode = $exitCode
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        QueryMilliseconds = if (($output -join "`n") -match "Query time:\s+(\d+)\s+msec") {
            [int]$Matches[1]
        } else {
            $null
        }
        Output = ($output -join "`n")
        Addresses = @(
            $output |
                Select-String -Pattern "\sIN\s+A\s+(\d{1,3}(?:\.\d{1,3}){3})\s*$" |
                ForEach-Object { $_.Matches[0].Groups[1].Value }
        )
        Status = if (($output -join "`n") -match "status:\s+([A-Z]+)") { $Matches[1] } else { "NO_RESPONSE" }
    }
}

function Restart-Resolver {
    & kubectl rollout restart deployment/resolver-sequential -n $Namespace | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to restart the sequential resolver."
    }

    & kubectl rollout status deployment/resolver-sequential -n $Namespace --timeout=120s | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The sequential resolver did not become ready."
    }
}

function Write-ResultsReport {
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = Join-Path $resultsDirectory "aks01day2-$timestamp.md"
    $passedCount = @($results | Where-Object Passed).Count
    $failedCount = $results.Count - $passedCount
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("# CoreDNS Failover Validation Result")
    $lines.Add("")
    $lines.Add("- Cluster context: ``$Context``")
    $lines.Add("- Namespace: ``$Namespace``")
    $lines.Add("- Executed: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")")
    $lines.Add("- Summary: $passedCount passed, $failedCount failed")
    $lines.Add("")
    $lines.Add("| Test | Result | Requirement | Observation |")
    $lines.Add("|---|---|---|---|")

    foreach ($result in $results) {
        $state = if ($result.Passed) { "PASS" } else { "FAIL" }
        $lines.Add("| $($result.Id) | $state | $($result.Requirement) | $($result.Observed) |")
    }

    Set-Content -Path $reportPath -Value $lines -Encoding utf8
    return $reportPath
}

$currentContext = (& kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the current kubectl context."
}

if ($currentContext -ne $Context) {
    throw "Current kubectl context is '$currentContext'. Switch to '$Context' before running tests."
}

& kubectl wait --for=condition=Available deployment --all -n $Namespace --timeout=120s | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "One or more lab deployments are unavailable. Run Deploy-CoreDNSFailoverLab.ps1 first."
}

try {
    $managedCorefile = & kubectl get configmap coredns -n kube-system -o jsonpath="{.data.Corefile}"
    $managedImage = & kubectl get deployment coredns -n kube-system -o jsonpath="{.spec.template.spec.containers[0].image}"
    $usesDefaultPolicy = $managedCorefile -match "forward \. /etc/resolv\.conf" -and
        $managedCorefile -notmatch "policy\s+(random|round_robin|sequential)"
    Add-TestResult "TC-00" "Record the managed CoreDNS baseline without changing kube-system." `
        ($LASTEXITCODE -eq 0 -and $usesDefaultPolicy) `
        "Image=$managedImage; Corefile forwards to /etc/resolv.conf with no explicit upstream-selection policy."

    $roundRobinAddresses = [System.Collections.Generic.HashSet[string]]::new()
    1..8 | ForEach-Object {
        $query = Invoke-Dig -Server "resolver-round-robin" -Name "answer.validation.test"
        foreach ($address in $query.Addresses) {
            [void]$roundRobinAddresses.Add($address)
        }
    }
    $roundRobinPassed = $roundRobinAddresses.Contains("192.0.2.10") -and
        $roundRobinAddresses.Contains("192.0.2.20")
    Add-TestResult "TC-01" "Round-robin policy must use both healthy upstreams." $roundRobinPassed `
        "Observed addresses across 8 queries: $($roundRobinAddresses -join ', ')."

    $sequentialAddresses = [System.Collections.Generic.List[string]]::new()
    1..8 | ForEach-Object {
        $query = Invoke-Dig -Server "resolver-sequential" -Name "answer.validation.test"
        foreach ($address in $query.Addresses) {
            $sequentialAddresses.Add($address)
        }
    }
    $unexpectedSequential = @($sequentialAddresses | Where-Object { $_ -ne "192.0.2.10" })
    $sequentialPassed = $sequentialAddresses.Count -eq 8 -and $unexpectedSequential.Count -eq 0
    Add-TestResult "TC-02" "Sequential policy must prefer the first healthy upstream." $sequentialPassed `
        "Observed addresses across 8 queries: $($sequentialAddresses -join ', ')."

    $defaultRcode = Invoke-Dig -Server "resolver-sequential" -Name "rcode.validation.test"
    $rcodeDefaultPassed = $defaultRcode.Status -eq "SERVFAIL" -and $defaultRcode.Addresses.Count -eq 0
    Add-TestResult "TC-03" "Without failover SERVFAIL, a DNS SERVFAIL response must be returned without trying the second upstream." `
        $rcodeDefaultPassed "Status=$($defaultRcode.Status); answers=$($defaultRcode.Addresses -join ',')."

    $failoverRcode = Invoke-Dig -Server "resolver-rcode-failover" -Name "rcode.validation.test"
    $rcodeFailoverPassed = $failoverRcode.Status -eq "NOERROR" -and
        $failoverRcode.Addresses -contains "192.0.2.20"
    Add-TestResult "TC-04" "With failover SERVFAIL, the resolver must retry the second upstream." `
        $rcodeFailoverPassed "Status=$($failoverRcode.Status); answers=$($failoverRcode.Addresses -join ',')."

    & kubectl apply -f $outageManifest | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply the primary-upstream outage policy."
    }

    Restart-Resolver
    $shortTimeout = Invoke-Dig -Server "resolver-sequential" -Name "answer.validation.test" -TimeoutSeconds 1
    $shortTimeoutPassed = $shortTimeout.ExitCode -ne 0 -or $shortTimeout.Status -eq "NO_RESPONSE"
    Add-TestResult "TC-05" "A client timeout shorter than the resolver read timeout must expose a lookup failure during the first dropped query." `
        $shortTimeoutPassed "Client timeout=1s; exit=$($shortTimeout.ExitCode); status=$($shortTimeout.Status)."

    Start-Sleep -Seconds 3
    Restart-Resolver
    $firstFailover = Invoke-Dig -Server "resolver-sequential" -Name "answer.validation.test" -TimeoutSeconds 5
    $firstFailoverPassed = $firstFailover.Status -eq "NOERROR" -and
        $firstFailover.Addresses -contains "192.0.2.20" -and
        $firstFailover.QueryMilliseconds -ge 1500 -and
        $firstFailover.QueryMilliseconds -le 3000
    Add-TestResult "TC-06" "A dropped first upstream must be retried on the second upstream after approximately the CoreDNS 1.13.1 fixed 2s read timeout." `
        $firstFailoverPassed "Status=$($firstFailover.Status); answer=$($firstFailover.Addresses -join ','); DNS query time=$($firstFailover.QueryMilliseconds)ms."

    Start-Sleep -Seconds 2
    $healthySecondaryLatencies = [System.Collections.Generic.List[int]]::new()
    $healthySecondaryAnswers = [System.Collections.Generic.List[string]]::new()
    1..3 | ForEach-Object {
        $query = Invoke-Dig -Server "resolver-sequential" -Name "answer.validation.test" -TimeoutSeconds 5
        $healthySecondaryLatencies.Add($query.QueryMilliseconds)
        foreach ($address in $query.Addresses) {
            $healthySecondaryAnswers.Add($address)
        }
    }
    $secondaryPassed = @($healthySecondaryAnswers | Where-Object { $_ -ne "192.0.2.20" }).Count -eq 0 -and
        $healthySecondaryAnswers.Count -eq 3 -and
        ($healthySecondaryLatencies | Measure-Object -Maximum).Maximum -lt 500
    Add-TestResult "TC-07" "After the primary is marked unhealthy, queries must use the healthy secondary without waiting for the primary read timeout." `
        $secondaryPassed "Answers=$($healthySecondaryAnswers -join ','); DNS query times=$($healthySecondaryLatencies -join ',')ms."

    $metricsPath = "/api/v1/namespaces/$Namespace/services/http:resolver-sequential:metrics/proxy/metrics"
    $metrics = & kubectl get --raw $metricsPath
    $healthMetricLines = @(
        $metrics -split "`n" |
            Where-Object { $_ -match '^coredns_proxy_healthcheck_failures_total\{.*proxy_name="forward".*\}\s+[1-9]' }
    )
    Add-TestResult "TC-08" "Active upstream health-check failures must be observable in CoreDNS metrics." `
        ($LASTEXITCODE -eq 0 -and $healthMetricLines.Count -gt 0) `
        "Non-zero forward health-check failure series=$($healthMetricLines.Count)."
}
finally {
    & kubectl delete -f $outageManifest --ignore-not-found | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The outage policy could not be removed. Delete it manually before using the lab."
    }
}

$recoveryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$recovered = $false
$recoveryObservation = "Primary did not recover within 10 seconds."

while ($recoveryStopwatch.Elapsed.TotalSeconds -lt 10) {
    $query = Invoke-Dig -Server "resolver-sequential" -Name "answer.validation.test" -TimeoutSeconds 5
    if ($query.Addresses -contains "192.0.2.10") {
        $recovered = $true
        $recoveryObservation = "Primary answer returned after $($recoveryStopwatch.ElapsedMilliseconds)ms."
        break
    }
    Start-Sleep -Milliseconds 250
}

$recoveryStopwatch.Stop()
Add-TestResult "TC-09" "After connectivity is restored, active health checks must return the primary upstream to service within 10 seconds." `
    $recovered $recoveryObservation

$reportPath = Write-ResultsReport
$failed = @($results | Where-Object { -not $_.Passed })

$results | Format-Table Id, Passed, Requirement, Observed -AutoSize
Write-Host ""
Write-Host "Result report: $reportPath"
Write-Host "The namespace remains deployed; the primary-outage NetworkPolicy has been removed."

if ($failed.Count -gt 0) {
    exit 1
}
