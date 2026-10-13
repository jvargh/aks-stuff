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

This validates the collector without creating a workload. The first node in
`-NodesToCapture` is the test node. The script briefly uncordons that node,
captures all listed nodes, and returns the first node to the cordoned state.

The run normally takes three to five minutes because pre-test and post-test
evidence collection occurs outside the two-minute observation window.

### Verify the Final Node State

```powershell
kubectl get node aks-userpool-vmss-node-a `
  -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status,UNSCHEDULABLE:.spec.unschedulable"
```

Expected:

```text
NAME                               READY   UNSCHEDULABLE
aks-userpool-vmss-node-a   True    true
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

The following output was captured after the interface was reduced to the single
ordered `-NodesToCapture` option. Repetitive collection-step lines are
abbreviated. Evidence folders and raw scheduler logs are intentionally not included in this repository.

```text
========== PHASE 1 - Preflight validation ==========
2026-10-13T05:54:08.0438287Z [INFO] PHASE 1 START: Preflight validation
2026-10-13T05:54:08.3421986Z [INFO] Active kubectl context: 'aks-test-cluster'.
2026-10-13T05:54:11.7393879Z [INFO] STEP: Validating target nodes:
  aks-userpool-vmss-node-a,
  aks-userpool-vmss-node-b,
  aks-userpool-vmss-node-c,
  aks-systempool-vmss-node-s.

========== PHASE 2 - Safety cordon and baseline capture ==========
2026-10-13T05:54:35.3495138Z [INFO] PHASE 2 START: Safety cordon and baseline capture
2026-10-13T05:54:35.3626838Z [INFO] STEP: Cordoning test node before baseline capture.
...

========== PHASE 3 - Workload scheduling specification ==========
2026-10-13T05:55:30.7562398Z [INFO] PHASE 3 START: Workload scheduling specification
2026-10-13T05:55:30.7736158Z [WARN] No Job or CronJob name supplied; workload specification export skipped.

========== PHASE 4 - Controlled uncordon and timed sampling ==========
2026-10-13T05:55:30.8072222Z [INFO] PHASE 4 START: Controlled uncordon and timed sampling
2026-10-13T05:55:34.5687720Z [INFO] SAMPLE 1 START: elapsed=0 seconds.
2026-10-13T05:56:03.7231129Z [INFO] Sample 1 result: nodeCPU=8%, nodeReady=True.
2026-10-13T05:56:04.8025036Z [INFO] SAMPLE 2 START: elapsed=30.2 seconds.
2026-10-13T05:56:34.9651954Z [INFO] Sample 2 result: nodeCPU=8%, nodeReady=True.
2026-10-13T05:56:35.0026915Z [INFO] SAMPLE 3 START: elapsed=60.4 seconds.
2026-10-13T05:57:03.9844526Z [INFO] Sample 3 result: nodeCPU=8%, nodeReady=True.
2026-10-13T05:57:05.0155911Z [INFO] SAMPLE 4 START: elapsed=90.5 seconds.
2026-10-13T05:57:09.7716217Z [WARN] kubectl attempt 1/3 failed for 'get pods -n test-namespace -o json'. Retrying in 3 seconds.
2026-10-13T05:57:36.8270713Z [INFO] Sample 4 result: nodeCPU=8%, nodeReady=True.

========== PHASE 5 - Safety re-cordon and post-test capture ==========
2026-10-13T05:57:36.8698992Z [INFO] PHASE 5 START: Safety re-cordon and post-test capture
2026-10-13T05:57:36.8869540Z [INFO] STEP: Re-cordoning test node.
...

========== PHASE 6 - Result summary ==========
2026-10-13T05:58:23.7547872Z [INFO] PHASE 6 START: Result summary
2026-10-13T05:58:23.7794854Z [INFO] Collection completed.
2026-10-13T05:58:23.7950225Z [INFO] Final safety state: test node cordoned=True.
2026-10-13T05:58:23.8175471Z [INFO] Test interval:
  start=2026-10-13T05:55:30.8210541Z,
  end=2026-10-13T05:57:36.8869540Z,
  durationMinutes=2.1.
```

Warnings followed by a successful retry are expected for transient API errors.
The run is successful when Phase 6 reports `Collection completed` and
`test node cordoned=True`.

### Successful `run-metadata.json`

This confirms the single-option behavior. The first entry is the test node;
all later entries are capture-only nodes.

```json
{
  "kubectlContext": "aks-test-cluster",
  "namespace": "test-namespace",
  "testNode": "aks-userpool-vmss-node-a",
  "nodesToCapture": [
    "aks-userpool-vmss-node-a",
    "aks-userpool-vmss-node-b",
    "aks-userpool-vmss-node-c",
    "aks-systempool-vmss-node-s"
  ],
  "durationMinutes": 2,
  "sampleIntervalSeconds": 30,
  "abortNodeCpuPercent": 90
}
```

### Successful `result.json`

```json
{
  "startUtc": "2026-10-13T05:55:30.8210541Z",
  "endUtc": "2026-10-13T05:57:36.8869540Z",
  "durationMinutes": 2.1,
  "abortReason": null,
  "cordonSucceeded": true,
  "outputRoot": "C:\\Users\\<user>\\Downloads\\scheduler-log-collector\\aks-test-output",
  "testError": null
}
```

Success indicators:

- `abortReason` is `null`;
- `cordonSucceeded` is `true`;
- `testError` is `null`.

### Successful `sample-summary.csv`

```csv
"SampleNumber","TimestampUtc","NodeCpuPercent","NodeReady"
"1","2026-10-13T05:55:34.5877017Z","8","True"
"2","2026-10-13T05:56:04.8198588Z","8","True"
"3","2026-10-13T05:56:35.0185801Z","8","True"
"4","2026-10-13T05:57:05.0326131Z","8","True"
```

Every sample should normally show `NodeReady=True`. If the CPU threshold is
reached or Ready changes, the test ends early and the reason appears in
`abortReason` and `run.log`.

## What It Does

1. Validates `kubectl`, context, namespace, nodes, permissions, node readiness,
   and Metrics Server access.
2. Cordon-protects node `aks-compute-vmss-node-a`.
3. Captures `kubectl describe node` for nodes `...000007`, `...000008`, and
   `...000005`.
4. Optionally exports a sanitized Job or CronJob scheduling specification.
5. Records the exact UTC uncordon timestamp.
6. Uncordons node `...000007`.
7. Samples every 60 seconds for 10 minutes by default:
   - pod placement and requests;
   - complete namespace pod JSON;
   - `kubectl top nodes`;
   - `kubectl top pods`;
   - namespace events;
   - test-node CPU and Ready status.
8. Stops early if test-node CPU reaches the configured threshold or the
   node stops reporting Ready.
9. Always attempts to re-cordon the node in a `finally` block.
10. Captures post-test node state and writes a result summary.

## Console and Run-Log Progress

The script emits phase banners and step-level status to both the console and
`run.log`:

1. Preflight validation
2. Safety cordon and baseline capture
3. Workload scheduling specification
4. Controlled uncordon and timed sampling
5. Safety re-cordon and post-test capture
6. Result summary

Each sample reports the actions being collected and then prints the affected
node's observed CPU percentage and Ready status. It also announces the wait
until the next sample, early-abort reason, final cordon result, test interval,
and output directory.

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
Test node: first entry, aks-userpool-vmss-node-a
Duration: 2 minutes
Requested sample cadence: 30 seconds
CPU abort threshold: 90%
```

Result:

- all six phases completed;
- four samples were captured;
- observed sample-start intervals were 30.23, 30.20, and 30.01 seconds;
- transient API connection resets were retried successfully;
- the node remained Ready;
- test-node CPU stayed at 8%;
- no abort threshold was reached;
- 51 evidence files were produced;
- four node descriptions were captured before and after the test;
- the final safety cordon succeeded;
- the target node finished Ready and unschedulable.

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

Node order defines behavior:

| Position | Role | Schedulability changed? | Evidence collected |
|---|---|---|---|
| First node | Test node | **Yes**. Cordoned for baseline, uncordoned during sampling, and re-cordoned at the end | Detailed before/after node output and safety checks |
| Every later node | Capture-only node | No | Detailed before/after node output |

For the example above:

```text
node007 - test node; cordoned, uncordoned, then re-cordoned
node008 - captured only
node005 - captured only
```

To capture exactly three nodes, provide exactly three node names. To capture
more feasible nodes, append more names. The script always changes
schedulability only for the first entry.

### Parameter descriptions

| Parameter | Required | Default | Purpose |
|---|---|---|---|
| `-Namespace` | Yes | None | Namespace whose pod placement, requests, usage, and events are sampled |
| `-NodesToCapture` | Yes | None | Ordered list of nodes. The first is the test node; all remaining nodes are capture-only |
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

**Purpose:** Use the first node as the test node and capture detailed
before/after descriptions for all three nodes.

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
reproduction script. The reproduction script always changes the
first node's schedulability.

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

**Purpose:** During a scheduler reproduction, capture every node that was
feasible for the target workload. The first node is the test node; every
listed node receives detailed before/after captures.

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
├── before/
├── samples/
│   ├── sample-001/
│   ├── sample-002/
│   └── ...
├── after/
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
