### 5. Expected application and user impact

**Question:** During a DNS server failure, should applications expect lookup failures, increased latency, or user impact before failover occurs?

#### Table of Contents

- [Introduction](#introduction)
- [Answer](#answer)
- [Theory](#theory)
  - [Failure path and application mediation](#failure-path-and-application-mediation)
  - [AKS support boundary](#aks-support-boundary)
- [Items to Validate](#items-to-validate)
- [Dedicated application-impact validation suite](#dedicated-application-impact-validation-suite)
  - [Common prerequisites](#common-prerequisites)
  - [IMP-00-BASELINE](#imp-00-baseline)
  - [IMP-01-FIRST-FAILURE](#imp-01-first-failure)
  - [IMP-02-BUDGETS](#imp-02-budgets)
  - [IMP-03-LEARNED-UNHEALTHY](#imp-03-learned-unhealthy)
  - [IMP-04-SERVFAIL](#imp-04-servfail)
  - [IMP-05-ALL-UNAVAILABLE](#imp-05-all-unavailable)
  - [IMP-06-RECOVERY](#imp-06-recovery)
  - [IMP-07-RUNTIME-CACHE](#imp-07-runtime-cache)
  - [IMP-08-CONNECTION-REUSE](#imp-08-connection-reuse)
  - [IMP-09-RETRY-AMPLIFICATION](#imp-09-retry-amplification)
  - [IMP-10-TRANSPORTS](#imp-10-transports)
  - [IMP-11-BOUNDED-LOAD](#imp-11-bounded-load)
  - [IMP-12-DNS-OBSERVABILITY](#imp-12-dns-observability)
  - [IMP-13-APPLICATION-OBSERVABILITY](#imp-13-application-observability)
  - [IMP-14-SLO-MAPPING](#imp-14-slo-mapping)
  - [IMP-15-NEGATIVE-CONTROLS](#imp-15-negative-controls)
  - [IMP-16-REPEATABILITY](#imp-16-repeatability)
  - [IMP-17-CLEANUP](#imp-17-cleanup)
- [Evidence handling](#evidence-handling)
- [Limitations](#limitations)
- [Conclusion](#conclusion)
- [Authoritative links](#authoritative-links)

#### Introduction

DNS failover is not instant or necessarily invisible to an application. A caller can observe extra lookup latency, a DNS error, or expiration of its own deadline before a healthy secondary answer arrives. Runtime caches, connection pools, retries, and total request budgets then determine whether that DNS event becomes a failed logical request or user-visible latency.

The DNS-level statements below were revalidated on `aks01day2` on 2026-09-24 in the disposable namespace `coredns-failover-validation-imp`. The suite was generated from the existing lab manifest by namespace replacement and configured with dynamically discovered upstream Service IPs. It did not mutate `kube-system`. Exact results are retained in [the dedicated IMP result](../validation/results/aks01day2-impact-20260924.md).

#### Answer

Applications should expect either increased lookup latency or lookup failure during an upstream DNS failure, and user impact is possible before failover succeeds. In the tested CoreDNS 1.13.1 image, a fresh UDP query encountering silent loss waited about two seconds before receiving the secondary answer. One- and two-second client budgets expired; a five-second budget succeeded. Once the failed upstream was learned unhealthy, later uncached queries completed in 4-16 ms in that run.

The failure mode matters. A returned `SERVFAIL` was immediately returned by the default resolver and reached the secondary only when `failover SERVFAIL` was explicitly configured. With both synthetic upstreams unavailable, the bounded client received no response. Cold forced-TCP loss took 29,996 ms and returned `SERVFAIL`, unlike the approximately two-second UDP path. These measurements are controlled observations, not platform guarantees.

No representative application workload was supplied. Therefore runtime cache behavior, connection reuse, retry amplification, application telemetry correlation, and SLO impact remain blocked/proposed and are not established. The DNS evidence must not be relabeled as user-impact evidence.

#### Theory

##### Failure path and application mediation

CoreDNS `forward` reuses connections, supports UDP and TCP, and performs in-band health checks after network errors. In the version-matched implementation, the read timeout is fixed at two seconds, while TCP dial timeout is adaptive and bounded. A silent UDP loss can therefore consume the read deadline before another upstream is attempted; a fresh TCP dial into silent loss can take much longer. A DNS response code is not a transport failure: `SERVFAIL` is returned unless a configured `failover` rule names it.

Health is process-local and temporal. With `max_fails 1`, the isolated resolver marked the failed upstream unhealthy after its health-check failure, allowing later queries to avoid the cold delay. A different replica or a restarted process can encounter its own first failure. When all upstreams are unhealthy, CoreDNS can still attempt an upstream, so client deadlines remain essential.

Application mediation prevents a one-to-one mapping from DNS result to user result:

- A warm positive runtime or OS cache can avoid DNS until expiry, while negative caching can extend a failure.
- Existing HTTP, HTTP/2, gRPC, database, or other pooled connections can avoid a new lookup.
- Application, SDK, sidecar, proxy, ingress, and caller retries can recover a request or amplify load and tail latency.
- A total request deadline can expire before CoreDNS finishes its fallback path.
- Concurrent cold lookups can create retry bursts not represented by a single `dig`.

##### AKS support boundary

The namespace-local resolver demonstrates upstream behavior without changing managed CoreDNS. AKS documentation states that the main managed Corefile cannot be modified directly and that supported customization uses the `coredns-custom` ConfigMap with the documented naming conventions. CoreDNS syntax support is not, by itself, authorization to replace the AKS-managed root forwarder. Production design must follow current AKS guidance and workload change controls.

#### Items to Validate

| Item to Validate | Validation Method | Mapped IMP Test Case |
| --- | --- | --- |
| Healthy DNS baseline | Prove both upstreams, the sequential resolver, and all isolated Deployments are healthy before faults. | `IMP-00-BASELINE` |
| First silent-failure impact | Restart the isolated resolver, drop primary ingress, and measure the first UDP query. | `IMP-01-FIRST-FAILURE` |
| One-, two-, and five-second client budgets | Use a fresh resolver and independent primary fault for each budget. | `IMP-02-BUDGETS` |
| Learned-unhealthy steady state | Compare one cold query with three later queries while the same fault remains active. | `IMP-03-LEARNED-UNHEALTHY` |
| Default and explicit `SERVFAIL` handling | Compare otherwise equivalent resolvers without and with `failover SERVFAIL`. | `IMP-04-SERVFAIL` |
| All upstreams unavailable | Independently isolate both synthetic upstreams and enforce a bounded client deadline. | `IMP-05-ALL-UNAVAILABLE` |
| DNS recovery | Remove both faults without restarting the resolver and poll for the primary answer. | `IMP-06-RECOVERY` |
| Application and runtime DNS caching | Compare warm, expired, negative-cache, and fresh-process behavior in a representative runtime. | `IMP-07-RUNTIME-CACHE` |
| Connection reuse | Compare a proven reused connection with a forced new connection to the same dependency. | `IMP-08-CONNECTION-REUSE` |
| Retry amplification | Trace one logical request through DNS, application, SDK/proxy, and caller attempts. | `IMP-09-RETRY-AMPLIFICATION` |
| UDP and TCP behavior | Compare healthy and cold silent-loss queries over UDP and forced TCP. | `IMP-10-TRANSPORTS` |
| Safe bounded DNS concurrency | Run 50 DNS queries at concurrency 5 and count all outputs. | `IMP-11-BOUNDED-LOAD` |
| Resolver observability | Correlate one faulted query with same-process metrics, logs, pod UID, and restart count. | `IMP-12-DNS-OBSERVABILITY` |
| Application observability correlation | Correlate resolver state with application request, dependency, retry, and error telemetry. | `IMP-13-APPLICATION-OBSERVABILITY` |
| Workload SLO mapping | Compare logical-request success and latency with approved workload thresholds. | `IMP-14-SLO-MAPPING` |
| Negative controls | Prove healthy, faulted, invalid-name, secondary, and restored paths separately. | `IMP-15-NEGATIVE-CONTROLS` |
| Independent repeatability | Execute five cold/steady cycles with a fresh resolver and per-cycle cleanup. | `IMP-16-REPEATABILITY` |
| Cleanup and noninterference | Delete the disposable namespace and prove the base lab and managed CoreDNS are healthy. | `IMP-17-CLEANUP` |

#### Dedicated application-impact validation suite

##### Common prerequisites

Use PowerShell 7+, `kubectl`, current context `aks01day2`, and the existing base manifest. Do not edit or apply faults to `kube-system`. The following setup creates a complete disposable lab by temporary namespace replacement, then configures resolvers with Service IPs discovered after creation:

```powershell
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$source = Join-Path $root "07-CoreDNS\validation\coredns-failover-lab.yaml"
$ns = "coredns-failover-validation-imp"
$temp = Join-Path $root ".imp-lab-$PID.yaml"
if ((kubectl config current-context).Trim() -ne "aks01day2") { throw "Wrong context" }

try {
    kubectl delete namespace $ns --ignore-not-found --wait=true --timeout=180s
    (Get-Content $source -Raw).Replace("coredns-failover-validation", $ns) |
        Set-Content $temp -Encoding utf8
    kubectl apply -f $temp
    $primaryIp = (kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
    $secondaryIp = (kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
    if (-not $primaryIp -or -not $secondaryIp) { throw "Missing dynamic upstream IP" }

    function Set-ImpResolver([string]$name, [string]$policy, [bool]$failover) {
        $line = if ($failover) { "        failover SERVFAIL`n" } else { "" }
        $corefile = ".:53 {`n    errors`n    log`n    ready`n    health`n    prometheus :9153`n" +
            "    forward . $primaryIp $secondaryIp {`n        policy $policy`n" +
            "        max_fails 1`n        health_check 500ms`n$line    }`n}"
        kubectl create configmap $name -n $ns "--from-literal=Corefile=$corefile" `
            --dry-run=client -o yaml | kubectl apply -f -
        if ($LASTEXITCODE) { throw "ConfigMap apply failed: $name" }
    }
    Set-ImpResolver "resolver-round-robin" "round_robin" $false
    Set-ImpResolver "resolver-sequential" "sequential" $false
    Set-ImpResolver "resolver-rcode-failover" "sequential" $true
    "resolver-round-robin","resolver-sequential","resolver-rcode-failover" |
        ForEach-Object { kubectl rollout restart "deployment/$_" -n $ns }
    kubectl wait --for=condition=Available deployment --all -n $ns --timeout=240s
}
finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
}
```

Define reusable helpers. Every faulting case uses `try/finally` and clears stale state before it starts:

```powershell
function Clear-ImpFaults {
    kubectl delete networkpolicy simulate-primary-dns-packet-loss `
        simulate-secondary-dns-packet-loss -n $ns --ignore-not-found | Out-Null
}
function Set-ImpFault([ValidateSet("primary","secondary")][string]$target) {
    $name = "simulate-$target-dns-packet-loss"
    $app = "upstream-$target"
    @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $name
  namespace: $ns
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: $app
  policyTypes: [Ingress]
  ingress: []
"@ | kubectl apply -f -
    if ($LASTEXITCODE) { throw "Fault apply failed: $target" }
}
function Reset-ImpResolver {
    kubectl rollout restart deployment/resolver-sequential -n $ns | Out-Null
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=180s | Out-Null
    if ($LASTEXITCODE) { throw "Resolver reset failed" }
}
function Invoke-ImpDig(
    [string]$server = "resolver-sequential",
    [string]$name = "answer.validation.test",
    [int]$budget = 5,
    [switch]$tcp
) {
    $args = @("exec","-n",$ns,"deployment/dns-client","--","dig","@$server",$name,
        "A","+time=$budget","+tries=1","+comments","+answer","+stats")
    if ($tcp) { $args += "+tcp" }
    kubectl @args
    "EXIT=$LASTEXITCODE UTC=$((Get-Date).ToUniversalTime().ToString('o'))"
}
```

Application-specific placeholders used only in blocked cases:

| Placeholder | Required substitution |
| --- | --- |
| `<APP_NAMESPACE>`, `<APP_DEPLOYMENT>`, `<APP_CONTAINER>` | Dedicated non-production representative workload and exact container. |
| `<APP_WARM_REQUEST>` | One request proven to reuse an established dependency connection. |
| `<APP_FRESH_REQUEST>` | Equivalent request proven to force a new connection and lookup. |
| `<APP_UNIQUE_REQUEST>` | Request carrying a unique correlation ID with physical attempts visible. |
| `<APP_TELEMETRY_QUERY>` | Query returning DNS/dependency/request/retry/error fields for that correlation ID. |
| `<SLO_SUCCESS_TARGET>`, `<SLO_P95_MS>`, `<SLO_P99_MS>` | Approved workload thresholds and source. |

#### IMP-00-BASELINE

##### IMP-00-BASELINE: Establish the healthy DNS baseline

**Validates item:** Healthy DNS baseline

**Purpose:** Prove the isolated client, both upstreams, resolver, and Deployments work before fault injection.

**Prerequisites:** Run Common prerequisites; no application workload is required.

**Commands:**

```powershell
Clear-ImpFaults
Reset-ImpResolver
1..10 | ForEach-Object { Invoke-ImpDig }
Invoke-ImpDig -server upstream-primary -budget 2
Invoke-ImpDig -server upstream-secondary -budget 2
kubectl get deployment,service,networkpolicy -n $ns
```

**Expected result:** Ten resolver queries return `NOERROR`/`192.0.2.10`; direct upstreams return `192.0.2.10` and `192.0.2.20`; six Deployments are Available.

**Pass/fail criteria:** Pass only with 10/10 expected resolver answers, both direct answers, 6/6 Deployments Available, and no fault policy.

**Evidence to capture:** Full `dig` output, exit codes, query times, Deployment state, Corefile, image, and UTC timestamps.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Ten of ten queries returned the primary; query times were 8, 0, 0, 0, 4, 4, 4, 0, 4, and 4 ms. Direct primary and secondary checks each took 4 ms, and 6/6 Deployments were Available.

#### IMP-01-FIRST-FAILURE

##### IMP-01-FIRST-FAILURE: Measure the first silent UDP failure

**Validates item:** First silent-failure impact

**Purpose:** Measure the cold resolver path when the preferred upstream silently drops traffic.

**Prerequisites:** Healthy IMP-00 baseline and NetworkPolicy enforcement in the isolated namespace.

**Commands:**

```powershell
try {
    Clear-ImpFaults
    Set-ImpFault primary
    Reset-ImpResolver
    Invoke-ImpDig -budget 5
}
finally { Clear-ImpFaults }
```

**Expected result:** The secondary returns `NOERROR`/`192.0.2.20` after approximately the UDP read-timeout path.

**Pass/fail criteria:** Pass when the secondary answer arrives in 1,500-3,000 ms with exit 0 and cleanup removes the fault.

**Evidence to capture:** Full output, `dig` query time, exit code, resolver pod identity, fault object, and cleanup listing.

**Established `aks01day2` evidence:** PASS on 2026-09-24. The first query returned `NOERROR`/`192.0.2.20` in 2,008 ms.

#### IMP-02-BUDGETS

##### IMP-02-BUDGETS: Test one-, two-, and five-second budgets

**Validates item:** One-, two-, and five-second client budgets

**Purpose:** Show whether the client remains alive long enough to receive fallback.

**Prerequisites:** Healthy isolated lab; each budget receives a fresh resolver and independent fault.

**Commands:**

```powershell
foreach ($budget in 1,2,5) {
    try {
        Clear-ImpFaults
        Set-ImpFault primary
        Reset-ImpResolver
        "BUDGET_SECONDS=$budget"
        Invoke-ImpDig -budget $budget
    }
    finally { Clear-ImpFaults }
}
```

**Expected result:** One second times out; five seconds succeeds; two seconds is a boundary race and must be recorded, not guaranteed.

**Pass/fail criteria:** Pass when all three trials terminate within their bounds, one second has no false success, five seconds returns the secondary, and the two-second observation is retained.

**Evidence to capture:** Per-budget output, exit code, query time, fresh pod identity, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. One second exited 9 with no response; two seconds exited 9 with no response; five seconds returned the secondary in 2,004 ms. This does not make two seconds deterministically unsafe or safe.

#### IMP-03-LEARNED-UNHEALTHY

##### IMP-03-LEARNED-UNHEALTHY: Compare cold and learned-unhealthy latency

**Validates item:** Learned-unhealthy steady state

**Purpose:** Determine whether later queries avoid repeatedly paying the cold failure delay.

**Prerequisites:** Healthy lab and a fresh sequential resolver.

**Commands:**

```powershell
try {
    Clear-ImpFaults
    Set-ImpFault primary
    Reset-ImpResolver
    Invoke-ImpDig
    Start-Sleep -Seconds 2
    1..3 | ForEach-Object { Invoke-ImpDig }
}
finally { Clear-ImpFaults }
```

**Expected result:** The cold query takes about two seconds; later queries return the secondary materially faster.

**Pass/fail criteria:** Pass when all four answers are the secondary and every later query is below 100 ms.

**Evidence to capture:** Ordered query times, answers, pod UID, health configuration, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Cold was 2,004 ms; later queries were 16, 4, and 4 ms, all returning `192.0.2.20`.

#### IMP-04-SERVFAIL

##### IMP-04-SERVFAIL: Compare default and explicit RCODE failover

**Validates item:** Default and explicit `SERVFAIL` handling

**Purpose:** Separate returned DNS errors from transport failure.

**Prerequisites:** Healthy `resolver-sequential` and `resolver-rcode-failover` configured from the same dynamic upstream IPs.

**Commands:**

```powershell
Invoke-ImpDig -server resolver-sequential -name rcode.validation.test
Invoke-ImpDig -server resolver-rcode-failover -name rcode.validation.test
```

**Expected result:** Default returns `SERVFAIL`; explicit failover returns the secondary answer.

**Pass/fail criteria:** Pass only when the first has no A answer and the second returns `NOERROR`/`192.0.2.20`.

**Evidence to capture:** Both Corefiles and full output from both queries.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Default returned `SERVFAIL` in 4 ms; explicit failover returned `NOERROR`/`192.0.2.20` in 4 ms.

#### IMP-05-ALL-UNAVAILABLE

##### IMP-05-ALL-UNAVAILABLE: Bound behavior when both upstreams are unavailable

**Validates item:** All upstreams unavailable

**Purpose:** Prove that no false answer appears and the client terminates.

**Prerequisites:** Healthy lab; both faults are namespace-local.

**Commands:**

```powershell
try {
    Clear-ImpFaults
    Set-ImpFault primary
    Set-ImpFault secondary
    Reset-ImpResolver
    Invoke-ImpDig -budget 5
}
finally { Clear-ImpFaults }
```

**Expected result:** No successful A answer; exact RCODE or client timeout is measured.

**Pass/fail criteria:** Pass when there is no A answer, the client terminates within its configured bound, and both policies are removed.

**Evidence to capture:** Output, exit, duration, both policies, resolver logs/metrics, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. The five-second client exited 9 with no response and no A answer.

#### IMP-06-RECOVERY

##### IMP-06-RECOVERY: Measure return to the preferred upstream

**Validates item:** DNS recovery

**Purpose:** Measure recovery after connectivity returns without masking behavior by restarting CoreDNS.

**Prerequisites:** Establish both-upstream loss inside this case.

**Commands:**

```powershell
try {
    Clear-ImpFaults
    Set-ImpFault primary
    Set-ImpFault secondary
    Reset-ImpResolver
    Invoke-ImpDig -budget 5
    $start = Get-Date
    Clear-ImpFaults
    1..20 | ForEach-Object {
        "ELAPSED_MS=$([math]::Round(((Get-Date)-$start).TotalMilliseconds))"
        Invoke-ImpDig -budget 2
        Start-Sleep -Milliseconds 500
    }
}
finally { Clear-ImpFaults }
```

**Expected result:** The primary returns after policy removal without resolver restart.

**Pass/fail criteria:** Pass when `192.0.2.10` appears within the declared ten-second lab wall-time bound and no policy remains.

**Evidence to capture:** Every probe, wall time, `dig` time, health metrics, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. The first recovery probe returned the primary; measured wall time was 9,735 ms including Kubernetes API/exec overhead, and `dig` query time was 4 ms.

#### IMP-07-RUNTIME-CACHE

##### IMP-07-RUNTIME-CACHE: Characterize representative runtime caching

**Validates item:** Application and runtime DNS caching

**Purpose:** Determine whether positive or negative caching hides, delays, or extends DNS impact.

**Prerequisites:** Supply the representative runtime/version, cache owner, test name/TTL, `<APP_*>` values, and a safe way to create a fresh process.

**Commands:**

```powershell
# PROPOSED: replace these values before execution.
$appNamespace = "<APP_NAMESPACE>"; $appDeployment = "<APP_DEPLOYMENT>"
$appContainer = "<APP_CONTAINER>"; $appFreshRequest = "<APP_FRESH_REQUEST>"
$observedTtlPlusOne = 0 # <OBSERVED_TTL_PLUS_ONE>
if ($observedTtlPlusOne -le 0) { throw "Supply the observed TTL plus one second" }
kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appFreshRequest
Start-Sleep -Seconds $observedTtlPlusOne
kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appFreshRequest
# Repeat for a controlled failed name and a fresh application process.
```

**Expected result:** Warm, expired, negative-cache, and fresh-process paths are distinguishable; behavior is runtime-specific.

**Pass/fail criteria:** Pass only when runtime/version/configuration, positive TTL, negative-cache lifetime, resolver-query delta, and fresh-process result are all recorded.

**Evidence to capture:** Runtime configuration, TTL, resolver metrics, request output, pod identity, and cache-expiry timings.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED. No representative application/runtime or cache configuration was supplied. Required substitutions are the exact workload identity, runtime/version, controlled TTL/name, cache owner, fresh-process method, and correlated resolver metrics.

#### IMP-08-CONNECTION-REUSE

##### IMP-08-CONNECTION-REUSE: Separate pooled connections from new lookups

**Validates item:** Connection reuse

**Purpose:** Prove whether an operation actually performs DNS.

**Prerequisites:** Supply one representative dependency, pool settings, connection identifier telemetry, and equivalent warm/new request commands.

**Commands:**

```powershell
# PROPOSED: replace these values before execution.
$appNamespace = "<APP_NAMESPACE>"; $appDeployment = "<APP_DEPLOYMENT>"
$appContainer = "<APP_CONTAINER>"; $appWarmRequest = "<APP_WARM_REQUEST>"
$appFreshRequest = "<APP_FRESH_REQUEST>"
kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appWarmRequest
try {
    Set-ImpFault primary
    kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appWarmRequest
    kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appFreshRequest
}
finally { Clear-ImpFaults }
```

**Expected result:** The reused path may avoid DNS while the forced-new path exposes current resolver behavior.

**Pass/fail criteria:** Pass only when telemetry proves reuse versus new connection and resolver-query deltas agree.

**Evidence to capture:** Connection IDs, pool configuration, request timings/status, DNS metric deltas, and cleanup.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED. No dependency protocol, pool, connection identity, or forced-new-connection path was supplied.

#### IMP-09-RETRY-AMPLIFICATION

##### IMP-09-RETRY-AMPLIFICATION: Count physical attempts per logical request

**Validates item:** Retry amplification

**Purpose:** Detect retry storms or hidden recovery across application layers.

**Prerequisites:** Supply retry limits/backoff for application, SDK, proxy, ingress, and caller plus a unique correlation-capable request.

**Commands:**

```powershell
# PROPOSED: replace these values before execution.
$appNamespace = "<APP_NAMESPACE>"; $appDeployment = "<APP_DEPLOYMENT>"
$appContainer = "<APP_CONTAINER>"; $appUniqueRequest = "<APP_UNIQUE_REQUEST>"
$appTelemetryQuery = "<APP_TELEMETRY_QUERY>"
$before = kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appUniqueRequest
$after = kubectl get --raw "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
& $appTelemetryQuery
```

**Expected result:** Every physical DNS/dependency attempt maps to one logical operation and remains within documented bounds.

**Pass/fail criteria:** Pass only when attempt counts at all layers, backoff, total duration, and resolver metric delta reconcile.

**Evidence to capture:** Retry configuration, correlation ID, raw metrics, logs/traces, and logical/physical counts.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED. No retry policy, representative operation, or correlation-capable telemetry was supplied.

#### IMP-10-TRANSPORTS

##### IMP-10-TRANSPORTS: Compare UDP and forced TCP

**Validates item:** UDP and TCP behavior

**Purpose:** Prevent UDP timing from being generalized to TCP.

**Prerequisites:** Healthy lab; permit a cold TCP trial up to 35 seconds.

**Commands:**

```powershell
Invoke-ImpDig
Invoke-ImpDig -tcp
try {
    Set-ImpFault primary
    Reset-ImpResolver
    Invoke-ImpDig -budget 5
}
finally { Clear-ImpFaults }
try {
    Set-ImpFault primary
    Reset-ImpResolver
    Invoke-ImpDig -budget 35 -tcp
}
finally { Clear-ImpFaults }
```

**Expected result:** Healthy transports return the primary; cold UDP and TCP failures are recorded independently.

**Pass/fail criteria:** Pass when healthy controls succeed, fault trials terminate, no false answer is accepted, and no common timeout is inferred.

**Evidence to capture:** Transport flag, full output, query time, answer/RCODE, exit, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Healthy UDP and TCP each returned the primary in 4 ms; cold UDP loss returned the secondary in 2,004 ms; cold forced-TCP loss returned `SERVFAIL` with no A answer in 29,996 ms.

#### IMP-11-BOUNDED-LOAD

##### IMP-11-BOUNDED-LOAD: Exercise safe DNS concurrency

**Validates item:** Safe bounded DNS concurrency

**Purpose:** Check answer correctness under a small bounded burst without claiming capacity.

**Prerequisites:** Healthy resolver, no fault, maximum 50 queries and concurrency 5.

**Commands:**

```powershell
Clear-ImpFaults
Reset-ImpResolver
kubectl exec -n $ns deployment/dns-client -- sh -c `
  'i=1; while [ $i -le 50 ]; do j=0; while [ $j -lt 5 ] && [ $i -le 50 ]; do (dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short | tail -n 1) & i=$((i+1)); j=$((j+1)); done; wait; done'
```

**Expected result:** Exactly 50 expected answers and no errors.

**Pass/fail criteria:** Pass DNS-level correctness with exit 0, 50 expected answers, and zero unexpected lines; do not infer production capacity.

**Evidence to capture:** Rate/concurrency, all outputs, exit code, pod resources, and resolver metrics.

**Established `aks01day2` evidence:** PASS for DNS on 2026-09-24. Fifty queries at concurrency 5 produced 50 primary answers, zero secondary answers, zero unexpected output, and exit 0. Application load remains blocked because no workload was supplied.

#### IMP-12-DNS-OBSERVABILITY

##### IMP-12-DNS-OBSERVABILITY: Correlate resolver metrics and logs

**Validates item:** Resolver observability

**Purpose:** Show that the faulted query and health-check activity are visible on the same resolver process.

**Prerequisites:** Kubernetes API access to the resolver metrics Service proxy.

**Commands:**

```powershell
$path = "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
try {
    Reset-ImpResolver
    $pod = kubectl get pod -n $ns -l app.kubernetes.io/name=resolver-sequential -o json
    $before = kubectl get --raw $path
    Set-ImpFault primary
    Invoke-ImpDig
    Start-Sleep -Seconds 2
    $after = kubectl get --raw $path
    kubectl logs -n $ns deployment/resolver-sequential --since=2m
    $pod
}
finally { Clear-ImpFaults }
```

**Expected result:** Same-process request and health-check counters increase and logs cover the query window.

**Pass/fail criteria:** Pass when pod UID/restart count are fixed, forwarded requests increase, health-check failures increase, and timestamped logs are retained.

**Evidence to capture:** Before/after raw metrics, exact series, pod UID, restart count, query output, logs, and UTC window.

**Established `aks01day2` evidence:** PASS on 2026-09-24. On one retained resolver pod UID, restart count 0, the query returned the secondary in 2,000 ms; health failures increased 0 to 3, requests 0 to 1, and five log lines were captured. The reusable document omits the ephemeral UID value.

#### IMP-13-APPLICATION-OBSERVABILITY

##### IMP-13-APPLICATION-OBSERVABILITY: Correlate DNS with a logical request

**Validates item:** Application observability correlation

**Purpose:** Connect resolver evidence to user-visible request/dependency outcome.

**Prerequisites:** Supply a representative workload, correlation ID propagation, telemetry schema, and query.

**Commands:**

```powershell
# PROPOSED: replace these values before execution.
$runId = "<UNIQUE_CORRELATION_ID>"
$appNamespace = "<APP_NAMESPACE>"; $appDeployment = "<APP_DEPLOYMENT>"
$appContainer = "<APP_CONTAINER>"; $appUniqueRequest = "<APP_UNIQUE_REQUEST>"
$appTelemetryQuery = "<APP_TELEMETRY_QUERY>"
kubectl exec -n $appNamespace "deployment/$appDeployment" -c $appContainer -- sh -c $appUniqueRequest
& $appTelemetryQuery
```

**Expected result:** One logical request correlates with DNS state, dependency attempt(s), retry count, duration, and final status.

**Pass/fail criteria:** Pass only when correlation is evidence-based and distinguishes DNS timeout, returned RCODE, and application timeout.

**Evidence to capture:** Query, run ID, traces/logs, request/dependency durations, error, retry count, and resolver window.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED. No application telemetry schema, correlation ID, log query, or representative request was supplied.

#### IMP-14-SLO-MAPPING

##### IMP-14-SLO-MAPPING: Map logical requests to workload SLOs

**Validates item:** Workload SLO mapping

**Purpose:** Determine whether measured logical-request availability and latency consume the approved error budget.

**Prerequisites:** Supply SLO source/window, success target, p95/p99 limits, request budget, and correlated logical-request data.

**Commands:**

```powershell
# PROPOSED: replace this value before execution.
$appTelemetryQuery = "<APP_TELEMETRY_QUERY>"
& $appTelemetryQuery
# Calculate success_rate, DNS-attributed failure rate, p95/p99 delta,
# physical_attempts/logical_requests, and error-budget consumption.
```

**Expected result:** Baseline and fault phases are compared to approved workload thresholds without relabeling DNS timing as user latency.

**Pass/fail criteria:** Pass only when `<SLO_SUCCESS_TARGET>`, `<SLO_P95_MS>`, and `<SLO_P99_MS>` are sourced and compared with logical-request measurements.

**Evidence to capture:** SLO source, query/window, counts, percentiles, calculations, and uncertainty.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED. No workload SLO thresholds, request budget, or logical-request telemetry was supplied.

#### IMP-15-NEGATIVE-CONTROLS

##### IMP-15-NEGATIVE-CONTROLS: Prove intended and unintended paths

**Validates item:** Negative controls

**Purpose:** Detect false conclusions caused by a broken client, invalid name, unhealthy secondary, or ineffective policy.

**Prerequisites:** Healthy lab and an intentionally absent test name.

**Commands:**

```powershell
Invoke-ImpDig -server upstream-primary -budget 2
Invoke-ImpDig -server upstream-secondary -budget 2
Invoke-ImpDig -name intentionally-absent.validation.test
try {
    Set-ImpFault primary
    Invoke-ImpDig -server upstream-primary -budget 1
    Invoke-ImpDig -server upstream-secondary -budget 2
}
finally { Clear-ImpFaults }
Invoke-ImpDig -server upstream-primary -budget 2
```

**Expected result:** Healthy paths work, absent name is distinguishable, only primary fails during isolation, secondary remains healthy, and cleanup restores primary.

**Pass/fail criteria:** Pass only when all five controls produce their expected distinct outcomes.

**Evidence to capture:** Full outputs, policies, exit codes, answers/RCODEs, and restored state.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Healthy primary/secondary returned expected answers in 0 ms; absent name returned `SERVFAIL` in 4 ms; isolated primary exited 9 with no response; secondary still answered in 0 ms; restored primary answered in 0 ms.

#### IMP-16-REPEATABILITY

##### IMP-16-REPEATABILITY: Repeat independent cold and steady cycles

**Validates item:** Independent repeatability

**Purpose:** Ensure the result is not one favorable sample.

**Prerequisites:** Healthy lab; five cycles; constant configuration.

**Commands:**

```powershell
1..5 | ForEach-Object {
    try {
        Clear-ImpFaults
        Reset-ImpResolver
        Set-ImpFault primary
        "CYCLE=$_ PHASE=COLD"
        Invoke-ImpDig
        Start-Sleep -Seconds 2
        "CYCLE=$_ PHASE=STEADY"
        Invoke-ImpDig
    }
    finally { Clear-ImpFaults }
}
```

**Expected result:** Five cold samples cluster near the UDP failure path and five steady samples are materially faster.

**Pass/fail criteria:** Pass when every cycle returns the secondary, cold samples are 1,500-3,000 ms, steady samples are below 100 ms, and no policy leaks.

**Evidence to capture:** Ordered per-cycle output, configuration, pod identity, outliers, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-24. Cold times were 2,004, 2,000, 2,004, 2,004, and 2,004 ms; steady times were 4, 0, 0, 0, and 8 ms. All answers were `192.0.2.20`.

#### IMP-17-CLEANUP

##### IMP-17-CLEANUP: Delete the disposable lab and prove noninterference

**Validates item:** Cleanup and noninterference

**Purpose:** Leave no IMP fault/resource and prove the retained base lab and managed resolver remain healthy.

**Prerequisites:** Stop load and retain the managed CoreDNS Deployment resourceVersion captured before setup.

**Commands:**

```powershell
Clear-ImpFaults
kubectl delete namespace $ns --wait=true --timeout=240s
kubectl get namespace $ns --ignore-not-found
kubectl wait --for=condition=Available deployment --all `
    -n coredns-failover-validation --timeout=180s
kubectl exec -n coredns-failover-validation deployment/dns-client -- `
    dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +stats
kubectl get deployment coredns -n kube-system `
    -o custom-columns='AVAILABLE:.status.availableReplicas,DESIRED:.spec.replicas,RV:.metadata.resourceVersion'
```

**Expected result:** The IMP namespace is absent; base lab returns the primary; managed CoreDNS remains Available and unchanged.

**Pass/fail criteria:** Pass when namespace is absent, base is 6/6 Available with `192.0.2.10`, managed CoreDNS is 2/2 Available, and its resourceVersion is unchanged.

**Evidence to capture:** Namespace query, base Deployment/DNS state, managed availability/resourceVersion before and after, and completion timestamp.

**Established `aks01day2` evidence:** PASS on 2026-09-24. The IMP namespace was deleted; base lab was 6/6 Available and returned the primary in 0 ms; managed CoreDNS was 2/2 Available and resourceVersion remained `22944732`.

#### Evidence handling

The retained result contains exact counts, timings, exit codes, RCODEs, answers, execution window, cleanup proof, and explicit blockers. Raw dynamic Service IPs are intentionally not repeated because they were ephemeral private cluster addresses; the repeatable procedure discovers them at runtime. Treat `dig` `Query time` as DNS latency. Wall time around `kubectl exec` includes Kubernetes API and process startup. Metrics are process-local and counters reset on restart, so pod UID and restart count must accompany comparisons.

#### Limitations

- The lab uses one resolver pod and synthetic upstreams; it is not a production-capacity test.
- NetworkPolicy semantics depend on the cluster network implementation.
- Exact timings are observations from the tested CoreDNS 1.13.1 AKS image, not guarantees for other versions or environments.
- The recovery wall time includes `kubectl exec` overhead.
- `IMP-07`, `IMP-08`, `IMP-09`, `IMP-13`, and `IMP-14` are blocked until a representative workload and precise placeholders are supplied.
- The bounded DNS load result does not establish application concurrency, end-user latency, or SLO compliance.

#### Conclusion

The DNS layer can add substantial latency or fail before fallback completes. On `aks01day2`, fresh silent UDP loss added about two seconds, short client budgets expired, default `SERVFAIL` did not fail over, all-upstream loss produced no answer, and cold forced-TCP loss behaved far worse than UDP. Learned health reduced later DNS latency, but process-local state means every replica can have its own cold event. Application and user impact remains workload-specific and cannot be declared established without the blocked representative-workload cases.

#### Authoritative links

- [CoreDNS 1.13.1 `forward` plugin documentation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
- [CoreDNS 1.13.1 forward proxy implementation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/proxy.go)
- [AKS: Customize CoreDNS](https://learn.microsoft.com/azure/aks/coredns-custom)
- [Kubernetes DNS debugging](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Dedicated `aks01day2` IMP result](../validation/results/aks01day2-impact-20260924.md)
