# CoreDNS in AKS: service discovery, upstream DNS, and failover

> **TL;DR:** A healthy CoreDNS pod does not guarantee that every application name will resolve. Azure Kubernetes Service (AKS) uses CoreDNS for Domain Name System (DNS) service discovery and upstream forwarding, and understanding those two roles helps you troubleshoot the right part of the system. Explore how they work, what AKS manages, and what failure tests reveal in the [CoreDNS guidance and test suites on GitHub](https://github.com/jvargh/aks-stuff/tree/main/coredns).
>
> **Who this is for:** Platform engineers, application developers, and operations teams who want a practical understanding of CoreDNS in AKS.

**Table of contents**

1. [Where CoreDNS fits in AKS](#1-where-coredns-fits-in-aks)
2. [How a pod gets a DNS answer](#2-how-a-pod-gets-a-dns-answer)
3. [What AKS manages and what you can customize](#3-what-aks-manages-and-what-you-can-customize)
4. [How CoreDNS selects and checks upstream servers](#4-how-coredns-selects-and-checks-upstream-servers)
5. [What failure tests on AKS showed](#5-what-failure-tests-on-aks-showed)
6. [Troubleshooting the right part of the DNS path](#6-troubleshooting-the-right-part-of-the-dns-path)
7. [A repeatable way to validate CoreDNS behavior](#7-a-repeatable-way-to-validate-coredns-behavior)
8. [Conclusion and next steps](#8-conclusion-and-next-steps)

## 1. Where CoreDNS fits in AKS

A pod can resolve another Kubernetes Service but fail to resolve a database name outside the cluster. CoreDNS can be running normally in both cases.

That distinction matters because several problems can look like the same DNS outage:

- **A cluster Service name fails.** The namespace, Service record, or path from the pod to cluster DNS may be wrong.
- **A name outside the cluster fails.** CoreDNS may be reachable, but the upstream server or its network path may not be.
- **A lookup eventually succeeds, but the application fails.** The application may have stopped waiting before DNS returned an answer.

CoreDNS is the default cluster DNS service in AKS. It runs as pods in `kube-system`, rather than as code inside your application or as a server hosted in the AKS control plane.

It has two important jobs:

1. **Kubernetes service discovery:** Answer names associated with Kubernetes resources, so workloads do not have to track changing addresses.
2. **Upstream forwarding:** Send queries that require another DNS server to the configured upstream resolvers.

Microsoft's [AKS DNS concepts guide](https://learn.microsoft.com/azure/aks/dns-concepts) explains this architecture. The key operational lesson is simple: **CoreDNS is part of the resolution path, but it is not the owner of every DNS answer.**

## 2. How a pod gets a DNS answer

For a typical pod using `dnsPolicy: ClusterFirst`, without a node-local DNS layer, the path looks like this:

```text
Application in a pod
    -> cluster DNS Service: kube-dns
    -> CoreDNS pod
         -> Kubernetes Service information: answer a cluster Service name
         -> upstream DNS server: forward a name handled outside the cluster
    -> DNS answer returns to the application
```

The Service is still named `kube-dns` even when CoreDNS handles its traffic. That name does not mean the cluster is running the older kube-dns implementation.

Kubernetes configures the pod's resolver settings, including its nameserver and search domains. For Linux containers, these are visible in `/etc/resolv.conf`.

### Cluster Service names

Consider a regular ClusterIP Service named `orders` in the `checkout` namespace. With the cluster domain `cluster.local`, its full name is:

```text
orders.checkout.svc.cluster.local
```

CoreDNS's `kubernetes` plugin uses Kubernetes resource information to answer that name with the Service's cluster IP. It does not need to ask a corporate or public DNS server for that Service record.

The namespace matters. A pod in `checkout` may use the short name `orders`; a pod in another namespace normally needs `orders.checkout` or the full name. See [Kubernetes DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) for the naming rules.

### Names handled by another DNS server

For a name outside its configured cluster zones, CoreDNS can use the `forward` plugin to contact another DNS server. That may be an Azure-provided resolver or a custom resolver, depending on the cluster's network and DNS configuration.

Do not assume that every AKS cluster forwards to the same address or that two configured addresses always mean primary and backup. Inspect the effective CoreDNS configuration and the upstream resolver settings it references.

Caching can also change the path. A valid cached answer may avoid an upstream query entirely.

### LocalDNS can change the first hop

If AKS LocalDNS is enabled, the pod can contact a DNS proxy and cache on its node first. Cluster-domain queries are forwarded to CoreDNS, while other queries can go through CoreDNS or directly to an upstream, depending on the DNS policy and LocalDNS configuration.

The diagram above is therefore a starting point, not a universal packet trace. Check whether LocalDNS is active before deciding which resolver to inspect. The [AKS DNS concepts guide](https://learn.microsoft.com/azure/aks/dns-concepts) describes these alternate paths.

## 3. What AKS manages and what you can customize

AKS manages the CoreDNS deployment and its main configuration. The Corefile, stored in the `coredns` ConfigMap, tells CoreDNS which plugins and forwarding rules to use.

Three plugin responsibilities are useful to recognize:

| Plugin | What it does |
| --- | --- |
| `kubernetes` | Answers DNS queries for configured Kubernetes zones using cluster resource information. |
| `forward` | Sends matching queries to upstream DNS servers. |
| `cache` | Reuses stored DNS responses when enabled and allowed by its configuration. |

An upstream failure affects queries that need that upstream. It does not automatically mean that normal Kubernetes Service records have become unavailable.

For supported customization, AKS provides the `coredns-custom` ConfigMap. Microsoft documents custom entries with names ending in `.server` or `.override`, including domain-specific forwarding examples.

**Do not edit the managed main Corefile as a shortcut.** A CoreDNS option being valid does not mean that every way of applying it is supported in AKS.

For example, forwarding one private domain to designated resolvers is different from replacing the managed root forwarding behavior for the entire cluster. Follow the [AKS CoreDNS customization guidance](https://learn.microsoft.com/azure/aks/coredns-custom) for the intended change.

Also check the deployed image. The tests discussed here used CoreDNS 1.13.1. A setting shown in documentation for a newer CoreDNS release may not exist in that image.

## 4. How CoreDNS selects and checks upstream servers

Once a query reaches the `forward` plugin, three separate decisions matter: which server to try, when to try another, and whether a server should be skipped on later queries.

### Selection policy chooses the starting server

For CoreDNS 1.13.1:

- `random` chooses among eligible upstreams. It is the default when no policy is specified.
- `round_robin` rotates the initial choice.
- `sequential` tries upstreams in their configured order, preferring the first one not marked unhealthy.

Here is an **illustrative isolated-lab fragment**, not a change to apply to AKS-managed CoreDNS. The addresses are placeholders:

```text
forward . <primary-dns-ip> <backup-dns-ip> {
    policy sequential
    failover SERVFAIL
}
```

`policy sequential` controls the order. `failover SERVFAIL` permits another upstream attempt when the response says the server could not complete the lookup. Those are different settings for different decisions.

### A missing reply and an error reply are different

If packets are silently dropped, CoreDNS receives no answer and must wait for a timeout. If the server returns `SERVFAIL`, CoreDNS has received a DNS error response.

By default, the `forward` plugin returns that `SERVFAIL` to the caller instead of trying another server. An explicit `failover` rule can change the handling of selected response codes.

Protocol matters too. User Datagram Protocol (UDP) does not open a connection before sending the query. Transmission Control Protocol (TCP) does.

In this release, the read timeout is two seconds. Opening a TCP connection has a separate timeout that starts at 30 seconds and can decrease toward one second based on recent connection times. There is no single timeout that describes every failure.

These behaviors are documented in the [CoreDNS 1.13.1 forward reference](https://github.com/coredns/coredns/blob/v1.13.1/plugin/forward/README.md).

### Health checks change later selections

The `forward` plugin starts upstream health checking after a network error. It does not continuously poll every untouched healthy upstream before any failure occurs.

The documented default check interval is 0.5 seconds. That is **not** a promise that failover finishes in half a second: the triggering query may already be waiting for a timeout.

`max_fails` controls how many failed health checks mark an upstream unhealthy. Its default is 2; the application-impact lab used 1 to make the change easier to observe.

A DNS error response can still prove network reachability. Health checking therefore does not prove that an upstream can successfully resolve every name your application needs.

Each CoreDNS process keeps its own upstream health state. Testing one replica does not establish the state of every replica, and restarting a resolver resets that state. The [health-check guide and evidence](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/04-Active-health-checks.md) distinguish source-backed behavior from measured, partial, and inconclusive cases.

## 5. What failure tests on AKS showed

The September 25, 2026 run used Kubernetes `v1.35.7` and image `mcr.microsoft.com/oss/v2/kubernetes/coredns:v1.13.1-20`.

Tests ran against separate CoreDNS resolvers and controlled upstream servers in an isolated namespace. They did not inject faults into AKS-managed CoreDNS or validate every production DNS path, including LocalDNS.

The test resolver used sequential selection and `max_fails 1`. Query times below are in milliseconds (ms).

| Test condition | Recorded result |
| --- | --- |
| First UDP query after silent primary packet loss | Backup answer in **2,000 ms** |
| Independent one-second and two-second client timeouts | Both clients received no response before timing out |
| Five-second client timeout | Backup answer in **2,000 ms** |
| Three later queries after the primary was marked unhealthy | Backup answers, each displayed as **0 ms** |
| Primary returned `SERVFAIL`, with default handling | `SERVFAIL` returned to the client |
| Same error with `failover SERVFAIL` configured | Successful answer from the backup |
| First forced-TCP query with silent primary packet loss | `SERVFAIL`, no address answer, after **30,000 ms** |
| Both test upstreams blocked | No response before the five-second client timeout |

Five additional independent UDP failure cycles reached the backup in **2,000-2,004 ms** on the first query. Their later queries took **0-4 ms**.

The [result summary](https://github.com/jvargh/aks-stuff/blob/main/coredns/validation/results/aks01day2-impact-20260925.md) and [raw query output](https://github.com/jvargh/aks-stuff/blob/main/coredns/validation/results/aks01day2-impact-20260925-102725.json) retain the details.

These are observations for one image and controlled failure conditions, not guaranteed AKS timings. A displayed `0 ms` reflects the tool's timing precision, not zero latency.

The practical lesson: **an available CoreDNS pod, a reachable backup, and a successful application request are three different things.**

## 6. Troubleshooting the right part of the DNS path

Start by separating cluster Service resolution from upstream resolution. Then inspect the configuration before changing it.

**Prerequisites:** PowerShell 7+, installed and authenticated `kubectl`, and permission to read CoreDNS Deployments, pods, Services, and ConfigMaps in the intended cluster. Check the context first and stop if it is not the correct cluster. The following commands are read-only.

```powershell
kubectl config current-context
kubectl get deployment coredns -n kube-system `
    -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get service kube-dns -n kube-system
kubectl get configmap coredns -n kube-system -o yaml
```

Use the findings to narrow the investigation:

- **Only a cluster Service name fails:** Check the Service name, namespace, and record type. Confirm that the Service exists and that the pod is using the expected cluster DNS path.
- **Only names requiring an upstream fail:** Check the matching forwarding rule, upstream reachability, and the upstream's ability to resolve that name.
- **Only some pods fail:** Compare their DNS policies, resolver settings, node-local DNS path, and network access. A successful query from another pod is useful, but not conclusive.
- **The first query is slow and later queries are fast:** Check upstream health state and caching. Do not assume the first result was an unrelated glitch.
- **CoreDNS returns `SERVFAIL`:** Identify whether it came from an upstream response or another failure. Do not assume it means packets were lost.

Measure DNS latency with `dig`'s `Query time`. The elapsed time of `kubectl exec` also includes Kubernetes API communication and process startup.

Finally, look at the application. A reused connection may avoid DNS, a cached answer may hide an outage, and retries may increase load. A client can time out even if CoreDNS eventually finds an answer.

The latest suite recorded **13 passing DNS and environment checks and five blocked application-specific cases**. No representative application was supplied, so caching, connection reuse, retries, application telemetry, and service-level objective (SLO) impact were not established. A DNS test alone cannot prove the user's experience.

## 7. A repeatable way to validate CoreDNS behavior

The [CoreDNS repository folder](https://github.com/jvargh/aks-stuff/tree/main/coredns) organizes these questions into five detailed guides:

| Guide | What to validate |
| --- | --- |
| [Selection policy](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/01-Selection-policy.md) | Which upstream is tried first, and how the policy behaves during failure. |
| [Timeout behavior](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/02-Timeout-before-next-upstream.md) | The difference between waiting for a reply, opening a connection, and the client's own timeout. |
| [Failover mechanism](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/03-Failover-mechanism.md) | Network failures, DNS error responses, recovery, and all-upstream failure. |
| [Health checks](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/04-Active-health-checks.md) | How errors start checks and how health state affects later queries. |
| [Application and user impact](https://github.com/jvargh/aks-stuff/blob/main/coredns/responses/05-Application-and-user-impact.md) | Which DNS results are measured and which application effects still require a workload test. |

Each guide maps a question to named test cases, expected results, pass/fail criteria, and an Established evidence section. That section should tell you what happened, when it happened, and what the result does not prove.

**Prerequisites for fault testing:** An authorized test cluster, PowerShell 7+, authenticated `kubectl`, permission to create and remove namespace-local test resources, and a network implementation that enforces the test NetworkPolicies. Review the selected guide's full setup and cleanup instructions before execution.

Use an isolated test resolver. Do not change managed `kube-system` resources to reproduce an upstream failure. If another test namespace already exists and ownership is unclear, choose a unique namespace instead of deleting it.

The published examples include the original lab context and paths beginning with `07-CoreDNS`. A GitHub clone uses `coredns`. Adjust these values for your environment before running a suite.

Cleanup is part of the test. In the September 25 run, the unique test namespace was removed, all six base-lab Deployments remained Available, both managed CoreDNS replicas remained Available, and the managed Deployment resource version was unchanged.

## 8. Conclusion and next steps

CoreDNS connects AKS workloads to both Kubernetes service discovery and the wider DNS environment. Understanding where a query is answered is the first step toward understanding why it failed.

Start with the pod's DNS path. Inspect the CoreDNS version and configuration. Separate Service records from upstream queries. Then test selection, timeouts, health checks, and application behavior without changing managed cluster DNS.

**Understand the path before changing the policy. Validate the behavior before promising the outcome.**

### Try it now

**Prerequisites:** Git, PowerShell, network access to GitHub, and a working directory without an existing `aks-stuff` folder. No Azure permissions are needed to download the guides. These commands do not deploy resources or run failure tests.

```powershell
git clone https://github.com/jvargh/aks-stuff.git
Set-Location .\aks-stuff
Get-Content .\coredns\README.md
```

### Learn more

- [CoreDNS guidance and test suites](https://github.com/jvargh/aks-stuff/tree/main/coredns)
- [DNS concepts in AKS](https://learn.microsoft.com/azure/aks/dns-concepts)
- [Supported CoreDNS customization in AKS](https://learn.microsoft.com/azure/aks/coredns-custom)
- [Latest validation summary](https://github.com/jvargh/aks-stuff/blob/main/coredns/validation/results/aks01day2-impact-20260925.md) and [recorded query output](https://github.com/jvargh/aks-stuff/blob/main/coredns/validation/results/aks01day2-impact-20260925-102725.json)

### Connect and contribute

Share a reproducible finding through the [GitHub repository](https://github.com/jvargh/aks-stuff). Include the CoreDNS version, DNS path, test case, failure condition, client timeout, measured result, and cleanup outcome. Remove credentials, private addresses, and customer identifiers before sharing logs.

**Start here:** [github.com/jvargh/aks-stuff/tree/main/coredns](https://github.com/jvargh/aks-stuff/tree/main/coredns)
