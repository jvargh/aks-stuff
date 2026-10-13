# AKS Scheduler Reproduction Automation

## Script

[`Collect-AksSchedulerRepro.ps1`](./Collect-AksSchedulerRepro.ps1) automates the
requested 8-10-minute AKS scheduler evidence collection.

## Fastest Safe Test

Open PowerShell and move to the collector directory:

```powershell
Set-Location "$env:USERPROFILE\Downloads\scheduler-log-collector"
```

Select the validated test cluster:

```powershell
kubectl config use-context aks-test-cluster
```

Run the two-minute validation:

```powershell
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace test-namespace `
  -NodesToCapture @(
    "aks-userpool-vmss-node-a",
    "aks-userpool-vmss-node-b",
    "aks-userpool-vmss-node-c",
    "aks-systempool-vmss-node-s"
  ) `
  -DurationMinutes 2 `
  -SampleIntervalSeconds 30 `
  -AbortNodeCpuPercent 90 `
  -AcknowledgeImpact
```

This validates the collector without creating a workload. Every node in
`-NodesToCapture` follows the same workflow: capture, cordon, capture while
cordoned, uncordon, sample, re-cordon, and final capture.

The run can take six to ten minutes for four nodes because three detailed node
captures and safety operations occur outside the two-minute observation window.

### Verify the Final Node State

```powershell
$nodes = @(
  "aks-userpool-vmss-node-a",
  "aks-userpool-vmss-node-b",
  "aks-userpool-vmss-node-c",
  "aks-systempool-vmss-node-s"
)

kubectl get nodes $nodes `
  -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status,UNSCHEDULABLE:.spec.unschedulable"
```

Expected:

```text
NAME                               READY   UNSCHEDULABLE
aks-systempool-vmss-node-s    True    true
aks-userpool-vmss-node-a   True    true
aks-userpool-vmss-node-b   True    true
aks-userpool-vmss-node-c   True    true
```

### Find the Latest Evidence Directory

```powershell
$latest = Get-ChildItem -Directory -Filter "aks-scheduler-repro-*" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

$latest.FullName
Get-Content (Join-Path $latest.FullName "result.json")
Get-Content (Join-Path $latest.FullName "sample-summary.csv")
Get-Content (Join-Path $latest.FullName "run.log")
```

> If `-OutputRoot` was used, inspect that directory instead of searching for
> `aks-scheduler-repro-*`.

## What a Successful Run Looks Like

The following output was captured with the final all-node workflow. Repetitive
capture steps are abbreviated. The complete run transcript was reviewed during validation; raw logs are intentionally not published.

```text
========== PHASE 1 - Preflight validation ==========
2026-10-13T13:02:59.4298016Z [INFO] PHASE 1 START: Preflight validation
2026-10-13T13:02:59.6452183Z [INFO] Active kubectl context: 'aks-test-cluster'.
2026-10-13T13:03:02.8590043Z [INFO] STEP: Validating target nodes:
  aks-userpool-vmss-node-a,
  aks-userpool-vmss-node-b,
  aks-userpool-vmss-node-c,
  aks-systempool-vmss-node-s.

========== PHASE 2 - Pre-cordon capture, safety cordon, and cordoned baseline ==========
2026-10-13T13:04:20.9139560Z [INFO] PHASE 2 START: Pre-cordon capture, safety cordon, and cordoned baseline
...
2026-10-13T13:05:26.8817441Z [INFO] STEP: Cordoning node 'aks-userpool-vmss-node-a'.
2026-10-13T13:05:30.1049975Z [INFO] STEP: Cordoning node 'aks-userpool-vmss-node-b'.
2026-10-13T13:05:33.4917386Z [INFO] STEP: Cordoning node 'aks-userpool-vmss-node-c'.
2026-10-13T13:05:36.5879719Z [INFO] STEP: Cordoning node 'aks-systempool-vmss-node-s'.
...

========== PHASE 3 - Workload scheduling specification ==========
2026-10-13T13:06:37.2115122Z [INFO] PHASE 3 START: Workload scheduling specification
2026-10-13T13:06:37.2284470Z [WARN] No Job or CronJob name supplied; workload specification export skipped.

========== PHASE 4 - Controlled uncordon and timed sampling ==========
2026-10-13T13:06:37.2609417Z [INFO] PHASE 4 START: Controlled uncordon and timed sampling
2026-10-13T13:06:37.2795210Z [INFO] STEP: Uncordoning node 'aks-userpool-vmss-node-a'.
2026-10-13T13:06:40.7778165Z [INFO] STEP: Uncordoning node 'aks-userpool-vmss-node-b'.
2026-10-13T13:06:44.1866710Z [INFO] STEP: Uncordoning node 'aks-userpool-vmss-node-c'.
2026-10-13T13:06:47.4845054Z [INFO] STEP: Uncordoning node 'aks-systempool-vmss-node-s'.

2026-10-13T13:06:53.9991648Z [INFO] SAMPLE 1 START: elapsed=0 seconds.
2026-10-13T13:07:20.8728281Z [INFO] Sample 1 result: node=aks-userpool-vmss-node-a, nodeCPU=9%, nodeReady=True.
2026-10-13T13:07:20.8883760Z [INFO] Sample 1 result: node=aks-userpool-vmss-node-b, nodeCPU=8%, nodeReady=True.
2026-10-13T13:07:20.9037741Z [INFO] Sample 1 result: node=aks-userpool-vmss-node-c, nodeCPU=7%, nodeReady=True.
2026-10-13T13:07:20.9190496Z [INFO] Sample 1 result: node=aks-systempool-vmss-node-s, nodeCPU=6%, nodeReady=True.

2026-10-13T13:07:24.8836635Z [INFO] SAMPLE 2 START: elapsed=30.9 seconds.
2026-10-13T13:07:50.7395612Z [INFO] Sample 2 completed for all four nodes.
2026-10-13T13:07:54.7564953Z [INFO] SAMPLE 3 START: elapsed=60.8 seconds.
2026-10-13T13:08:20.2072027Z [INFO] Sample 3 completed for all four nodes.
2026-10-13T13:08:24.2184244Z [INFO] SAMPLE 4 START: elapsed=90.2 seconds.
2026-10-13T13:08:50.3081012Z [INFO] Sample 4 completed for all four nodes.

========== PHASE 5 - Safety re-cordon and post-test capture ==========
2026-10-13T13:08:54.3637826Z [INFO] PHASE 5 START: Safety re-cordon and post-test capture
2026-10-13T13:08:54.3783040Z [INFO] STEP: Re-cordoning node 'aks-userpool-vmss-node-a'.
2026-10-13T13:08:58.1323615Z [INFO] STEP: Re-cordoning node 'aks-userpool-vmss-node-b'.
2026-10-13T13:09:01.9798287Z [INFO] STEP: Re-cordoning node 'aks-userpool-vmss-node-c'.
2026-10-13T13:09:05.7388765Z [INFO] STEP: Re-cordoning node 'aks-systempool-vmss-node-s'.
...

========== PHASE 6 - Result summary ==========
2026-10-13T13:10:01.5907559Z [INFO] PHASE 6 START: Result summary
2026-10-13T13:10:01.6159537Z [INFO] Collection completed.
2026-10-13T13:10:01.6297427Z [INFO] Final safety state: all listed nodes cordoned=True.
```

The run is successful when Phase 6 reports `Collection completed`,
`all listed nodes cordoned=True`, and every entry in `cordonResults` is `true`.

### Successful `run-metadata.json`

```json
{
  "kubectlContext": "aks-test-cluster",
  "namespace": "test-namespace",
  "nodesToCapture": [
    "aks-userpool-vmss-node-a",
    "aks-userpool-vmss-node-b",
    "aks-userpool-vmss-node-c",
    "aks-systempool-vmss-node-s"
  ],
  "nodeWorkflow": "all nodes: pre-cordon capture, cordon, cordoned capture, uncordon, timed sampling, re-cordon, final capture",
  "durationMinutes": 2,
  "sampleIntervalSeconds": 30,
  "abortNodeCpuPercent": 90
}
```

### Successful `result.json`

```json
{
  "startUtc": "2026-10-13T13:06:37.2779106Z",
  "endUtc": "2026-10-13T13:08:54.3760425Z",
  "durationMinutes": 2.28,
  "abortReason": null,
  "cordonSucceeded": true,
  "cordonResults": {
    "aks-userpool-vmss-node-a": true,
    "aks-userpool-vmss-node-b": true,
    "aks-userpool-vmss-node-c": true,
    "aks-systempool-vmss-node-s": true
  },
  "outputRoot": "C:\\Users\\<user>\\Downloads\\scheduler-log-collector\\aks-test-output",
  "testError": null
}
```

### Successful `sample-summary.csv`

Each sample contains one row per listed node:

```csv
"SampleNumber","TimestampUtc","NodeName","NodeCpuPercent","NodeReady"
"1","2026-10-13T13:06:54.0346699Z","aks-userpool-vmss-node-a","9","True"
"1","2026-10-13T13:06:54.0346699Z","aks-userpool-vmss-node-b","8","True"
"1","2026-10-13T13:06:54.0346699Z","aks-userpool-vmss-node-c","7","True"
"1","2026-10-13T13:06:54.0346699Z","aks-systempool-vmss-node-s","6","True"
...
"4","2026-10-13T13:08:24.2523758Z","aks-userpool-vmss-node-a","9","True"
"4","2026-10-13T13:08:24.2523758Z","aks-userpool-vmss-node-b","9","True"
"4","2026-10-13T13:08:24.2523758Z","aks-userpool-vmss-node-c","7","True"
"4","2026-10-13T13:08:24.2523758Z","aks-systempool-vmss-node-s","7","True"
```

If any node reaches the CPU threshold or stops reporting Ready, the test ends
early and that node is named in `abortReason` and `run.log`.

## What It Does

1. Validates `kubectl`, context, namespace, nodes, permissions, node readiness,
   and Metrics Server access.
2. Captures every listed node before cordon.
3. Cordons every listed node.
4. Captures every listed node while cordoned.
5. Optionally exports a sanitized Job or CronJob scheduling specification.
6. Records the exact UTC uncordon timestamp.
7. Uncordons every listed node.
8. Samples every 60 seconds for 10 minutes by default:
   - pod placement and requests;
   - complete namespace pod JSON;
   - `kubectl top nodes`;
   - `kubectl top pods`;
   - namespace events;
   - per-node CPU and Ready status for every listed node.
9. Stops early if any listed node reaches the CPU threshold or stops reporting
   Ready.
10. Always attempts to re-cordon every listed node in a `finally` block.
11. Captures final state for every listed node and writes per-node results.

## Console and Run-Log Progress

The script emits phase banners and step-level status to both the console and
`run.log`:

1. Preflight validation
2. Safety cordon and baseline capture
3. Workload scheduling specification
4. Controlled uncordon and timed sampling
5. Safety re-cordon and post-test capture
6. Result summary

Each sample reports the actions being collected and then prints every listed
node's observed CPU percentage and Ready status. It also announces the wait
until the next sample, early-abort reason, per-node final cordon results, test
interval, and output directory.

Transient `kubectl` failures are retried up to three times. The final safety
cordon is retried up to five times with a five-second delay.

## Live Validation

The script was validated against AKS cluster `aks-test-cluster` on October 13, 2026.

Test parameters:

```text
Namespace: test-namespace
NodesToCapture, in order:
  aks-userpool-vmss-node-a
  aks-userpool-vmss-node-b
  aks-userpool-vmss-node-c
  aks-systempool-vmss-node-s
Duration: 2 minutes
Requested sample cadence: 30 seconds
CPU abort threshold: 90%
```

Result:

- all six phases completed;
- four samples were captured for all four nodes, producing 16 sample rows;
- observed sample-start intervals were approximately 30.88, 29.87, and 29.46 seconds;
- transient API connection resets were retried successfully;
- all nodes remained Ready;
- node CPU remained between 6% and 9%;
- no abort threshold was reached;
- 81 evidence files were produced;
- four node descriptions were captured at pre-cordon, cordoned-baseline, and
  final stages;
- all four final safety cordons succeeded;
- every listed node finished Ready and unschedulable.

The validation evidence bundle was reviewed before publication but is intentionally not included in this repository.

## Safety Requirements

The script changes node schedulability. Run it only when:

- a change window is approved;
- a rollback owner is present;
- peer-node capacity is sufficient;
- application owners accept the reproduction risk;
- scheduler, audit, and historical telemetry collection are enabled.

The mandatory `-AcknowledgeImpact` switch prevents accidental execution.

The script does not drain or delete pods.

## `NodesToCapture` Reference

### How the node list works

The script has one node option:

```powershell
-NodesToCapture @("node007", "node008", "node005")
```

Every listed node follows the same behavior:

```text
node007 - captured, cordoned, captured, uncordoned, sampled, re-cordoned, captured
node008 - captured, cordoned, captured, uncordoned, sampled, re-cordoned, captured
node005 - captured, cordoned, captured, uncordoned, sampled, re-cordoned, captured
```

Node order does not change behavior. To process exactly three nodes, provide
exactly three names. To process more feasible nodes, append more names.

### Parameter descriptions

| Parameter | Required | Default | Purpose |
|---|---|---|---|
| `-Namespace` | Yes | None | Namespace whose pod placement, requests, usage, and events are sampled |
| `-NodesToCapture` | Yes | None | One or many nodes that all receive the complete capture/cordon/uncordon/re-cordon workflow |
| `-DurationMinutes` | No | 10 | Length of the uncordoned observation window |
| `-SampleIntervalSeconds` | No | 60 | Target start-to-start interval between samples |
| `-AbortNodeCpuPercent` | No | 90 | Re-cordon early when test-node CPU reaches this value |
| `-JobName` | No | None | Exports a sanitized scheduling specification for one Job |
| `-CronJobName` | No | None | Exports a sanitized scheduling specification for one CronJob |
| `-OutputRoot` | No | Timestamped directory under the current path | Overrides the evidence directory |
| `-AcknowledgeImpact` | Yes | False | Confirms approval to change test-node schedulability |

`-JobName` and `-CronJobName` are optional and mutually exclusive. Omitting
both does not prevent sampling; it only skips workload-template export.

## Basic Usage

### Capture a Job

**Purpose:** Run the full reproduction and export the selected Job's sanitized
scheduling configuration.

```powershell
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace workload-namespace `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c'
  ) `
  -JobName <job-name> `
  -AcknowledgeImpact
```

### Capture a CronJob

**Purpose:** Run the full reproduction and export the selected CronJob's
schedule, concurrency settings, Job settings, and pod placement configuration.

```powershell
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace workload-namespace `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c'
  ) `
  -CronJobName <cronjob-name> `
  -DurationMinutes 8 `
  -SampleIntervalSeconds 30 `
  -AbortNodeCpuPercent 90 `
  -AcknowledgeImpact
```

### Capture Exactly Three Nodes During a Reproduction

**Purpose:** Apply the same capture, cordon, uncordon, sample, and re-cordon
workflow to exactly three nodes.

```powershell
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace <namespace> `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c'
  ) `
  -AcknowledgeImpact
```

### Capture Three Nodes Without Cordon or Uncordon

If the goal is only to collect three node outputs, do **not** use the
reproduction script. The reproduction script changes schedulability for every
node in `-NodesToCapture`.

Use this read-only PowerShell block instead:

```powershell
$nodes = @(
  'aks-compute-vmss-node-a',
  'aks-compute-vmss-node-b',
  'aks-compute-vmss-node-c'
)

$timestamp = Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ'
$output = Join-Path $PWD "aks-node-comparison-$timestamp"
New-Item -ItemType Directory -Path $output -Force | Out-Null

Get-Date -AsUTC -Format o |
  Set-Content (Join-Path $output 'timestamp-utc.txt')

foreach ($node in $nodes) {
  kubectl describe node $node |
    Set-Content (Join-Path $output "$node-describe.txt")

  kubectl get node $node -o json |
    Set-Content (Join-Path $output "$node.json")

  kubectl get pods -A -o wide --field-selector "spec.nodeName=$node" |
    Set-Content (Join-Path $output "$node-pods-wide.txt")
}

kubectl top nodes |
  Set-Content (Join-Path $output 'top-nodes.txt')

Write-Host "Read-only node evidence saved to: $output"
```

This read-only collection produces:

- one `kubectl describe node` file per node;
- one complete node JSON file per node;
- one assigned-pod list per node;
- one cluster-wide `kubectl top nodes` snapshot;
- one UTC timestamp.

It does not:

- cordon or uncordon nodes;
- reproduce scheduler placement;
- collect repeated time-series samples;
- export a Job or CronJob template.

### Capture More Feasible Nodes

**Purpose:** During a scheduler reproduction, apply the same workflow to every
node that was feasible for the target workload.

```powershell
.\Collect-AksSchedulerRepro.ps1 `
  -Namespace <namespace> `
  -NodesToCapture @(
    'aks-compute-vmss-node-a',
    'aks-compute-vmss-node-b',
    'aks-compute-vmss-node-c',
    '<another-feasible-node>'
  ) `
  -AcknowledgeImpact
```

## Output Structure

The script creates a timestamped directory:

```text
aks-scheduler-repro-YYYYMMDDTHHMMSSZ/
├── pre-cordon/
│   ├── <node>-describe.txt
│   └── <node>-pods-wide.txt
├── before/
│   ├── <node>-describe.txt
│   └── <node>-pods-wide.txt
├── samples/
│   ├── sample-001/
│   │   ├── all-nodes.json
│   │   ├── top-nodes.txt
│   │   └── ...
│   ├── sample-002/
│   └── ...
├── after/
│   ├── <node>-describe.txt
│   └── <node>-pods-wide.txt
├── initial-cordon-<node>.txt
├── uncordon-<node>.txt
├── final-cordon-<node>.txt
├── run.log
├── run-metadata.json
├── sample-summary.csv
├── uncordon-start-utc.txt
├── cordon-end-utc.txt
├── result.json
└── <job-or-cronjob>-sanitized-scheduling-spec.json
```

## Sanitized Workload Export

The sanitized Job or CronJob export includes:

- resource requests and limits;
- image and image pull policy;
- init containers;
- node selectors;
- affinity;
- topology-spread constraints;
- tolerations;
- priority class;
- scheduler name;
- RuntimeClass and pod overhead;
- persistent-volume claim names;
- Job parallelism or CronJob concurrency.

It excludes:

- environment variables;
- environment sources;
- secret values;
- ConfigMap contents;
- command-line credentials;
- full volume secret/configuration definitions.

Review the sanitized file before sharing.

## Important Limitations

- `kubectl top` is recent Metrics Server data, not historical forensic
  telemetry.
- The pod custom-column output does not calculate effective scheduler requests
  across init containers and pod overhead. Use the saved pod JSON plus
  Prometheus/kube-state-metrics for complete calculation.
- The script does not capture scheduler plugin scores unless those logs are
  already available through AKS control-plane diagnostics.
- Capturing only three nodes may be insufficient. Add all feasible nodes with
  `-NodesToCapture`.
- CPU is the only automatic numeric stop condition. Application latency, PSI,
  OOM, and readiness thresholds must still be monitored through the approved
  dashboard and operator runbook.

## Decision Guidance

Placement is consistent with normal scheduling if:

- node `...000007` had more scheduler-visible requested capacity;
- workload affinity, labels, topology, tolerations, storage, priority, or image
  locality favored it;
- peer nodes were not equivalently eligible.

Escalation is stronger if:

- all feasible nodes had materially equivalent scheduler inputs;
- node `...000007` again received a disproportionate share in both cycles;
- no documented scheduler input explains the difference;
- raw timestamps, pod UIDs, node state, and metrics support the reproduction.
