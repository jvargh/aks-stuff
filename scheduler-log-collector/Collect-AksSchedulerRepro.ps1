#requires -Version 7.0

<#
.SYNOPSIS
Collects evidence during a controlled AKS scheduler reproduction.

.DESCRIPTION
Captures node requested resources, pod placement, node/pod usage, events, and
an optional sanitized Job or CronJob scheduling specification. The script
cordons the test node before baseline capture, uncordons it for the
configured observation window, and always attempts to re-cordon it.

This script changes node schedulability. Run only in an approved change window.

.EXAMPLE
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace workload-namespace `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c'
  ) `
  -JobName example-job `
  -AcknowledgeImpact

.EXAMPLE
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace workload-namespace `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c'
  ) `
  -CronJobName example-cronjob `
  -DurationMinutes 8 `
  -SampleIntervalSeconds 30 `
  -AbortNodeCpuPercent 90 `
  -AcknowledgeImpact
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Namespace,

    [Parameter(Mandatory)]
    [ValidateCount(1, 100)]
    [string[]]$NodesToCapture,

    [ValidateRange(2, 30)]
    [int]$DurationMinutes = 10,

    [ValidateRange(15, 300)]
    [int]$SampleIntervalSeconds = 60,

    [ValidateRange(1, 100)]
    [int]$AbortNodeCpuPercent = 90,

    [string]$JobName,

    [string]$CronJobName,

    [string]$OutputRoot = (Join-Path $PWD (
        'aks-scheduler-repro-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    )),

    [Parameter(Mandatory)]
    [switch]$AcknowledgeImpact
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($JobName -and $CronJobName) {
    throw 'Specify either -JobName or -CronJobName, not both.'
}

$NodesToCapture = @($NodesToCapture |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique)

if ($NodesToCapture.Count -eq 0) {
    throw 'Specify at least one node with -NodesToCapture.'
}

$TestNode = $NodesToCapture[0]

if (-not $AcknowledgeImpact) {
    throw 'Run with -AcknowledgeImpact only after change approval and rollback ownership are confirmed.'
}

function Write-RunLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (
        (Get-Date).ToUniversalTime().ToString('o'),
        $Level,
        $Message
    )
    Write-Host $line
    Add-Content -LiteralPath $script:RunLogPath -Value $line
}

function Write-Phase {
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $banner = "========== PHASE $Number - $Name =========="
    Write-Host ''
    Write-Host $banner -ForegroundColor Cyan
    Write-RunLog "PHASE $Number START: $Name"
}

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-RunLog "STEP: $Message"
}

function Invoke-KubectlText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$OutputPath,

        [switch]$AllowFailure,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 3,

        [ValidateRange(1, 30)]
        [int]$RetryDelaySeconds = 3
    )

    $exitCode = -1
    $text = ''

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $output = & kubectl @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

        if ($exitCode -eq 0) {
            break
        }

        if ($attempt -lt $MaxAttempts) {
            Write-RunLog "kubectl attempt $attempt/$MaxAttempts failed for '$($Arguments -join ' ')'. Retrying in $RetryDelaySeconds seconds. Error: $text" 'WARN'
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    if ($OutputPath) {
        $text | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }

    $result = [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $text
        Attempts = [Math]::Min($attempt, $MaxAttempts)
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "kubectl $($Arguments -join ' ') failed after $MaxAttempts attempts with exit code $exitCode.`n$text"
    }

    $result
}

function Get-KubectlJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-KubectlText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        throw "kubectl $($Arguments -join ' ') returned no JSON."
    }

    $result.Text | ConvertFrom-Json -Depth 100
}

function Get-KubectlCanI {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-KubectlText -Arguments (@('auth', 'can-i') + $Arguments)
    $decision = $result.Text -split '\r?\n' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ -in @('yes', 'no') } |
        Select-Object -Last 1

    if (-not $decision) {
        throw "Unable to parse kubectl auth can-i result:`n$($result.Text)"
    }

    $decision
}

function Assert-NodeExists {
    param([Parameter(Mandatory)][string]$NodeName)

    $result = Invoke-KubectlText -Arguments @('get', 'node', $NodeName, '-o', 'name') -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Node '$NodeName' was not found in the active kubectl context."
    }
}

function Get-NodeReadyStatus {
    param([Parameter(Mandatory)][string]$NodeName)

    $node = Get-KubectlJson -Arguments @('get', 'node', $NodeName, '-o', 'json')
    ($node.status.conditions |
        Where-Object type -eq 'Ready' |
        Select-Object -First 1).status
}

function Get-TestNodeCpuPercent {
    $result = Invoke-KubectlText -Arguments @(
        'top', 'node', $TestNode, '--no-headers'
    ) -AllowFailure

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    $parts = $result.Text.Trim() -split '\s+'
    if ($parts.Count -lt 3) {
        return $null
    }

    $cpuPercentText = $parts[2].TrimEnd('%')
    $cpuPercent = 0
    if ([int]::TryParse($cpuPercentText, [ref]$cpuPercent)) {
        return $cpuPercent
    }

    return $null
}

function Export-SanitizedWorkloadSpec {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('job', 'cronjob')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-Step "Reading $Kind '$Name' from namespace '$Namespace'."
    $resource = Get-KubectlJson -Arguments @(
        'get', $Kind, $Name, '-n', $Namespace, '-o', 'json'
    )

    if ($Kind -eq 'job') {
        $controllerSpec = [ordered]@{
            parallelism            = $resource.spec.parallelism
            completions            = $resource.spec.completions
            completionMode         = $resource.spec.completionMode
            suspend                = $resource.spec.suspend
            backoffLimit           = $resource.spec.backoffLimit
            activeDeadlineSeconds  = $resource.spec.activeDeadlineSeconds
            ttlSecondsAfterFinished = $resource.spec.ttlSecondsAfterFinished
        }
        $podSpec = $resource.spec.template.spec
        $podLabels = $resource.spec.template.metadata.labels
    }
    else {
        $controllerSpec = [ordered]@{
            schedule                   = $resource.spec.schedule
            timeZone                   = $resource.spec.timeZone
            suspend                    = $resource.spec.suspend
            concurrencyPolicy          = $resource.spec.concurrencyPolicy
            successfulJobsHistoryLimit = $resource.spec.successfulJobsHistoryLimit
            failedJobsHistoryLimit     = $resource.spec.failedJobsHistoryLimit
            startingDeadlineSeconds    = $resource.spec.startingDeadlineSeconds
            jobParallelism             = $resource.spec.jobTemplate.spec.parallelism
            jobCompletions             = $resource.spec.jobTemplate.spec.completions
            jobBackoffLimit            = $resource.spec.jobTemplate.spec.backoffLimit
        }
        $podSpec = $resource.spec.jobTemplate.spec.template.spec
        $podLabels = $resource.spec.jobTemplate.spec.template.metadata.labels
    }

    $containers = @($podSpec.containers | ForEach-Object {
        [ordered]@{
            name            = $_.name
            image           = $_.image
            imagePullPolicy = $_.imagePullPolicy
            resources       = $_.resources
        }
    })

    $initContainers = @($podSpec.initContainers | ForEach-Object {
        [ordered]@{
            name            = $_.name
            image           = $_.image
            imagePullPolicy = $_.imagePullPolicy
            resources       = $_.resources
        }
    })

    $persistentVolumeClaims = @($podSpec.volumes | ForEach-Object {
        if ($_.persistentVolumeClaim) {
            [ordered]@{
                volumeName = $_.name
                claimName  = $_.persistentVolumeClaim.claimName
                readOnly   = $_.persistentVolumeClaim.readOnly
            }
        }
    } | Where-Object { $null -ne $_ })

    $sanitized = [ordered]@{
        apiVersion = $resource.apiVersion
        kind       = $resource.kind
        metadata   = [ordered]@{
            name      = $resource.metadata.name
            namespace = $resource.metadata.namespace
            uid       = $resource.metadata.uid
            labels    = $resource.metadata.labels
        }
        controller = $controllerSpec
        podTemplate = [ordered]@{
            labels                    = $podLabels
            schedulerName             = $podSpec.schedulerName
            priorityClassName         = $podSpec.priorityClassName
            runtimeClassName          = $podSpec.runtimeClassName
            nodeSelector              = $podSpec.nodeSelector
            affinity                  = $podSpec.affinity
            topologySpreadConstraints = $podSpec.topologySpreadConstraints
            tolerations               = $podSpec.tolerations
            overhead                  = $podSpec.overhead
            containers                = $containers
            initContainers            = $initContainers
            persistentVolumeClaims    = $persistentVolumeClaims
        }
    }

    $path = Join-Path $OutputRoot "$Kind-$Name-sanitized-scheduling-spec.json"
    $sanitized | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $path -Encoding utf8
    Write-RunLog "Saved sanitized $Kind scheduling specification to '$path'."
}

function Capture-NodeState {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('before', 'after')]
        [string]$Stage
    )

    $stagePath = Join-Path $OutputRoot $Stage
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null

    foreach ($node in $script:TargetNodes) {
        Write-Step "Capturing '$Stage' describe output for node '$node'."
        Invoke-KubectlText -Arguments @('describe', 'node', $node) `
            -OutputPath (Join-Path $stagePath "$node-describe.txt") | Out-Null
    }

    Write-Step "Capturing '$Stage' cluster-wide node inventory and labels."
    Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'wide', '--show-labels') `
        -OutputPath (Join-Path $stagePath 'all-nodes-wide.txt') | Out-Null
    Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'json') `
        -OutputPath (Join-Path $stagePath 'all-nodes.json') | Out-Null
    Write-Step "Capturing '$Stage' pods currently assigned to '$TestNode'."
    Invoke-KubectlText -Arguments @(
        'get', 'pods', '-A', '-o', 'wide',
        '--field-selector', "spec.nodeName=$TestNode"
    ) -OutputPath (Join-Path $stagePath 'test-node-pods-wide.txt') | Out-Null
    Write-Step "Capturing '$Stage' node usage snapshot."
    Invoke-KubectlText -Arguments @('top', 'nodes') `
        -OutputPath (Join-Path $stagePath 'top-nodes.txt') -AllowFailure | Out-Null
}

function Capture-Sample {
    param(
        [Parameter(Mandatory)]
        [int]$SampleNumber
    )

    $samplePath = Join-Path $OutputRoot ('samples\sample-{0:D3}' -f $SampleNumber)
    New-Item -ItemType Directory -Path $samplePath -Force | Out-Null

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $timestamp | Set-Content -LiteralPath (Join-Path $samplePath 'timestamp-utc.txt')

    Write-Step "Sample ${SampleNumber}: recording pod placement and declared requests in namespace '$Namespace'."
    Invoke-KubectlText -Arguments @(
        'get', 'pods', '-n', $Namespace, '-o',
        'custom-columns=POD:.metadata.name,UID:.metadata.uid,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,MEMORY_REQUEST:.spec.containers[*].resources.requests.memory,PHASE:.status.phase'
    ) -OutputPath (Join-Path $samplePath 'namespace-pods-placement.txt') | Out-Null

    Write-Step "Sample ${SampleNumber}: saving complete namespace pod JSON."
    Invoke-KubectlText -Arguments @('get', 'pods', '-n', $Namespace, '-o', 'json') `
        -OutputPath (Join-Path $samplePath 'namespace-pods.json') | Out-Null

    Write-Step "Sample ${SampleNumber}: capturing node CPU and memory usage."
    Invoke-KubectlText -Arguments @('top', 'nodes') `
        -OutputPath (Join-Path $samplePath 'top-nodes.txt') -AllowFailure | Out-Null

    Write-Step "Sample ${SampleNumber}: capturing namespace pod CPU usage sorted by CPU."
    Invoke-KubectlText -Arguments @(
        'top', 'pods', '-n', $Namespace, '--sort-by=cpu'
    ) -OutputPath (Join-Path $samplePath 'top-pods-by-cpu.txt') -AllowFailure | Out-Null

    Write-Step "Sample ${SampleNumber}: capturing namespace events."
    Invoke-KubectlText -Arguments @(
        'get', 'events', '-n', $Namespace, '--sort-by=.lastTimestamp'
    ) -OutputPath (Join-Path $samplePath 'events.txt') -AllowFailure | Out-Null

    Write-Step "Sample ${SampleNumber}: evaluating test-node CPU and Ready safety checks."
    $cpuPercent = Get-TestNodeCpuPercent
    $readyStatus = Get-NodeReadyStatus -NodeName $TestNode
    Write-RunLog "Sample $SampleNumber result: timestamp=$timestamp, nodeCPU=$cpuPercent%, nodeReady=$readyStatus."

    [pscustomobject]@{
        SampleNumber   = $SampleNumber
        TimestampUtc   = $timestamp
        NodeCpuPercent = $cpuPercent
        NodeReady      = $readyStatus
    }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$script:RunLogPath = Join-Path $OutputRoot 'run.log'
$script:TargetNodes = @($NodesToCapture)

$testStarted = $false
$testError = $null
$abortReason = $null
$cordonSucceeded = $false
$startUtc = $null
$endUtc = $null

try {
    Write-Phase -Number 1 -Name 'Preflight validation'

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl was not found in PATH.'
    }

    Write-Step 'Reading the active kubectl context.'
    $context = (Invoke-KubectlText -Arguments @('config', 'current-context')).Text.Trim()
    Write-RunLog "Active kubectl context: '$context'."
    Write-RunLog "Output directory: '$OutputRoot'."

    Write-Step "Validating namespace '$Namespace'."
    Invoke-KubectlText -Arguments @('get', 'namespace', $Namespace, '-o', 'name') | Out-Null

    Write-Step "Validating target nodes: $($script:TargetNodes -join ', ')."
    foreach ($node in $script:TargetNodes) {
        Assert-NodeExists -NodeName $node
    }

    Write-Step 'Validating permission to patch node schedulability.'
    $canPatchNodes = Get-KubectlCanI -Arguments @('patch', 'nodes')
    if ($canPatchNodes -ne 'yes') {
        throw "Current identity cannot patch nodes. kubectl auth can-i returned '$canPatchNodes'."
    }

    Write-Step "Validating permission to list pods in namespace '$Namespace'."
    $canListPods = Get-KubectlCanI -Arguments @(
        'list', 'pods', '-n', $Namespace
    )
    if ($canListPods -ne 'yes') {
        throw "Current identity cannot list pods in namespace '$Namespace'."
    }

    Write-Step "Validating that test node '$TestNode' is Ready."
    if ((Get-NodeReadyStatus -NodeName $TestNode) -ne 'True') {
        throw "Test node '$TestNode' is not Ready. Do not run the reproduction."
    }

    Write-Phase -Number 2 -Name 'Safety cordon and baseline capture'
    Write-Step "Cordoning test node '$TestNode' before baseline capture."
    Invoke-KubectlText -Arguments @('cordon', $TestNode) `
        -OutputPath (Join-Path $OutputRoot 'initial-cordon.txt') | Out-Null

    Write-Step 'Validating Metrics Server node metrics before uncordon.'
    Invoke-KubectlText -Arguments @('top', 'nodes') `
        -OutputPath (Join-Path $OutputRoot 'preflight-top-nodes.txt') | Out-Null
    Write-Step "Validating Metrics Server pod metrics in namespace '$Namespace'."
    Invoke-KubectlText -Arguments @(
        'top', 'pods', '-n', $Namespace, '--sort-by=cpu'
    ) -OutputPath (Join-Path $OutputRoot 'preflight-top-pods.txt') | Out-Null

    Write-Step 'Capturing complete pre-uncordon node state.'
    Capture-NodeState -Stage before

    Write-Phase -Number 3 -Name 'Workload scheduling specification'
    if ($JobName) {
        Export-SanitizedWorkloadSpec -Kind job -Name $JobName
    }
    elseif ($CronJobName) {
        Export-SanitizedWorkloadSpec -Kind cronjob -Name $CronJobName
    }
    else {
        Write-RunLog 'No Job or CronJob name supplied; workload specification export skipped.' 'WARN'
    }

    $metadata = [ordered]@{
        kubectlContext        = $context
        namespace             = $Namespace
        testNode          = $TestNode
        nodesToCapture        = $script:TargetNodes
        durationMinutes       = $DurationMinutes
        sampleIntervalSeconds = $SampleIntervalSeconds
        abortNodeCpuPercent   = $AbortNodeCpuPercent
        jobName               = $JobName
        cronJobName           = $CronJobName
        requestedStartUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
    $metadata | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $OutputRoot 'run-metadata.json') -Encoding utf8

    Write-Phase -Number 4 -Name 'Controlled uncordon and timed sampling'
    $startUtc = (Get-Date).ToUniversalTime()
    $startUtc.ToString('o') |
        Set-Content -LiteralPath (Join-Path $OutputRoot 'uncordon-start-utc.txt')
    Write-Step "Uncordoning '$TestNode' at $($startUtc.ToString('o'))."
    Invoke-KubectlText -Arguments @('uncordon', $TestNode) `
        -OutputPath (Join-Path $OutputRoot 'uncordon.txt') | Out-Null
    $testStarted = $true
    Write-RunLog "Observation window started: duration=$DurationMinutes minutes, sampleInterval=$SampleIntervalSeconds seconds, CPU abort threshold=$AbortNodeCpuPercent%."

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $sampleNumber = 0
    $sampleSummaries = [System.Collections.Generic.List[object]]::new()

    while ($stopwatch.Elapsed.TotalMinutes -lt $DurationMinutes) {
        $sampleNumber++
        Write-RunLog "SAMPLE $sampleNumber START: elapsed=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds."
        $summary = Capture-Sample -SampleNumber $sampleNumber
        $sampleSummaries.Add($summary)

        if ($summary.NodeReady -ne 'True') {
            $abortReason = "Test node Ready status changed to '$($summary.NodeReady)'."
            Write-RunLog $abortReason 'WARN'
            break
        }

        if ($null -ne $summary.NodeCpuPercent -and
            $summary.NodeCpuPercent -ge $AbortNodeCpuPercent) {
            $abortReason = "Test node CPU reached $($summary.NodeCpuPercent)%, meeting the $AbortNodeCpuPercent% abort threshold."
            Write-RunLog $abortReason 'WARN'
            break
        }

        $remainingSeconds = (
            [TimeSpan]::FromMinutes($DurationMinutes) - $stopwatch.Elapsed
        ).TotalSeconds
        if ($remainingSeconds -le 0) {
            break
        }

        $nextSampleStartSeconds = $sampleNumber * $SampleIntervalSeconds
        $secondsUntilNextSample = $nextSampleStartSeconds - $stopwatch.Elapsed.TotalSeconds

        if ($secondsUntilNextSample -gt 0) {
            $sleepSeconds = [Math]::Min(
                [int][Math]::Ceiling($secondsUntilNextSample),
                [int][Math]::Ceiling($remainingSeconds)
            )
            Write-RunLog "Sample $sampleNumber complete. Waiting $sleepSeconds seconds to maintain the $SampleIntervalSeconds-second start-to-start cadence."
            Start-Sleep -Seconds $sleepSeconds
        }
        else {
            Write-RunLog "Sample $sampleNumber collection exceeded the $SampleIntervalSeconds-second interval by $([Math]::Round(-$secondsUntilNextSample, 1)) seconds; starting the next sample without an additional wait." 'WARN'
        }
    }

    $stopwatch.Stop()
    Write-Step "Writing summary for $($sampleSummaries.Count) completed samples."
    $sampleSummaries |
        Export-Csv -LiteralPath (Join-Path $OutputRoot 'sample-summary.csv') `
            -NoTypeInformation -Encoding utf8
}
catch {
    $testError = $_
    Write-RunLog $_.Exception.Message 'ERROR'
}
finally {
    Write-Phase -Number 5 -Name 'Safety re-cordon and post-test capture'
    $endUtc = (Get-Date).ToUniversalTime()
    $endUtc.ToString('o') |
        Set-Content -LiteralPath (Join-Path $OutputRoot 'cordon-end-utc.txt')

    Write-Step "Re-cordoning '$TestNode' at $($endUtc.ToString('o'))."
    $cordonResult = Invoke-KubectlText -Arguments @('cordon', $TestNode) `
        -OutputPath (Join-Path $OutputRoot 'final-cordon.txt') -AllowFailure `
        -MaxAttempts 5 -RetryDelaySeconds 5
    $cordonSucceeded = $cordonResult.ExitCode -eq 0

    if (-not $cordonSucceeded) {
        Write-RunLog "CRITICAL: Failed to re-cordon '$TestNode'. Manual intervention is required." 'ERROR'
    }

    try {
        Write-Step 'Capturing complete post-test node state.'
        Capture-NodeState -Stage after
    }
    catch {
        Write-RunLog "Post-test capture failed: $($_.Exception.Message)" 'ERROR'
        if (-not $testError) {
            $testError = $_
        }
    }
}

Write-Phase -Number 6 -Name 'Result summary'
$result = [ordered]@{
    startUtc        = if ($startUtc) { $startUtc.ToString('o') } else { $null }
    endUtc          = if ($endUtc) { $endUtc.ToString('o') } else { $null }
    durationMinutes = if ($startUtc -and $endUtc) {
        [Math]::Round(($endUtc - $startUtc).TotalMinutes, 2)
    }
    else {
        $null
    }
    abortReason     = $abortReason
    cordonSucceeded = $cordonSucceeded
    outputRoot      = $OutputRoot
    testError       = if ($testError) { $testError.Exception.Message } else { $null }
}
$result | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $OutputRoot 'result.json') -Encoding utf8

if (-not $cordonSucceeded) {
    throw "Failed to re-cordon '$TestNode'. Run: kubectl cordon $TestNode"
}

if ($testError) {
    throw $testError
}

Write-RunLog "Collection completed. Evidence saved to '$OutputRoot'."
Write-RunLog "Final safety state: test node cordoned=$cordonSucceeded."
Write-RunLog "Test interval: start=$($result.startUtc), end=$($result.endUtc), durationMinutes=$($result.durationMinutes)."
if ($abortReason) {
    Write-Warning "The test ended early: $abortReason"
}
