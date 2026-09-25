### 5. Expected application and user impact

**Question:** During a DNS server failure, should applications expect lookup failures, increased latency, or user impact before failover occurs?

#### Table of Contents

- [Introduction](#introduction)
- [Answer](#answer)
- [Theory](#theory)
  - [How DNS failure reaches an application](#how-dns-failure-reaches-an-application)
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

DNS failover is not instant, and applications may notice it. A DNS lookup can take longer, return an error, or exceed the application's timeout before CoreDNS gets an answer from the secondary server. DNS caches, reused connections, retries, and application timeouts determine whether users see an error or extra delay.

The DNS tests below were rerun on `aks01day2` on 2026-09-25 in the temporary namespace `coredns-failover-validation-imp-20260925-102725`. The test setup used a copy of the existing lab manifest and discovered the upstream Service IPs at runtime. It did not change anything in `kube-system`. The exact results are in [the latest IMP test result](../validation/results/aks01day2-impact-20260925.md), with raw structured evidence in [the run JSON](../validation/results/aks01day2-impact-20260925-102725.json).

#### Answer

Applications should expect slower DNS lookups or lookup failures when an upstream DNS server fails. Users may see an error or delay before failover succeeds. In the tested CoreDNS 1.13.1 image, the first UDP query waited about two seconds when the primary server silently dropped packets, then received an answer from the secondary server. Clients with one- and two-second timeouts gave up before that answer arrived. A client with a five-second timeout succeeded. After CoreDNS marked the primary server unhealthy, later uncached queries completed in 4-16 ms in this test.

The type of failure matters. By default, CoreDNS returned a `SERVFAIL` response directly to the client. It tried the secondary server only when `failover SERVFAIL` was configured. When both test upstreams were unavailable, a client with a five-second timeout received no response. For a new forced-TCP connection whose packets were silently dropped, CoreDNS took 29,996 ms and returned `SERVFAIL`. The equivalent UDP test took about two seconds. These are results from this test environment, not guaranteed AKS timings.

No representative application workload was available. Therefore, this test did not establish how an application cache, reused connection, retry policy, telemetry, or service-level objective (SLO) would behave. The DNS test results alone do not prove user impact.

#### Theory

##### How DNS failure reaches an application

The CoreDNS `forward` plugin reuses connections, supports UDP and TCP, and starts health checks after a network error. In the tested version, CoreDNS waits up to two seconds for a reply after sending a query. The timeout for opening a TCP connection changes based on recent connection times and has an upper limit. If UDP packets are silently dropped, CoreDNS may wait for the two-second read timeout before trying another server. When CoreDNS opens a new TCP connection and the packets are silently dropped, it may wait much longer before failing. A DNS response code is different from a network error. CoreDNS returns `SERVFAIL` to the client unless a `failover` rule tells it to try another server for that response code.

Each CoreDNS pod tracks upstream health in its own memory. This state is lost when the pod restarts and is not shared with other replicas. With `max_fails 1`, the test resolver marked the primary server unhealthy after one failed health check. Later queries then skipped the primary and avoided the first-query delay. Another CoreDNS replica, or a restarted pod, can still experience that delay on its first failed query. When every upstream is unhealthy, CoreDNS may still try one of them, so applications still need a timeout.

Application behavior can change whether a DNS problem reaches the user:

- A cached successful DNS answer can avoid a new lookup until the cache entry expires. A cached failed lookup can make the failure appear to last longer.
- An existing HTTP, HTTP/2, gRPC, database, or other reused connection may not need a new DNS lookup.
- Retries by the application, SDK, sidecar, proxy, ingress, or caller may recover the request. Too many retries can also increase load and make slow requests even slower.
- The application's request timeout may expire before CoreDNS finishes trying another server.
- Many applications making their first lookup at the same time can create more retries and load than a single `dig` test shows.

##### AKS support boundary

The resolver in the test namespace shows CoreDNS upstream behavior without changing the AKS-managed CoreDNS deployment. AKS does not support direct changes to the main managed Corefile. Supported custom settings use the `coredns-custom` ConfigMap and its required naming rules. A setting supported by CoreDNS is not automatically supported as a replacement for the AKS-managed root forwarder. Production changes must follow current AKS guidance and the workload's change-control process.

#### Items to Validate

| Item to Validate | Validation Method | Mapped IMP Test Case |
| --- | --- | --- |
| Healthy DNS baseline | Prove both upstreams, the sequential resolver, and all isolated Deployments are healthy before faults. | `IMP-00-BASELINE` |
| First silent-failure impact | Restart the test resolver, make the primary server silently drop traffic, and measure the first UDP query. | `IMP-01-FIRST-FAILURE` |
| One-, two-, and five-second client timeouts | Restart the resolver and create a new primary fault for each client timeout. | `IMP-02-BUDGETS` |
| Queries after CoreDNS marks the primary unhealthy | Compare the first failed query with three later queries while the same fault remains active. | `IMP-03-LEARNED-UNHEALTHY` |
| Default and explicit `SERVFAIL` handling | Compare otherwise equivalent resolvers without and with `failover SERVFAIL`. | `IMP-04-SERVFAIL` |
| All upstreams unavailable | Block both test upstreams and set a client timeout so the test cannot wait forever. | `IMP-05-ALL-UNAVAILABLE` |
| DNS recovery | Remove both faults without restarting the resolver and poll for the primary answer. | `IMP-06-RECOVERY` |
| Application and runtime DNS caching | Compare cached, expired, failed-lookup cache, and new-process behavior in a representative runtime. | `IMP-07-RUNTIME-CACHE` |
| Connection reuse | Compare a request that reuses a connection with one that must create a new connection to the same dependency. | `IMP-08-CONNECTION-REUSE` |
| Retry amplification | Trace one user operation and count every DNS, application, SDK/proxy, and caller attempt. | `IMP-09-RETRY-AMPLIFICATION` |
| UDP and TCP behavior | Compare healthy queries and first-query packet loss over UDP and forced TCP. | `IMP-10-TRANSPORTS` |
| Safe limited DNS concurrency | Run 50 DNS queries, no more than five at a time, and count all results. | `IMP-11-BOUNDED-LOAD` |
| Resolver metrics and logs | Match one failed query to metrics and logs from the same resolver pod. | `IMP-12-DNS-OBSERVABILITY` |
| Application metrics and logs | Match resolver state to application request, dependency, retry, and error data. | `IMP-13-APPLICATION-OBSERVABILITY` |
| Workload SLO comparison | Compare application request success and latency with approved workload targets. | `IMP-14-SLO-MAPPING` |
| Verification checks | Test healthy, failed, invalid-name, secondary, and restored paths separately. | `IMP-15-NEGATIVE-CONTROLS` |
| Repeatability | Run five independent first-query and later-query cycles, cleaning up after each cycle. | `IMP-16-REPEATABILITY` |
| Cleanup and managed CoreDNS safety | Delete the temporary namespace and verify that the base lab and managed CoreDNS are healthy. | `IMP-17-CLEANUP` |

#### Dedicated application-impact validation suite

##### Common prerequisites

Use PowerShell 7+, `kubectl`, the `aks01day2` context, and the existing base manifest. Do not change resources or create fault policies in `kube-system`. The following setup copies the base lab into a temporary namespace. It then finds the upstream Service IPs and adds them to the resolver configuration:

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

Define the helper functions used by the tests. Each failure test removes old fault policies before it starts and uses `try/finally` to clean up:

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

The application tests cannot run until the following placeholders are replaced:

| Placeholder | Required substitution |
| --- | --- |
| `<APP_NAMESPACE>`, `<APP_DEPLOYMENT>`, `<APP_CONTAINER>` | A representative non-production workload and the exact container to test. |
| `<APP_WARM_REQUEST>` | A request proven to reuse an existing dependency connection. |
| `<APP_FRESH_REQUEST>` | An equivalent request proven to create a new connection and perform a DNS lookup. |
| `<APP_UNIQUE_REQUEST>` | A request with a unique ID that appears on every retry and dependency call. |
| `<APP_TELEMETRY_QUERY>` | A query that returns DNS, dependency, request, retry, and error data for the unique request ID. |
| `<SLO_SUCCESS_TARGET>`, `<SLO_P95_MS>`, `<SLO_P99_MS>` | Approved workload targets and the source that defines them. |

#### IMP-00-BASELINE

##### IMP-00-BASELINE: Establish the healthy DNS baseline

**Validates item:** Healthy DNS baseline

**Purpose:** Confirm that the test client, both upstream servers, the resolver, and all Deployments work before creating a failure.

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

**Expected result:** All ten resolver queries return `NOERROR` and `192.0.2.10`. Direct queries return `192.0.2.10` from the primary and `192.0.2.20` from the secondary. All six Deployments are Available.

**Pass/fail criteria:** Pass only if all ten resolver answers are correct, both direct queries return the expected answer, all six Deployments are Available, and no fault NetworkPolicy exists.

**Evidence to capture:** Full `dig` output, exit codes, query times, Deployment state, Corefile, image, and UTC timestamps.

**Established `aks01day2` evidence:** PASS on 2026-09-25 in `coredns-failover-validation-imp-20260925-102725`. All ten resolver queries returned `NOERROR` and the primary answer `192.0.2.10`; query times were 4, 12, 0, 4, 0, 0, 4, 96, 0, and 0 ms. Direct primary and secondary queries returned `192.0.2.10` and `192.0.2.20` in 0 ms, and all 6 Deployments were Available. This confirms the lab baseline for this run, not a production latency baseline.

#### IMP-01-FIRST-FAILURE

##### IMP-01-FIRST-FAILURE: Measure the first silent UDP failure

**Validates item:** First silent-failure impact

**Purpose:** Measure the first query after a resolver restart when the preferred upstream silently drops packets.

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

**Expected result:** After waiting about two seconds for the primary, CoreDNS tries the secondary, which returns `NOERROR` and `192.0.2.20`.

**Pass/fail criteria:** Pass when the secondary answer arrives in 1,500-3,000 ms with exit 0 and cleanup removes the fault.

**Evidence to capture:** Full output, `dig` query time, exit code, resolver pod identity, fault object, and cleanup listing.

**Established `aks01day2` evidence:** PASS on 2026-09-25. After a resolver restart and silent primary packet loss, the first UDP query returned `NOERROR` and the secondary answer `192.0.2.20` in 2,000 ms with exit code 0. This measures one first-query failure path in the tested CoreDNS image; it is not a guaranteed timeout for every network failure.

#### IMP-02-BUDGETS

##### IMP-02-BUDGETS: Test one-, two-, and five-second budgets

**Validates item:** One-, two-, and five-second client timeouts

**Purpose:** Check whether each client timeout is long enough to receive an answer from the secondary server.

**Prerequisites:** Healthy test lab. Restart the resolver and create a new primary fault for each timeout value.

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

**Expected result:** The one-second client times out, and the five-second client succeeds. The two-second timeout is too close to the observed failover time to predict reliably, so record the result without treating it as guaranteed.

**Pass/fail criteria:** Pass when all three tests stop within their configured timeout, the one-second test does not report a false success, the five-second test returns the secondary answer, and the two-second result is recorded.

**Evidence to capture:** Output, exit code, query time, new resolver pod identity, and cleanup result for each timeout.

**Established `aks01day2` evidence:** PASS on 2026-09-25. Independent tests used a restarted resolver and a new primary fault for each timeout. The one- and two-second clients exited with code 9 and received no DNS response. The five-second client returned `NOERROR` and `192.0.2.20` in 2,000 ms with exit code 0. This establishes the result for these three trials only; a two-second timeout is too close to the observed failover time to be a safe design margin.

#### IMP-03-LEARNED-UNHEALTHY

##### IMP-03-LEARNED-UNHEALTHY: Compare cold and learned-unhealthy latency

**Validates item:** Queries after CoreDNS marks the primary unhealthy

**Purpose:** Check whether later queries skip the primary after CoreDNS marks it unhealthy.

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

**Expected result:** The first query takes about two seconds. Later queries skip the primary and return the secondary answer in less than 100 ms.

**Pass/fail criteria:** Pass when all four queries return the secondary answer and each of the last three queries completes in less than 100 ms.

**Evidence to capture:** Ordered query times, answers, pod UID, health configuration, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-25. With the primary fault left active, the first query returned `192.0.2.20` in 2,004 ms. After CoreDNS marked the primary unhealthy, the next three queries returned the same secondary answer in 0, 0, and 0 ms. This faster result depends on health state held by that resolver pod and does not carry across pod restarts or replicas.

#### IMP-04-SERVFAIL

##### IMP-04-SERVFAIL: Compare default and explicit RCODE failover

**Validates item:** Default and explicit `SERVFAIL` handling

**Purpose:** Show the difference between a DNS error response and a network failure.

**Prerequisites:** Healthy `resolver-sequential` and `resolver-rcode-failover` configured from the same dynamic upstream IPs.

**Commands:**

```powershell
Invoke-ImpDig -server resolver-sequential -name rcode.validation.test
Invoke-ImpDig -server resolver-rcode-failover -name rcode.validation.test
```

**Expected result:** The default resolver returns `SERVFAIL` to the client. The resolver configured with `failover SERVFAIL` tries the secondary and returns its answer.

**Pass/fail criteria:** Pass only when the first has no A answer and the second returns `NOERROR`/`192.0.2.20`.

**Evidence to capture:** Both Corefiles and full output from both queries.

**Established `aks01day2` evidence:** PASS on 2026-09-25. The default sequential resolver returned `SERVFAIL` with no A record in 0 ms. The otherwise equivalent resolver configured with `failover SERVFAIL` returned `NOERROR` and the secondary answer `192.0.2.20` in 0 ms. This proves the configured response-code behavior in the test resolvers, not the configuration of AKS-managed CoreDNS.

#### IMP-05-ALL-UNAVAILABLE

##### IMP-05-ALL-UNAVAILABLE: Bound behavior when both upstreams are unavailable

**Validates item:** All upstreams unavailable

**Purpose:** Confirm that the client does not receive a false answer and does not wait forever.

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

**Expected result:** The client receives no successful A record. Record whether it receives a DNS response code or reaches its timeout.

**Pass/fail criteria:** Pass when there is no A record, the client stops within its configured timeout, and both fault NetworkPolicies are removed.

**Evidence to capture:** Output, exit, duration, both policies, resolver logs/metrics, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-25. With both test upstreams blocked, the five-second client exited with code 9 and received no DNS response or A record. The full command took 7,616 ms because `kubectl exec` and process startup time are included; the configured DNS client timeout remained five seconds. This result does not define how every application reports an all-upstream failure.

#### IMP-06-RECOVERY

##### IMP-06-RECOVERY: Measure return to the preferred upstream

**Validates item:** DNS recovery

**Purpose:** Measure how quickly the primary returns to service after network access is restored, without restarting CoreDNS.

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

**Expected result:** After the fault NetworkPolicies are removed, CoreDNS returns an answer from the primary without a resolver restart.

**Pass/fail criteria:** Pass when `192.0.2.10` appears within ten seconds of wall-clock time and no fault NetworkPolicy remains.

**Evidence to capture:** Every probe, wall time, `dig` time, health metrics, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-25. After both fault policies were removed without restarting the resolver, the first recovery check returned `NOERROR` and the primary answer `192.0.2.10`. The wall-clock measurement was 4,915 ms and included Kubernetes API and `kubectl exec` startup time; the DNS query itself took 0 ms. The wall-clock value is not a resolver recovery SLA.

#### IMP-07-RUNTIME-CACHE

##### IMP-07-RUNTIME-CACHE: Test application DNS caching

**Validates item:** Application and runtime DNS caching

**Purpose:** Check whether cached successful or failed DNS results hide a problem, delay when it appears, or make it last longer.

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

**Expected result:** The results clearly show the difference between a cached answer, an expired answer, a cached failed lookup, and a new application process. The exact behavior depends on the application runtime.

**Pass/fail criteria:** Pass only when the runtime version and configuration, successful-answer TTL, failed-lookup cache duration, change in resolver query count, and new-process result are all recorded.

**Evidence to capture:** Runtime configuration, TTL, resolver metrics, request output, pod identity, and cache-expiry timings.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED on 2026-09-25. The latest run had no representative application, runtime, or cache configuration, so no application-cache result was measured. To establish this case, provide the workload, runtime and version, test name and TTL, component that owns the cache, method for starting a new process, and matching resolver metrics. DNS-only results from the other cases cannot be used as application-cache evidence.

#### IMP-08-CONNECTION-REUSE

##### IMP-08-CONNECTION-REUSE: Compare reused and new connections

**Validates item:** Connection reuse

**Purpose:** Check whether a request performs a DNS lookup or reuses an existing connection.

**Prerequisites:** Provide one representative dependency, connection-pool settings, connection ID data, and equivalent commands for a reused connection and a new connection.

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

**Expected result:** The reused connection may avoid DNS. The new connection should show the current DNS behavior.

**Pass/fail criteria:** Pass only when telemetry proves which request reused a connection, which created a new connection, and the resolver query count matches those results.

**Evidence to capture:** Connection IDs, pool configuration, request timings/status, DNS metric deltas, and cleanup.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED on 2026-09-25. No representative dependency protocol, connection pool, connection ID data, or method for forcing a new connection was provided. Therefore, the run could not prove whether a workload reused an existing connection or performed a new DNS lookup.

#### IMP-09-RETRY-AMPLIFICATION

##### IMP-09-RETRY-AMPLIFICATION: Count retries for one user operation

**Validates item:** Retry amplification

**Purpose:** Find out whether retries at several layers create too many attempts or hide an initial failure.

**Prerequisites:** Provide retry limits and delays for the application, SDK, proxy, ingress, and caller. Also provide a request with a unique ID that appears in telemetry.

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

**Expected result:** Every DNS and dependency attempt can be linked to one user operation, and the total number of attempts stays within the documented retry limits.

**Pass/fail criteria:** Pass only when retry counts at every layer, retry delays, total duration, and the change in resolver metrics all agree.

**Evidence to capture:** Retry settings, request ID, raw metrics, logs or traces, one user-operation count, and the number of underlying attempts.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED on 2026-09-25. No application, SDK, proxy, ingress, or caller retry policy was provided, and no representative user operation had telemetry with a shared request ID. The run therefore did not measure retry counts or retry-driven load.

#### IMP-10-TRANSPORTS

##### IMP-10-TRANSPORTS: Compare UDP and forced TCP

**Validates item:** UDP and TCP behavior

**Purpose:** Show that UDP and TCP can have different failure times.

**Prerequisites:** Healthy lab. Allow up to 35 seconds for the first failed TCP test.

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

**Expected result:** Healthy UDP and TCP queries return the primary answer. Record the first failed UDP and TCP queries separately.

**Pass/fail criteria:** Pass when the healthy tests succeed, both failure tests stop, no false answer is accepted, and the results do not claim that UDP and TCP use the same timeout.

**Evidence to capture:** Transport flag, full output, query time, answer/RCODE, exit, and cleanup.

**Established `aks01day2` evidence:** PASS on 2026-09-25. Healthy UDP and forced-TCP queries each returned the primary answer in 0 ms. With silent primary packet loss and a restarted resolver, UDP returned `NOERROR` and the secondary answer in 2,004 ms. Forced TCP returned `SERVFAIL` with no A record in 30,000 ms. These results show that UDP and TCP followed different failure paths in this test; they do not guarantee fixed timings in other environments.

#### IMP-11-BOUNDED-LOAD

##### IMP-11-BOUNDED-LOAD: Run a small concurrent DNS test

**Validates item:** Safe limited DNS concurrency

**Purpose:** Check DNS answers during a small, limited burst of queries. This is not a capacity test.

**Prerequisites:** Healthy resolver, no fault, maximum 50 queries and concurrency 5.

**Commands:**

```powershell
Clear-ImpFaults
Reset-ImpResolver
kubectl exec -n $ns deployment/dns-client -- sh -c `
  'i=1; while [ $i -le 50 ]; do j=0; while [ $j -lt 5 ] && [ $i -le 50 ]; do (dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short | tail -n 1) & i=$((i+1)); j=$((j+1)); done; wait; done'
```

**Expected result:** All 50 queries return the expected answer, with no errors or unexpected output.

**Pass/fail criteria:** Pass when the command exits with code 0, all 50 answers are correct, and there is no unexpected output. Do not use this result to estimate production capacity.

**Evidence to capture:** Rate/concurrency, all outputs, exit code, pod resources, and resolver metrics.

**Established `aks01day2` evidence:** PASS for DNS on 2026-09-25. The test ran 50 queries with no more than five active at once. All 50 returned the primary answer, none returned the secondary answer, there was no unexpected output, and the command exited with code 0. This is a small DNS correctness test, not a capacity, application-load, or user-latency result.

#### IMP-12-DNS-OBSERVABILITY

##### IMP-12-DNS-OBSERVABILITY: Match a DNS failure to resolver metrics and logs

**Validates item:** Resolver metrics and logs

**Purpose:** Show the failed query and health-check activity in metrics and logs from the same resolver pod.

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

**Expected result:** Request and health-check counters increase on the same resolver pod, and its logs include the time of the query.

**Pass/fail criteria:** Pass when the pod UID and restart count do not change during the test, forwarded-request and health-check-failure counters increase, and timestamped logs are saved.

**Evidence to capture:** Before/after raw metrics, exact series, pod UID, restart count, query output, logs, and UTC window.

**Established `aks01day2` evidence:** PASS on 2026-09-25. The resolver pod UID stayed the same and its restart count remained 0. The faulted query returned the secondary in 2,000 ms; `coredns_proxy_healthcheck_failures_total` increased from 0 to 2, `coredns_proxy_request_duration_seconds_count` increased from 0 to 1, and five matching resolver log lines were captured. These counters belong to that pod and reset when the pod restarts.

#### IMP-13-APPLICATION-OBSERVABILITY

##### IMP-13-APPLICATION-OBSERVABILITY: Match DNS state to an application request

**Validates item:** Application metrics and logs

**Purpose:** Connect resolver data to the result of an application request and its dependency calls.

**Prerequisites:** Provide a representative workload, a request ID passed through each component, the telemetry fields, and a query for that request ID.

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

**Expected result:** One application request can be matched to the DNS state, dependency attempts, retry count, duration, and final result.

**Pass/fail criteria:** Pass only when logs, metrics, or traces link the events and clearly show whether the failure was a DNS timeout, a DNS response code, or an application timeout.

**Evidence to capture:** Query, run ID, traces/logs, request/dependency durations, error, retry count, and resolver window.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED on 2026-09-25. No representative application request, shared request ID, telemetry fields, or application log query was provided. The run captured resolver metrics and logs only, so it cannot connect the DNS event to an application or user result.

#### IMP-14-SLO-MAPPING

##### IMP-14-SLO-MAPPING: Compare application results with workload SLOs

**Validates item:** Workload SLO comparison

**Purpose:** Determine whether application request failures and delays use more of the approved error budget than allowed.

**Prerequisites:** Provide the SLO source and time window, success target, p95 and p99 latency limits, application request timeout, and matching request data.

**Commands:**

```powershell
# PROPOSED: replace this value before execution.
$appTelemetryQuery = "<APP_TELEMETRY_QUERY>"
& $appTelemetryQuery
# Calculate success_rate, DNS-attributed failure rate, p95/p99 delta,
# physical_attempts/logical_requests, and error-budget consumption.
```

**Expected result:** Compare normal and failure-test application results with approved workload targets. Do not treat DNS query time as application or user latency.

**Pass/fail criteria:** Pass only when the source of `<SLO_SUCCESS_TARGET>`, `<SLO_P95_MS>`, and `<SLO_P99_MS>` is recorded and those targets are compared with application request measurements.

**Evidence to capture:** SLO source, query/window, counts, percentiles, calculations, and uncertainty.

**Established `aks01day2` evidence:** BLOCKED/NOT ESTABLISHED on 2026-09-25. No workload success target, p95 or p99 latency target, application request timeout, error-budget definition, or matching request telemetry was provided. DNS query times alone cannot establish workload SLO impact.

#### IMP-15-NEGATIVE-CONTROLS

##### IMP-15-NEGATIVE-CONTROLS: Verify each test path

**Validates item:** Verification checks

**Purpose:** Avoid a false result caused by a broken client, a missing DNS name, an unhealthy secondary server, or a fault policy that did not work.

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

**Expected result:** Healthy queries work, a missing name returns a different result, only the primary fails when isolated, the secondary stays healthy, and cleanup restores the primary.

**Pass/fail criteria:** Pass only when all five checks return their expected and clearly different results.

**Evidence to capture:** Full outputs, policies, exit codes, answers/RCODEs, and restored state.

**Established `aks01day2` evidence:** PASS on 2026-09-25. Healthy direct queries returned the expected primary and secondary answers in 0 ms. The intentionally absent name returned `SERVFAIL` in 4 ms. While the primary was blocked, its direct query exited with code 9 and no response, while the secondary still answered in 0 ms. After cleanup, the primary again answered in 0 ms. These checks confirm that the fault targeted only the intended path in this run.

#### IMP-16-REPEATABILITY

##### IMP-16-REPEATABILITY: Repeat first and later queries

**Validates item:** Repeatability

**Purpose:** Confirm that the result can be repeated and was not caused by one unusual test run.

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

**Expected result:** The first query in each of five cycles takes about two seconds. The later query in each cycle completes in less than 100 ms.

**Pass/fail criteria:** Pass when every query returns the secondary answer, each first query takes 1,500-3,000 ms, each later query takes less than 100 ms, and every fault NetworkPolicy is removed.

**Evidence to capture:** Query results in execution order, configuration, pod identity, unusual results, and cleanup for each cycle.

**Established `aks01day2` evidence:** PASS on 2026-09-25. Five independent cycles restarted the resolver, created a new primary fault, ran a first query, ran a later query, and removed the fault. First-query times were 2,004, 2,004, 2,000, 2,004, and 2,004 ms; later-query times were 0, 0, 0, 4, and 0 ms. Every query returned the secondary answer `192.0.2.20`. This repeatability applies to the tested image and lab failure mode, not all DNS failures.

#### IMP-17-CLEANUP

##### IMP-17-CLEANUP: Delete the test lab and verify managed CoreDNS

**Validates item:** Cleanup and managed CoreDNS safety

**Purpose:** Remove all IMP test resources and confirm that the base lab and AKS-managed CoreDNS remain healthy.

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

**Expected result:** The IMP namespace no longer exists, the base lab returns the primary answer, and managed CoreDNS remains Available and unchanged.

**Pass/fail criteria:** Pass when the namespace is gone, all six base-lab Deployments are Available and return `192.0.2.10`, both managed CoreDNS replicas are Available, and the CoreDNS Deployment resourceVersion is unchanged.

**Evidence to capture:** Namespace query, base Deployment/DNS state, managed availability/resourceVersion before and after, and completion timestamp.

**Established `aks01day2` evidence:** PASS on 2026-09-25. The unique test namespace was deleted and confirmed absent. The retained base lab had 6/6 Deployments Available and returned `NOERROR` with the primary answer `192.0.2.10` in 3 ms. AKS-managed CoreDNS remained 2/2 Available, and its Deployment resourceVersion stayed `23332770` before and after the run. The pre-existing `coredns-failover-validation-imp` namespace was not changed.

#### Evidence handling

The saved result includes counts, timings, exit codes, DNS response codes, answers, test times, cleanup results, and tests that could not run. Temporary private Service IPs are not included because the procedure discovers them each time it runs. Use the `dig` `Query time` value for DNS latency. Wall-clock time around `kubectl exec` also includes Kubernetes API and process startup time. Metrics belong to one resolver pod, and their counters reset when that pod restarts. Always record the pod UID and restart count when comparing metrics.

#### Limitations

- The lab uses one resolver pod and test upstream servers. It does not measure production capacity.
- NetworkPolicy behavior depends on the cluster's network implementation.
- The exact times were measured with the tested CoreDNS 1.13.1 AKS image. Other versions and environments may behave differently.
- The recovery wall time includes `kubectl exec` overhead.
- `IMP-07`, `IMP-08`, `IMP-09`, `IMP-13`, and `IMP-14` cannot run until a representative workload and the required values are provided.
- The limited DNS load test does not measure application concurrency, user latency, or compliance with an SLO.

#### Conclusion

DNS can add delay or fail before CoreDNS finishes trying another server. On `aks01day2`, the first UDP query took about two extra seconds when the primary silently dropped packets. Clients with short timeouts gave up, the default resolver did not try the secondary after `SERVFAIL`, and no answer arrived when both upstreams were unavailable. A new forced-TCP connection took much longer to fail than UDP. Later queries were faster after CoreDNS marked the primary unhealthy, but each CoreDNS replica keeps its own health state and can experience the first-query delay. The effect on applications and users depends on the workload and cannot be confirmed until the blocked application tests are run.

#### Authoritative links

- [CoreDNS 1.13.1 `forward` plugin documentation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
- [CoreDNS 1.13.1 forward proxy implementation](https://github.com/coredns/coredns/blob/v1.13.1/plugin/pkg/proxy/proxy.go)
- [AKS: Customize CoreDNS](https://learn.microsoft.com/azure/aks/coredns-custom)
- [Kubernetes DNS debugging](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Dedicated `aks01day2` IMP result](../validation/results/aks01day2-impact-20260924.md)
