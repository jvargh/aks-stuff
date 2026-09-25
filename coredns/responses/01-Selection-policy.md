### 1\. Selection policy

**Question:** Can CoreDNS upstream selection be changed from round-robin to sequential?

#### Table of Contents

- [Introduction](#introduction)
- [Answer](#answer)
- [Detailed theory](#detailed-theory)
  - [Policy semantics](#policy-semantics)
  - [Transport errors, DNS RCODEs, and health](#transport-errors-dns-rcodes-and-health)
  - [Caching and statistically meaningful queries](#caching-and-statistically-meaningful-queries)
  - [AKS customization boundary](#aks-customization-boundary)
- [Items to Validate](#items-to-validate)
- [Dedicated selection-policy validation suite](#dedicated-selection-policy-validation-suite)
  - [Common prerequisites](#common-prerequisites)
  - [Fixture-extension helper](#fixture-extension-helper)
  - [SP-00: Managed baseline and default](#sp-00-managed-default-random-managed-baseline-and-default)
  - [SP-01: Omitted policy behavior](#sp-01-default-random-sample-omitted-policy-behavior)
  - [SP-02: Explicit random policy](#sp-02-explicit-random-sample-explicit-random-policy)
  - [SP-03: Round-robin with two healthy upstreams](#sp-03-round-robin-healthy-round-robin-with-two-healthy-upstreams)
  - [SP-04: First healthy upstream preference](#sp-04-sequential-healthy-order-first-healthy-upstream-preference)
  - [SP-05: First upstream unavailable](#sp-05-sequential-primary-failure-first-upstream-unavailable)
  - [SP-06: Preferred secondary unavailable](#sp-06-sequential-secondary-failure-preferred-secondary-unavailable)
  - [SP-07: Preferred upstream re-enters service](#sp-07-sequential-recovery-preferred-upstream-re-enters-service)
  - [SP-08: RCODE is not transport failure](#sp-08-dns-rcode-vs-selection-rcode-is-not-transport-failure)
  - [SP-09: Repeated trials](#sp-09-repeatability-and-sample-size-repeated-trials)
  - [SP-10: Parser and image compatibility](#sp-10-syntax-and-version-parser-and-image-compatibility)
  - [SP-11: Read-only AKS configuration inspection](#sp-11-aks-support-boundary-read-only-aks-configuration-inspection)
  - [SP-12: Logs and forward metrics](#sp-12-observability-logs-and-forward-metrics)
  - [SP-13: Remove test resources](#sp-13-cleanup-and-noninterference-remove-test-resources)
- [Evidence handling](#evidence-handling)
- [Limitations](#limitations)
- [Conclusion](#conclusion)
- [Authoritative links](#authoritative-links)

#### Introduction

AKS deploys CoreDNS as the cluster DNS service. Workload pods normally send DNS queries to the `kube-dns` Service, and the AKS-managed CoreDNS configuration decides whether to answer locally or forward a query to an upstream resolver. Selection policy matters only when a `forward` stanza has more than one eligible upstream. It determines which healthy upstream CoreDNS tries first; it does not replace transport retry, health checking, response-code failover, caching, or the retry and timeout behavior of the calling application.

There are two separate questions in AKS:

1.  Does the CoreDNS `forward` plugin support ordered upstream selection?
2.  Can that policy be applied through an AKS-supported customization boundary?

The first answer is determined by the CoreDNS version and is testable in an isolated namespace. The second is determined by AKS support policy. AKS owns the main `coredns` ConfigMap and Deployment in `kube-system`; directly editing them is not a durable or supported customization. Microsoft documents the `coredns-custom` ConfigMap for custom server blocks and overrides. Consequently, the tests below leave `kube-system` unchanged and use the existing `coredns-failover-validation` fixture.

#### Answer

Yes. CoreDNS supports `random`, `round_robin`, and `sequential` in the `forward` plugin. To prefer upstreams in configured order, use:

```text
forward . 10.0.0.20 10.0.0.21 {
    policy sequential
}
```

However, the premise that the current AKS behavior is round-robin must first be verified. In CoreDNS 1.13.1, omitting `policy` means `random`, not `round_robin`. The established `aks01day2` baseline used `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20` and its managed Corefile contained `forward . /etc/resolv.conf` with no explicit policy. Therefore, its effective policy was the version-matched default, `random`.

A domain-specific `coredns-custom` server block can use the built-in `forward` plugin with `policy sequential`. This validation does not prove that the AKS-managed root forwarder can be globally replaced or overridden in a supported way. Obtain current Microsoft guidance before attempting that cluster-wide production change.

#### Detailed theory

##### Policy semantics

| Policy | Selection behavior |
| --- | --- |
| `random` | Selects an eligible upstream randomly. This is the default when `policy` is omitted. |
| `round_robin` | Rotates the initial selection among eligible upstreams. |
| `sequential` | Tries eligible upstreams in configured order, so the first healthy upstream is preferred. |

An upstream is eligible when the forward proxy does not currently regard it as down. With `sequential`, "first" means first in the `forward` argument list, not lowest IP, fastest response, or primary according to an external DNS system. A policy chooses the first endpoint to try. If that exchange has a network error, CoreDNS can try another endpoint.

##### Transport errors, DNS RCODEs, and health

A timeout, refused connection, or other exchange error is a transport failure. The forward proxy can try another upstream. A valid DNS message carrying `SERVFAIL`, `REFUSED`, or another RCODE is not a transport failure. By default, CoreDNS returns that response instead of trying the next server. The separate `failover` option can list RCODEs that should cause another upstream to be tried, for example:

```text
failover SERVFAIL REFUSED
```

After an exchange error, CoreDNS starts in-band health checking of that upstream. In the fixture, `max_fails 1` and `health_check 500ms` make the state transition easier to observe. Any DNS response to the health probe establishes network reachability; an RCODE such as `SERVFAIL` does not by itself mean that the endpoint is unhealthy.

##### Caching and statistically meaningful queries

Policy is evaluated when the `forward` plugin performs an upstream exchange. An answer served from cache would not demonstrate upstream selection. The fixture resolver Corefiles intentionally omit the `cache` plugin. The upstream answer TTL is 30 seconds, but it is irrelevant while the resolver has no cache. Random behavior is probabilistic: observing both endpoints supports the claim that both are eligible, but a finite sample can never prove perfect randomness or a precise 50/50 distribution. Round-robin tests must also avoid parallel queries when the assertion depends on exact alternation.

##### AKS customization boundary

Do not edit the managed `coredns` ConfigMap. For a domain-specific forwarding rule, the supported shape is a key ending in `.server` in `coredns-custom`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  example.server: |
    example.internal:53 {
        errors
        forward . 10.0.0.20 10.0.0.21 {
            policy sequential
        }
    }
```

This is an explanatory example, not a command to apply. The upstreams, zone, network path, ownership, and change approval must be established for the target environment.

#### Items to Validate

| Item to Validate | Validation Method | Mapped SP Test Case |
| --- | --- | --- |
| Managed baseline and effective default | Record the managed image and Corefile, verify no explicit policy, and match the image to versioned CoreDNS documentation. | `SP-00-MANAGED-DEFAULT-RANDOM` |
| Default `random` behavior | Run an isolated resolver with two upstreams and no `policy` line; collect a sufficiently large uncached sample. | `SP-01-DEFAULT-RANDOM-SAMPLE` |
| Explicit `random` behavior | Run the same isolated resolver with `policy random`; collect an uncached sample from both upstreams. | `SP-02-EXPLICIT-RANDOM-SAMPLE` |
| `round_robin` behavior | Query the existing round-robin resolver serially and verify that both healthy fixture answers occur. | `SP-03-ROUND-ROBIN-HEALTHY` |
| Healthy `sequential` ordering | Query the existing sequential resolver repeatedly and verify that only the first configured upstream answers. | `SP-04-SEQUENTIAL-HEALTHY-ORDER` |
| Primary failure | Silently drop traffic to the first upstream and verify that sequential selection reaches the second upstream. | `SP-05-SEQUENTIAL-PRIMARY-FAILURE` |
| Secondary failure | Use a secondary-first sequential extension, isolate that endpoint, and verify fallback to the primary. | `SP-06-SEQUENTIAL-SECONDARY-FAILURE` |
| Recovery | Restore the preferred upstream and verify that health checking returns it to service. | `SP-07-SEQUENTIAL-RECOVERY` |
| DNS RCODE distinction | Compare sequential resolution with and without `failover SERVFAIL`. | `SP-08-DNS-RCODE-VS-SELECTION` |
| Repeatability and sample-size limits | Repeat samples, report counts, and avoid claiming deterministic distribution from random results. | `SP-09-REPEATABILITY-AND-SAMPLE-SIZE` |
| Syntax and version compatibility | Prove the exact image starts successfully with each policy and record parser errors, image digest, and version. | `SP-10-SYNTAX-AND-VERSION` |
| AKS support boundary | Read managed and custom ConfigMaps without modifying them and compare the proposed change with Microsoft AKS guidance. | `SP-11-AKS-SUPPORT-BOUNDARY` |
| Observability | Capture resolver logs and forward-proxy metrics before, during, and after an outage. | `SP-12-OBSERVABILITY` |
| Cleanup | Remove fault and extension resources, restore the reusable base lab, and prove that `kube-system` was not changed. | `SP-13-CLEANUP-AND-NONINTERFERENCE` |

#### Dedicated selection-policy validation suite

This suite is intentionally limited to upstream-selection policy and can be executed independently of the other four question-specific suites.

##### Common prerequisites

*   PowerShell 7 or Windows PowerShell with `kubectl` and `az` available.
*   Permission to read `kube-system` and create namespaced resources.
*   The current context must be the intended non-production validation cluster.
*   NetworkPolicy enforcement must be available for outage cases.
*   Run commands from the repository root.
*   Use a separate PowerShell terminal for the metrics port-forward in SP-11.
*   The fixture uses documentation-only addresses `192.0.2.10` and `192.0.2.20` as returned answers. These are not upstream Service IPs.

Establish credentials and deploy the existing isolated fixture:

```powershell
az aks get-credentials --resource-group aks01day2-rg --name aks01day2 --overwrite-existing
$expectedContext = "aks01day2"
$actualContext = (kubectl config current-context).Trim()
if ($actualContext -ne $expectedContext) {
    throw "Wrong kubectl context: $actualContext"
}

.\07-CoreDNS\validation\Deploy-CoreDNSFailoverLab.ps1

$ns = "coredns-failover-validation"
kubectl wait --for=condition=Available deployment --all -n $ns --timeout=180s
$primaryIP = (kubectl get service upstream-primary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$secondaryIP = (kubectl get service upstream-secondary -n $ns -o jsonpath="{.spec.clusterIP}").Trim()
$image = (kubectl get deployment resolver-sequential -n $ns `
    -o jsonpath="{.spec.template.spec.containers[0].image}").Trim()
kubectl get deployment,service,networkpolicy -n $ns -o wide
```

Expected prerequisite result: all six existing Deployments are Available, both upstream Service IP variables are nonempty, and `$image` is recorded.

Pass/fail: pass only if the context check succeeds, all fixture Deployments are Available, and no command mutates `kube-system`. Otherwise stop.

Evidence to capture:

```powershell
kubectl config current-context
kubectl get deployment,service,networkpolicy -n $ns -o wide
kubectl get deployment resolver-sequential -n $ns -o yaml
kubectl get configmap resolver-sequential -n $ns -o yaml
```

##### Fixture-extension helper

SP-01, SP-02, and SP-06 require resolvers not present in the checked-in fixture. This is explicitly a **fixture extension**. The following commands create ephemeral ConfigMaps and Deployments without editing fixture files. Run this helper once in the same PowerShell session:

If an earlier version of these functions is already loaded in the current PowerShell session, rerun the entire helper block below before retrying. Function definitions already loaded in memory are not updated when this Markdown file changes.

```powershell
function New-PolicyResolver {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FirstUpstream,
        [Parameter(Mandatory)][string]$SecondUpstream,
        [AllowEmptyString()][string]$PolicyLine
    )

    if ([string]::IsNullOrWhiteSpace($image)) {
        throw "The CoreDNS image variable is empty. Run the Common prerequisites first."
    }
    if ([string]::IsNullOrWhiteSpace($FirstUpstream) -or
        [string]::IsNullOrWhiteSpace($SecondUpstream)) {
        throw "Both upstream Service IPs are required. Run the Common prerequisites first."
    }

    $corefile = @"
.:53 {
    errors
    log
    ready
    health
    prometheus :9153
    forward . $FirstUpstream $SecondUpstream {
$PolicyLine
        max_fails 1
        health_check 500ms
    }
}
"@

    kubectl create configmap $Name -n $ns `
        "--from-literal=Corefile=$corefile" --dry-run=client -o yaml |
        kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "ConfigMap creation failed for $Name" }

    # Delete an older extension created by a previous version of this helper.
    # The old selector is immutable and cannot be corrected with kubectl apply.
    kubectl delete deployment $Name -n $ns --ignore-not-found --wait=true
    if ($LASTEXITCODE -ne 0) { throw "Existing Deployment cleanup failed for $Name" }

    $deployment = @{
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = @{
            name = $Name
            namespace = $ns
            labels = @{
                "app.kubernetes.io/name" = $Name
                "app.kubernetes.io/part-of" = "coredns-failover-validation"
            }
        }
        spec = @{
            replicas = 1
            selector = @{
                matchLabels = @{
                    "app.kubernetes.io/name" = $Name
                }
            }
            template = @{
                metadata = @{
                    labels = @{
                        "app.kubernetes.io/name" = $Name
                        "app.kubernetes.io/part-of" = "coredns-failover-validation"
                    }
                }
                spec = @{
                    containers = @(
                        @{
                            name = "coredns"
                            image = $image
                            args = @("-conf", "/etc/coredns/Corefile")
                            ports = @(
                                @{ name = "dns-udp"; containerPort = 53; protocol = "UDP" }
                                @{ name = "dns-tcp"; containerPort = 53; protocol = "TCP" }
                                @{ name = "metrics"; containerPort = 9153; protocol = "TCP" }
                            )
                            readinessProbe = @{
                                httpGet = @{ path = "/ready"; port = 8181 }
                            }
                            resources = @{
                                requests = @{ cpu = "10m"; memory = "20Mi" }
                                limits = @{ cpu = "100m"; memory = "64Mi" }
                            }
                            securityContext = @{
                                allowPrivilegeEscalation = $false
                                capabilities = @{
                                    add = @("NET_BIND_SERVICE")
                                    drop = @("ALL")
                                }
                                readOnlyRootFilesystem = $true
                                runAsNonRoot = $true
                                runAsUser = 65532
                                seccompProfile = @{ type = "RuntimeDefault" }
                            }
                            volumeMounts = @(
                                @{ name = "config"; mountPath = "/etc/coredns"; readOnly = $true }
                            )
                        }
                    )
                    volumes = @(
                        @{ name = "config"; configMap = @{ name = $Name } }
                    )
                }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress

    $deployment | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Deployment creation failed for $Name" }
    kubectl rollout status deployment/$Name -n $ns --timeout=120s
    if ($LASTEXITCODE -ne 0) { throw "Resolver did not become ready: $Name" }
}

function Get-ResolverPodIP {
    param([Parameter(Mandatory)][string]$Name)
    $podIPOutput = kubectl get pod -n $ns -l "app.kubernetes.io/name=$Name" `
        -o jsonpath="{.items[0].status.podIP}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$podIPOutput)) {
        throw "No ready pod IP was found for resolver $Name."
    }
    $podIP = ([string]$podIPOutput).Trim()
    $podIP
}

function Invoke-PolicySample {
    param(
        [Parameter(Mandatory)][string]$Server,
        [int]$Count = 64,
        [string]$Name = "answer.validation.test"
    )

    if ($Count -lt 1) { throw "Count must be at least 1." }
    if ($Server -notmatch "^(?:\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)$") {
        throw "Server must be an IPv4 address or DNS name."
    }
    if ($Name -notmatch "^[A-Za-z0-9.-]+$") {
        throw "Name contains unsupported characters."
    }

    # Run the loop inside one client-pod session. This avoids one Kubernetes API
    # exec/TLS handshake per sample, which can make a large sample unreliable.
    $sampleScript = 'i=1; while [ "$i" -le "$3" ]; do dig "@$1" "$2" A +time=5 +tries=1 +short || exit 1; i=$((i+1)); done'
    $output = kubectl exec -n $ns deployment/dns-client -- `
        sh -c $sampleScript -- $Server $Name $Count
    if ($LASTEXITCODE -ne 0) {
        throw "DNS sample failed against $Server."
    }

    $answers = @($output | Where-Object {
        $_ -match "^\d{1,3}(\.\d{1,3}){3}$"
    } | ForEach-Object { $_.Trim() })
    if ($answers.Count -ne $Count) {
        throw "Expected $Count DNS answers from $Server but received $($answers.Count)."
    }
    $answers
}
```

The generated Deployment uses the image entry point and supplies the same `-conf` arguments as the checked-in Deployments. It deliberately uses the pod IP directly, so no additional DNS Service is needed. If the pod is recreated, call `Get-ResolverPodIP` again.

---

##### SP-00-MANAGED-DEFAULT-RANDOM: Managed baseline and default

**Validates item:** Managed baseline and effective default.

**Purpose:** Determine the deployed version and whether the managed Corefile actually configures `round_robin`, `sequential`, or no policy.

**Prerequisites:** Common prerequisites only. Read access to `kube-system`.

**Commands:**

```powershell
$managedImage = kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.spec.template.spec.containers[0].image}"
$managedCorefile = kubectl get configmap coredns -n kube-system `
    -o jsonpath="{.data.Corefile}"

$managedImage
$managedCorefile
$explicitPolicies = [regex]::Matches(
    $managedCorefile,
    '(?m)^\s*policy\s+(random|round_robin|sequential)\s*$'
).Value
$explicitPolicies
```

**Expected result:** The image version is identifiable. If the relevant `forward` block has no `policy`, version-matched documentation identifies the effective policy as `random`. Do not infer a policy from traffic distribution.

**Pass/fail criteria:** Pass if the image and complete Corefile are captured, the relevant `forward` block is identified, and any policy conclusion is tied to that exact block and version. Fail if the file is partial, the image is unknown, or "round-robin" is assumed merely because multiple upstreams exist.

**Evidence to capture:** Raw image string, full Corefile, the relevant server block, command timestamp, current context, and versioned documentation URL.

**Established `aks01day2` evidence:** Image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`; the managed root forwarder was `forward . /etc/resolv.conf` with no explicit selection policy. For CoreDNS 1.13.1, the resulting default is `random`.

---

##### SP-01-DEFAULT-RANDOM-SAMPLE: Omitted policy behavior

**Validates item:** Default `random` behavior.

**Purpose:** Demonstrate that both healthy endpoints remain eligible when the policy line is omitted.

**Fixture extension required:** Yes. It creates `resolver-random-default`; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper.

**Commands:**

```powershell
New-PolicyResolver -Name "resolver-random-default" `
    -FirstUpstream $primaryIP -SecondUpstream $secondaryIP -PolicyLine ""
$defaultRandomIP = Get-ResolverPodIP "resolver-random-default"
$defaultRandomAnswers = Invoke-PolicySample -Server $defaultRandomIP -Count 100
$defaultRandomCounts = $defaultRandomAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$defaultRandomCounts | Format-Table -AutoSize
```

**Expected result:** The answers are only `192.0.2.10` and `192.0.2.20`; both normally appear in 100 independent uncached exchanges.

**Pass/fail criteria:** Pass if there are exactly 100 valid answers, no unexpected address occurs, and each expected address occurs at least once. Fail on any query error or unexpected answer. If only one expected address appears, record an inconclusive statistical result, verify both upstreams are healthy, increase the sample, and do not relabel it an implementation failure without further evidence.

**Evidence to capture:** Generated ConfigMap YAML, Deployment YAML, image, pod IP, raw ordered answers, grouped counts, resolver logs, and upstream logs.

**Established `aks01day2` evidence:** On 2026-09-24, the corrected helper created and rolled out `resolver-random-default`. In the human-run sample shown for this case, all 100 uncached queries succeeded: `192.0.2.10` returned 42 times and `192.0.2.20` returned 58 times. An independent verification run also completed 100 queries successfully and produced the reverse 58/42 split. Both runs returned only the two expected addresses and selected both healthy upstreams. The differing distributions are expected for a random policy and must not be interpreted as a guaranteed 50/50 ratio.

---

##### SP-02-EXPLICIT-RANDOM-SAMPLE: Explicit random policy

**Validates item:** Explicit `random` behavior.

**Purpose:** Validate parser acceptance and behavior of `policy random`.

**Fixture extension required:** Yes. It creates `resolver-random-explicit`; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper.

**Commands:**

```powershell
New-PolicyResolver -Name "resolver-random-explicit" `
    -FirstUpstream $primaryIP -SecondUpstream $secondaryIP `
    -PolicyLine "        policy random"
$explicitRandomIP = Get-ResolverPodIP "resolver-random-explicit"
$explicitRandomAnswers = Invoke-PolicySample -Server $explicitRandomIP -Count 100
$explicitRandomCounts = $explicitRandomAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$explicitRandomCounts | Format-Table -AutoSize
```

**Expected result:** The Deployment becomes Ready and both expected addresses normally appear; there is no parser error for `policy random`.

**Pass/fail criteria:** Pass if all 100 responses contain only expected addresses, both occur, and logs contain no policy parser error. Apply the same statistical-inconclusive rule as SP-01 if only one expected answer occurs.

**Evidence to capture:** Corefile, rollout status, image, ordered answers, counts, and `kubectl logs deployment/resolver-random-explicit -n $ns`.

**Established `aks01day2` evidence:** On 2026-09-24, the human-run sample created and successfully rolled out `resolver-random-explicit` with `policy random`. All 100 uncached queries succeeded: `192.0.2.10` returned 47 times and `192.0.2.20` returned 53 times. No unexpected address was reported. This establishes parser acceptance of `policy random` in the tested CoreDNS image and confirms that both healthy upstreams were eligible. The 47/53 split is one probabilistic sample, not a balancing guarantee or proof of an exact 50/50 distribution.

---

##### SP-03-ROUND-ROBIN-HEALTHY: Round-robin with two healthy upstreams

**Validates item:** `round_robin` behavior.

**Purpose:** Show that explicit `round_robin` selects both eligible upstreams.

**Prerequisites:** Existing fixture only. Both upstream Deployments Available.

**Commands:**

```powershell
kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
    --ignore-not-found
kubectl rollout restart deployment/resolver-round-robin -n $ns
kubectl rollout status deployment/resolver-round-robin -n $ns --timeout=120s
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-primary answer.validation.test A +time=2 +tries=1 +short
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-secondary answer.validation.test A +time=2 +tries=1 +short
kubectl get configmap resolver-round-robin -n $ns -o jsonpath="{.data.Corefile}"
$roundRobinAnswers = Invoke-PolicySample `
    -Server "resolver-round-robin" -Count 20
$roundRobinAnswers
$roundRobinCounts = $roundRobinAnswers |
    Group-Object | Sort-Object Name | Select-Object Name,Count
$roundRobinCounts | Format-Table -AutoSize
```

**Expected result:** Both `192.0.2.10` and `192.0.2.20` appear, with no other answer. Commands are serial to avoid making a stronger ordering claim under concurrency.

**Pass/fail criteria:** Pass if 20 answers are returned and both expected addresses occur. Fail if an unexpected address, timeout, or only one address occurs while both upstreams are demonstrably healthy.

**Evidence to capture:** Resolver Corefile, ordered answers, grouped counts, resolver logs, both upstream logs, and pod readiness.

**Established `aks01day2` evidence:** On 2026-09-24, after removing the stale primary-outage policy, restarting the resolver, and proving both upstreams directly reachable, all 20 queries succeeded. `192.0.2.10` returned 10 times and `192.0.2.20` returned 10 times. The exact 10/10 split is an observation from this serial sample, not a general concurrency or fairness guarantee.

---

##### SP-04-SEQUENTIAL-HEALTHY-ORDER: First healthy upstream preference

**Validates item:** Healthy `sequential` ordering.

**Purpose:** Validate deterministic first-healthy preference.

**Prerequisites:** Existing fixture only. No outage NetworkPolicy may exist.

**Commands:**

```powershell
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
    --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-primary answer.validation.test A +time=2 +tries=1 +short
kubectl exec -n $ns deployment/dns-client -- `
    dig @upstream-secondary answer.validation.test A +time=2 +tries=1 +short
kubectl get configmap resolver-sequential -n $ns -o jsonpath="{.data.Corefile}"
$sequentialHealthy = Invoke-PolicySample `
    -Server "resolver-sequential" -Count 20
$sequentialHealthy
$sequentialHealthy | Group-Object | Select-Object Name,Count
```

**Expected result:** Every answer is `192.0.2.10`, the first upstream in the effective Corefile.

**Pass/fail criteria:** Pass only if all 20 queries succeed and all 20 return `192.0.2.10`. Any secondary answer, unexpected answer, or query failure fails this deterministic case.

**Evidence to capture:** Effective Corefile, primary and secondary Service IPs, ordered answers, grouped counts, logs, and absence of outage NetworkPolicies.

**Established `aks01day2` evidence:** On 2026-09-24, after removing the stale primary-outage policy, restarting the resolver, and proving both upstreams directly reachable, all 20 queries returned the first configured upstream answer, `192.0.2.10`. No secondary or unexpected answer occurred.

---

##### SP-05-SEQUENTIAL-PRIMARY-FAILURE: First upstream unavailable

**Validates item:** Primary failure.

**Purpose:** Verify that a transport failure at the preferred upstream allows selection of the next upstream.

**Prerequisites:** Existing fixture, a NetworkPolicy-enforcing data plane, and successful SP-04. This test changes only the validation namespace.

**Commands:**

```powershell
try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s

    $primaryFailureOutput = kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    $primaryFailureOutput

    Start-Sleep -Seconds 3
    $primaryDownSample = Invoke-PolicySample `
        -Server "resolver-sequential" -Count 10
    $primaryDownSample | Group-Object | Select-Object Name,Count
}
finally {
    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
}
```

**Expected result:** The first exchange may show approximately the version's network-error timeout before returning `192.0.2.20`. After the primary is marked down, the sample returns only `192.0.2.20` without repeatedly waiting for the primary.

**Pass/fail criteria:** Pass if the first sufficiently patient query succeeds with `NOERROR` and `192.0.2.20`, and all later queries return the secondary. Fail if the secondary is never reached, an unexpected address occurs, or the NetworkPolicy does not actually isolate primary ingress.

**Evidence to capture:** NetworkPolicy YAML, first full `dig` output including status and query time, subsequent answers, resolver logs, health metrics, and NetworkPolicy-capability confirmation.

**Established `aks01day2` evidence:** On 2026-09-24, the first query returned the secondary answer `192.0.2.20` in 2,003 ms. After health detection, all 10 follow-up queries returned `192.0.2.20`. The outage policy was removed in cleanup. This is consistent with the earlier 1,999 ms first-failure observation and 0-3 ms known-unhealthy observations.

---

##### SP-06-SEQUENTIAL-SECONDARY-FAILURE: Preferred secondary unavailable

**Validates item:** Secondary failure.

**Purpose:** Test the symmetric failure path with the existing secondary listed first and the existing primary listed second.

**Fixture extension required:** Yes. It creates `resolver-sequential-secondary-first` plus an ephemeral NetworkPolicy; no fixture file is edited.

**Prerequisites:** Common prerequisites and the fixture-extension helper. Remove the primary outage before starting.

**Commands:**

```powershell
kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
    --ignore-not-found

New-PolicyResolver -Name "resolver-sequential-secondary-first" `
    -FirstUpstream $secondaryIP -SecondUpstream $primaryIP `
    -PolicyLine "        policy sequential"
$secondaryFirstIP = Get-ResolverPodIP "resolver-sequential-secondary-first"

$beforeSecondaryOutage = Invoke-PolicySample `
    -Server $secondaryFirstIP -Count 5
$beforeSecondaryOutage

try {
@"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: simulate-secondary-dns-packet-loss
  namespace: coredns-failover-validation
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: upstream-secondary
  policyTypes:
    - Ingress
  ingress: []
"@ | kubectl apply -f -

    kubectl rollout restart deployment/resolver-sequential-secondary-first -n $ns
    kubectl rollout status deployment/resolver-sequential-secondary-first `
        -n $ns --timeout=120s
    $secondaryFirstIP = Get-ResolverPodIP "resolver-sequential-secondary-first"

    $secondaryFailureOutput = kubectl exec -n $ns deployment/dns-client -- `
        dig "@$secondaryFirstIP" answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    $secondaryFailureOutput

    Start-Sleep -Seconds 3
    $secondaryDownSample = Invoke-PolicySample `
        -Server $secondaryFirstIP -Count 10
    $secondaryDownSample | Group-Object | Select-Object Name,Count
}
finally {
    kubectl delete networkpolicy simulate-secondary-dns-packet-loss `
        -n $ns --ignore-not-found
}
```

**Expected result:** Before isolation all five answers are `192.0.2.20`. After isolation, the first patient query and all subsequent queries return `192.0.2.10`.

**Pass/fail criteria:** Pass only if ordering is proven before the outage and fallback to the primary is proven after the outage. Fail if the precondition is not established, NetworkPolicy is not enforced, or any post-outage answer is unexpected.

**Evidence to capture:** Extension Corefile and Deployment, NetworkPolicy YAML, before/after ordered answers, first full `dig` output and query time, logs, and metrics.

**Established `aks01day2` evidence:** On 2026-09-24, all five healthy precondition queries returned the preferred secondary answer `192.0.2.20`. With secondary ingress silently dropped, the first fallback returned `192.0.2.10` in 2,007 ms, and all 10 follow-up queries returned `192.0.2.10`. The secondary-outage policy was removed in cleanup.

---

##### SP-07-SEQUENTIAL-RECOVERY: Preferred upstream re-enters service

**Validates item:** Recovery.

**Purpose:** Verify that removal of the primary outage permits the first configured endpoint to become eligible again.

**Prerequisites:** Existing fixture and a NetworkPolicy-enforcing data plane. This case creates and removes its own primary outage.

**Commands:**

```powershell
try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl rollout restart deployment/resolver-sequential -n $ns
    kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short
    Start-Sleep -Seconds 2

    $recoveryStart = Get-Date
    kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
        --ignore-not-found

    $recovered = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $answer = kubectl exec -n $ns deployment/dns-client -- `
            dig @resolver-sequential answer.validation.test A `
            +time=5 +tries=1 +short
        $elapsedMs = [int]((Get-Date) - $recoveryStart).TotalMilliseconds
        "$elapsedMs ms : $($answer -join ',')"
        if ($answer -contains "192.0.2.10") {
            $recovered = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $recovered) { throw "Primary did not re-enter the sample window" }
}
finally {
    kubectl delete networkpolicy simulate-primary-dns-packet-loss -n $ns `
        --ignore-not-found
}
```

**Expected result:** `192.0.2.10` reappears after health checks can reach the primary. The measured interval is an observation, not a production recovery SLO.

**Pass/fail criteria:** Pass if the primary answer returns within the declared 10-second, 20-attempt observation window. Fail if it does not. A test failure does not prove permanent exclusion; preserve logs and metrics for diagnosis.

**Evidence to capture:** Deletion timestamp, every timestamped answer, time-to-first-primary, resolver logs, health-check counters, and final NetworkPolicy list.

**Established `aks01day2` evidence:** Recovery has been observed in repeated runs. The primary answer returned after approximately 3,645 ms in the original validation and within 8,829 ms in the 2026-09-24 independent rerun. Both observations were inside the declared 10-second window. The elapsed value includes `kubectl exec` and API overhead and is not a production recovery SLO.

---

##### SP-08-DNS-RCODE-VS-SELECTION: RCODE is not transport failure

**Validates item:** DNS RCODE distinction.

**Purpose:** Prove that selection policy alone does not retry a valid `SERVFAIL`, and that `failover SERVFAIL` is a separate option.

**Prerequisites:** Existing fixture. Remove both outage policies first.

**Commands:**

```powershell
kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s
kubectl rollout restart deployment/resolver-rcode-failover -n $ns
kubectl rollout status deployment/resolver-rcode-failover -n $ns --timeout=120s

$withoutRcodeFailover = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-sequential rcode.validation.test A `
    +time=5 +tries=1 +comments +answer
$withRcodeFailover = kubectl exec -n $ns deployment/dns-client -- `
    dig @resolver-rcode-failover rcode.validation.test A `
    +time=5 +tries=1 +comments +answer

"Without failover SERVFAIL:"
$withoutRcodeFailover
"With failover SERVFAIL:"
$withRcodeFailover
kubectl get configmap resolver-sequential resolver-rcode-failover `
    -n $ns -o yaml
```

**Expected result:** The sequential resolver without `failover SERVFAIL` returns `status: SERVFAIL` and no A answer. The otherwise comparable resolver with that option returns `status: NOERROR` and `192.0.2.20`.

**Pass/fail criteria:** Pass only if both halves match. Fail if selection policy alone retries SERVFAIL or the explicit failover resolver does not reach the secondary.

**Evidence to capture:** Both full `dig` outputs, both Corefiles, resolver logs, and upstream logs showing which endpoint received each query.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 after removing outage policies and restarting both resolvers. Without `failover SERVFAIL`, the result was `SERVFAIL` with no A answer. With `failover SERVFAIL`, the result was `NOERROR` with `192.0.2.20`.

---

##### SP-09-REPEATABILITY-AND-SAMPLE-SIZE: Repeated trials

**Validates item:** Repeatability and sample-size limits.

**Purpose:** Separate deterministic sequential behavior from probabilistic random behavior and expose trial-to-trial variation.

**Prerequisites:** SP-01 through SP-04; all upstreams healthy; random resolver pod IPs refreshed after any restart.

**Commands:**

```powershell
kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found
foreach ($resolver in @(
    "resolver-random-default",
    "resolver-random-explicit",
    "resolver-round-robin",
    "resolver-sequential"
)) {
    kubectl rollout restart deployment/$resolver -n $ns
    kubectl rollout status deployment/$resolver -n $ns --timeout=120s
}

$defaultRandomIP = Get-ResolverPodIP "resolver-random-default"
$explicitRandomIP = Get-ResolverPodIP "resolver-random-explicit"

$repeatability = foreach ($trial in 1..5) {
    foreach ($case in @(
        @{ Name = "default-random"; Server = $defaultRandomIP },
        @{ Name = "explicit-random"; Server = $explicitRandomIP },
        @{ Name = "round-robin"; Server = "resolver-round-robin" },
        @{ Name = "sequential"; Server = "resolver-sequential" }
    )) {
        $answers = Invoke-PolicySample -Server $case.Server -Count 100
        [pscustomobject]@{
            Trial = $trial
            PolicyCase = $case.Name
            Total = $answers.Count
            Primary = @($answers | Where-Object { $_ -eq "192.0.2.10" }).Count
            Secondary = @($answers | Where-Object { $_ -eq "192.0.2.20" }).Count
            Unexpected = @(
                $answers | Where-Object {
                    $_ -notin @("192.0.2.10", "192.0.2.20")
                }
            ).Count
        }
    }
}
$repeatability | Format-Table -AutoSize
```

**Expected result:** Sequential is 100 primary answers in every healthy trial. Random trials contain only expected answers and ordinarily include both. Round-robin contains both. Exact random ratios are not acceptance criteria.

**Pass/fail criteria:** Pass deterministic sequential only at 500/500 primary. For random cases, pass data integrity only when totals are complete and no unexpected answer occurs; report endpoint coverage separately. Never claim a uniform distribution from five trials. A statistical fairness test would need a predeclared hypothesis, independence assumptions, and a larger sample.

**Evidence to capture:** Trial table, raw answers retained separately, Corefiles, pod identities, restart counts, timestamps, and any throttling or query errors.

**Established `aks01day2` evidence:** The complete five-trial matrix ran on 2026-09-24 with 2,000 successful queries and no unexpected answers. Default-random primary counts by trial were 46, 45, 51, 55, and 47, totaling 244 primary and 256 secondary. Explicit-random primary counts were 58, 43, 50, 41, and 60, totaling 252 primary and 248 secondary. Round-robin returned 50 primary and 50 secondary in every trial, totaling 250/250. Sequential returned 100 primary and zero secondary in every trial, totaling 500/0. The random totals demonstrate variation and endpoint coverage, not a guaranteed ratio.

---

##### SP-10-SYNTAX-AND-VERSION: Parser and image compatibility

**Validates item:** Syntax and version compatibility.

**Purpose:** Confirm that policy syntax is accepted by the exact runtime image, not merely by current online documentation.

**Prerequisites:** All four policy resolver variants deployed.

**Commands:**

```powershell
$policyResolvers = @(
    "resolver-random-default",
    "resolver-random-explicit",
    "resolver-round-robin",
    "resolver-sequential",
    "resolver-sequential-secondary-first"
)

kubectl get deployment $policyResolvers -n $ns `
    -o custom-columns="NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas"

foreach ($resolver in $policyResolvers) {
    "===== $resolver Corefile ====="
    kubectl get configmap $resolver -n $ns -o jsonpath="{.data.Corefile}"
    "`n===== $resolver logs ====="
    kubectl logs deployment/$resolver -n $ns --tail=100
}

kubectl exec -n $ns deployment/resolver-sequential -- coredns -version
kubectl get pod -n $ns -l app.kubernetes.io/name=resolver-sequential `
    -o jsonpath="{.items[0].status.containerStatuses[0].imageID}"
```

**Expected result:** Every Deployment is Ready and Available, logs have no `Unknown property`, parse, or startup error, and the runtime version and image digest are recorded. Omitted, `random`, `round_robin`, and `sequential` syntax all start successfully.

**Pass/fail criteria:** Pass only for syntax actually started by the recorded image. If `-version` is unsupported by the packaged binary, record that command failure but use image tag, immutable image ID, readiness, and logs. Fail policy compatibility if the resolver enters CrashLoopBackOff or logs a parser error.

**Evidence to capture:** Corefiles, readiness table, logs, image tag, image ID, version output or its error, Kubernetes events, and documentation tag.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 for all five resolver variants. Omitted-policy random, explicit `random`, `round_robin`, `sequential`, and secondary-first `sequential` each had one Ready and Available replica, used `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`, and had no parser errors in the sampled logs. The binary reported CoreDNS 1.13.1, and the sequential pod image ID was `sha256:b1b16649b9a06534471ed990bb952b756f456241fe3c0a378da33cfe7dedfa51`.

---

##### SP-11-AKS-SUPPORT-BOUNDARY: Read-only AKS configuration inspection

**Validates item:** AKS support boundary.

**Purpose:** Distinguish CoreDNS capability from what AKS supports customers changing.

**Prerequisites:** Read access to the two ConfigMaps. This is read-only.

**Commands:**

```powershell
kubectl get configmap coredns -n kube-system -o yaml
kubectl get configmap coredns-custom -n kube-system -o yaml `
    --ignore-not-found
kubectl get deployment coredns -n kube-system `
    -o jsonpath="{.metadata.labels}{'\n'}{.metadata.annotations}{'\n'}"
```

Review the output against the current Microsoft document linked below. Do not run `kubectl edit`, `kubectl patch`, or `kubectl apply` against the managed `coredns` ConfigMap.

**Expected result:** The managed Corefile and any current custom keys are recorded. A proposed domain-specific key ends in `.server` or `.override` and uses only supported built-in plugins. No command changes `kube-system`.

**Pass/fail criteria:** Pass if the implementation recommendation stays within the documented `coredns-custom` mechanism, or explicitly records that a global root-forwarder change needs Microsoft confirmation. Fail if the plan directly edits the managed ConfigMap or assumes the isolated lab authorizes a global change.

**Evidence to capture:** Read-only YAML, Microsoft document retrieval date, proposed zone scope, policy Corefile, ownership approval, and a before/after resourceVersion comparison if a separately approved custom change is later performed.

**Established `aks01day2` evidence:** Read-only inspection on 2026-09-24 showed two Available managed CoreDNS replicas. The managed `coredns` ConfigMap had resourceVersion `22591546`, label `app.kubernetes.io/managed-by: Eno`, root directive `forward . /etc/resolv.conf`, and no explicit selection policy. The existing `coredns-custom` ConfigMap contained one supported `.server` key named `test.server`. No `kube-system` resource was changed. This evidence confirms the customization boundary but does not authorize replacing the managed root forwarder.

---

##### SP-12-OBSERVABILITY: Logs and forward metrics

**Validates item:** Observability.

**Purpose:** Make policy and health-state conclusions auditable.

**Prerequisites:** Existing fixture. Use SP-04, SP-05, and SP-07 to generate healthy, outage, and recovery traffic.

**Commands:**

```powershell
$metricsPath = "/api/v1/namespaces/$ns/services/http:resolver-sequential:metrics/proxy/metrics"
function Get-ResolverMetrics {
    (kubectl get --raw $metricsPath) -join "`n"
}
function Measure-MetricTotal {
    param([string]$Text, [string]$MetricName)
    $total = 0.0
    foreach ($line in $Text -split "`n") {
        if ($line -match "^$([regex]::Escape($MetricName))(?:\{[^}]*\})?\s+([0-9.eE+-]+)$") {
            $total += [double]$Matches[1]
        }
    }
    $total
}

kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
    --ignore-not-found
kubectl rollout restart deployment/resolver-sequential -n $ns
kubectl rollout status deployment/resolver-sequential -n $ns --timeout=120s

$metricsBefore = Get-ResolverMetrics
$healthBefore = Measure-MetricTotal $metricsBefore `
    "coredns_proxy_healthcheck_failures_total"
$requestsBefore = Measure-MetricTotal $metricsBefore `
    "coredns_proxy_request_duration_seconds_count"

try {
    kubectl apply -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml
    kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A `
        +time=5 +tries=1 +comments +answer +stats
    Start-Sleep -Seconds 3

    $metricsDuring = Get-ResolverMetrics
    $healthDuring = Measure-MetricTotal $metricsDuring `
        "coredns_proxy_healthcheck_failures_total"
    $requestsDuring = Measure-MetricTotal $metricsDuring `
        "coredns_proxy_request_duration_seconds_count"
    kubectl logs deployment/resolver-sequential -n $ns --since=10m `
        --timestamps

    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
    Start-Sleep -Seconds 2
    $recoveryAnswer = kubectl exec -n $ns deployment/dns-client -- `
        dig @resolver-sequential answer.validation.test A +time=5 +tries=1 +short

    $metricsAfter = Get-ResolverMetrics
    $healthAfter = Measure-MetricTotal $metricsAfter `
        "coredns_proxy_healthcheck_failures_total"
    $requestsAfter = Measure-MetricTotal $metricsAfter `
        "coredns_proxy_request_duration_seconds_count"

    [pscustomobject]@{
        HealthBefore = $healthBefore
        HealthDuring = $healthDuring
        HealthAfter = $healthAfter
        RequestsBefore = $requestsBefore
        RequestsDuring = $requestsDuring
        RequestsAfter = $requestsAfter
        RecoveryAnswer = $recoveryAnswer -join ","
    } | Format-List
}
finally {
    kubectl delete -f .\07-CoreDNS\validation\primary-outage-networkpolicy.yaml `
        --ignore-not-found
}
```

**Expected result:** Query logs identify forwarded requests and metrics expose forward-proxy requests and health-check failures. Counter names and labels must be interpreted from the version actually deployed. Counters are cumulative for the process and reset on pod restart.

**Pass/fail criteria:** Pass if logs and metric snapshots can be time-correlated with the test, and the outage produces a nonzero health-check-failure series. Fail if evidence is missing, taken from the wrong pod, or compared across a restart without acknowledging reset.

**Evidence to capture:** Pod UID, restart count, all three metric snapshots, timestamped logs, exact queries, outage apply/delete times, and CoreDNS image.

**Established `aks01day2` evidence:** Revalidated on 2026-09-24 through the Kubernetes API metrics proxy, without a port-forward. After a fresh resolver restart, health-check failures increased from 0 before the outage to 4 during it and 9 after recovery probing. Forward request count increased from 0 to 1 during the outage query and to 2 after the recovery query. The recovery answer was `192.0.2.10`, and five timestamped resolver log lines were captured.

---

##### SP-13-CLEANUP-AND-NONINTERFERENCE: Remove test resources

**Validates item:** Cleanup.

**Purpose:** Restore the validation cluster and prove that cleanup is scoped.

**Prerequisites:** Evidence from all required cases has been saved outside the namespace.

**Commands:**

```powershell
$ns = "coredns-failover-validation"

kubectl delete networkpolicy simulate-primary-dns-packet-loss `
    simulate-secondary-dns-packet-loss -n $ns --ignore-not-found

kubectl delete deployment `
    resolver-random-default `
    resolver-random-explicit `
    resolver-sequential-secondary-first `
    -n $ns --ignore-not-found
kubectl delete configmap `
    resolver-random-default `
    resolver-random-explicit `
    resolver-sequential-secondary-first `
    -n $ns --ignore-not-found

.\07-CoreDNS\validation\Deploy-CoreDNSFailoverLab.ps1

kubectl get namespace $ns
kubectl get deployment -n $ns
kubectl get deployment,configmap,networkpolicy -n $ns -o name |
    Select-String "resolver-random-default|resolver-random-explicit|resolver-sequential-secondary-first|simulate-.*-dns-packet-loss"
kubectl get deployment coredns -n kube-system
kubectl get configmap coredns -n kube-system `
    -o jsonpath="{.metadata.resourceVersion}{'\n'}"
```

**Expected result:** The three extension resolvers and both fault policies are absent. The validation namespace remains available with the six base Deployments healthy for later human testing. The managed CoreDNS Deployment remains Available, and the test suite never writes a `kube-system` resource.

**Pass/fail criteria:** Pass if no extension or fault resource is returned, all six base Deployments are Available, and managed CoreDNS remains Available. Compare the final managed ConfigMap `resourceVersion` with SP-00 evidence; investigate any unexpected change rather than attributing it automatically to this suite, because AKS itself may reconcile resources.

**Evidence to capture:** Delete output, final namespace and base Deployment status, empty extension-resource search, final managed CoreDNS status and resourceVersion, current context, and cleanup timestamp.

**Established `aks01day2` evidence:** Executed on 2026-09-24. Both fault policies and all three extension resolver ConfigMaps and Deployments were removed. The base lab was reapplied and retained with all six base Deployments Available. No extension match remained. Managed CoreDNS retained two Available replicas, and the managed Corefile ConfigMap resourceVersion remained `22591546`.

#### Evidence handling

For every case, store:

*   Case ID, UTC timestamp, operator-independent cluster/context identifier, and CoreDNS image tag plus immutable image ID.
*   Exact commands and unedited stdout/stderr.
*   Effective ConfigMaps, relevant Deployments, pod UIDs, restart counts, and NetworkPolicies.
*   Ordered answers, not only grouped counts.
*   Full `dig` status, answer, and statistics output for failure transitions.
*   Timestamped resolver and upstream logs.
*   Metrics before, during, and after fault injection.
*   A result of PASS, FAIL, BLOCKED, or STATISTICALLY INCONCLUSIVE, with the criterion cited.

Do not put credentials, subscription identifiers, private production addresses, or other PII in evidence. Redact only sensitive fields and record that redaction occurred.

#### Limitations

1.  The fixture uses namespace-local CoreDNS instances. It validates CoreDNS behavior, not every detail of the AKS-managed DNS request path.
2.  NetworkPolicy behavior depends on the cluster network plugin and policy enforcement. Prove isolation rather than assuming it.
3.  Silent packet loss, connection refusal, route failure, and a valid DNS `SERVFAIL` are different failure modes with different timing.
4.  Random selection is probabilistic. Endpoint coverage in a finite sample does not establish uniformity or fairness.
5.  Round-robin order can be obscured by concurrency, retries, endpoint health changes, multiple resolver replicas, or process restarts.
6.  The fixture omits caching to isolate selection. Production caching reduces the number of upstream exchanges and changes what clients observe.
7.  The fixture uses `max_fails 1` and `health_check 500ms`; those values may differ from the managed or proposed production configuration.
8.  Results apply to the recorded image. Revalidate after an AKS or CoreDNS upgrade.
9.  Pod-IP queries in extension cases are deliberate lab shortcuts and are not a production service design.
10.  A successful domain-specific custom server block does not prove that AKS supports globally replacing its managed root forwarder.
11.  Recovery time from this lab is an observation, not an availability SLO.
12.  This procedure does not assess upstream correctness, DNSSEC, TLS, confidentiality, capacity, or application retry behavior.

#### Conclusion

CoreDNS can use sequential upstream selection, and the isolated v1.13.1 AKS fixture established first-healthy ordering, transport fallback, RCODE distinction, health observability, and recovery for the cases already recorded. The managed `aks01day2` baseline was not round-robin; because it omitted `policy`, its version-matched default was random.

For AKS, use `coredns-custom` for a scoped, domain-specific configuration and validate it with the dedicated cases above. Do not directly edit the managed Corefile. Treat a requested global change to `forward . /etc/resolv.conf` as an AKS support-boundary question requiring current Microsoft confirmation.

#### Authoritative links

*   [Customize CoreDNS for Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/coredns-custom)
*   [Troubleshoot CoreDNS in Azure Kubernetes Service](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/dns/basic-troubleshooting-dns-resolution-problems)
*   [CoreDNS 1.13.1 forward plugin](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md)
*   [CoreDNS forward plugin metrics](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md#metrics)
*   [Kubernetes DNS debugging](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
*   [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
*   [Full AKS CoreDNS failover validation plan](../AKS_CoreDNS_Failover_Validation.md)
*   [Established `aks01day2` validation result](../validation/results/aks01day2-20260923-232149.md)
