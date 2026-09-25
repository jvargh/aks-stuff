# AKS Networking Queries: Kubenet and Azure CNI Overlay

Use the read-only Azure Resource Graph (ARG) query below to identify the current networking configuration of AKS clusters. It reads the cluster's `properties.networkProfile`, not cluster or VMSS tags. The additional Kusto snapshot query supports historical investigation when the required telemetry is available.

For an investigation into encrypted VM live-migration failures following a move to Azure CNI Overlay, ARG provides a **candidate cluster inventory**, while snapshots can help identify reported configuration changes. Neither query alone proves that the cluster's VMs are affected.

## Choose the query

| Area | ARG cluster query | Kusto snapshot query |
| --- | --- | --- |
| Best use | Customer-run current-state inventory | Historical migration investigation |
| Runs in | Azure Resource Graph Explorer | `AKSprod` on `https://aks.kusto.windows.net` |
| Access required | Read access to customer AKS resources | Separate access to the telemetry database |
| Time coverage | Current indexed configuration | Available snapshots within the selected time window |
| Configuration source | `properties.networkProfile` | `orchestratorProfile.kubernetesConfig` |
| Result shape | One record per visible cluster | Potentially multiple snapshots per cluster |

Keep ARG as the customer-facing inventory. Use snapshots as complementary evidence; they do not replace current inventory or operation diagnostics.

## How to run the ARG query

1. Open **Azure portal > Resource Graph Explorer**.
2. Select the customer subscriptions to assess. You need read access to the AKS cluster resources.
3. Paste the complete query below and select **Run query**.
4. Review `networkingType`, the underlying networking fields, and `provisioningState`.
5. Apply the filters below to narrow the results.

This query uses ARG's `Resources` table. Do not paste it directly into a Log Analytics workspace query editor, where that table is not available.

## ARG cluster networking query

```kusto
Resources
| where type =~ 'microsoft.containerservice/managedclusters'
| extend
    networkPlugin = tostring(properties.networkProfile.networkPlugin),
    networkPluginMode = tostring(properties.networkProfile.networkPluginMode),
    networkDataplane = tostring(properties.networkProfile.networkDataplane)
| extend networkingType = case(
    networkPlugin =~ 'kubenet', 'Kubenet',
    networkPlugin =~ 'azure' and networkPluginMode =~ 'overlay', 'Azure CNI Overlay',
    networkPlugin =~ 'azure', 'Azure CNI (not reported as Overlay)',
    'Other / Unknown')
| project
    id,
    clusterName = name,
    subscriptionId,
    resourceGroup,
    location,
    networkingType,
    networkPlugin,
    networkPluginMode,
    networkDataplane,
    provisioningState = tostring(properties.provisioningState),
    nodeResourceGroup = tostring(properties.nodeResourceGroup)
| order by networkingType asc, clusterName asc, id asc
```

### How it works

- **Select AKS clusters:** `where` limits the inventory to `Microsoft.ContainerService/managedClusters`.
- **Read configuration:** `extend` extracts the network plugin, plugin mode, and dataplane as strings.
- **Classify networking:** `case()` checks Kubenet first, then Azure CNI with Overlay mode, then other reported Azure CNI configurations. Comparisons using `=~` are case-insensitive.
- **Keep incomplete records visible:** missing or unrecognized plugin values produce `Other / Unknown`, rather than silently dropping the cluster.
- **Identify resources:** the output includes the full resource ID and node resource group for follow-up investigation. No VMSS join or tag inspection is performed.

### Interpret the fields

| Field or classification | Meaning |
| --- | --- |
| `Kubenet` | `networkPlugin` is `kubenet`. |
| `Azure CNI Overlay` | `networkPlugin` is `azure` and `networkPluginMode` is `overlay`. |
| `Azure CNI (not reported as Overlay)` | The plugin is `azure`, but the returned mode is not `overlay`. This includes an empty mode; check the direct resource configuration if the result is unexpected. |
| `Other / Unknown` | The plugin is missing or outside the classifications above. Investigate rather than treating it as unaffected. |
| `networkDataplane` | The reported dataplane, such as `azure` or `cilium`. A blank value means it was not returned; this query does not infer a default. |
| `provisioningState` | The cluster's reported provisioning state. It does not establish that every node has completed a networking transition. |

**Cilium and Overlay are different settings.** Cilium identifies the dataplane; Overlay identifies the networking mode. Do not use `networkDataplane = cilium` alone to identify Overlay clusters.

### Example output

Selected columns from the supplied output, with generic cluster aliases. Resource IDs, subscription IDs, and resource-group names are omitted.

| clusterName | location | networkingType | networkPlugin | networkPluginMode | networkDataplane | provisioningState |
| --- | --- | --- | --- | --- | --- | --- |
| aks-cluster-01 | eastus2 | Azure CNI Overlay | azure | overlay | cilium | Succeeded |
| aks-cluster-02 | centralus | Azure CNI Overlay | azure | overlay | cilium | Succeeded |
| aks-cluster-03 | centralus | Azure CNI Overlay | azure | overlay | cilium | Succeeded |
| aks-cluster-04 | eastus2 | Azure CNI Overlay | azure | overlay | azure | Succeeded |
| aks-cluster-05 | eastus2 | Azure CNI Overlay | azure | overlay | cilium | Succeeded |

**What this shows:**

- All five returned cluster records report Azure CNI Overlay: four use the Cilium dataplane and one uses the Azure dataplane.
- The Overlay filter retains all five records; the Kubenet filter returns none from this example. This does not establish the absence of Kubenet clusters outside the queried scope.
- `Succeeded` is the reported cluster provisioning state, not confirmation that encrypted VM live migration is unaffected.
- Each row describes current indexed cluster configuration. It does not establish how the cluster reached that configuration.

## Filter or summarize ARG results

Insert either filter **before the final `order by`**.

**Only Azure CNI Overlay clusters:**

```kusto
| where networkingType == 'Azure CNI Overlay'
```

**Only Kubenet clusters:**

```kusto
| where networkingType == 'Kubenet'
```

**One specific cluster:** insert this immediately after the resource-type filter, replacing all placeholders:

```kusto
| where name =~ '<cluster-name>'
    and resourceGroup =~ '<resource-group>'
    and subscriptionId =~ '<subscription-id>'
```

Cluster names can repeat across subscriptions and resource groups. Use all three fields, or filter by the full `id`, for an exact target.

**Counts by subscription, region, and networking type:** replace the final `order by` with:

```kusto
| summarize clusterCount = count() by subscriptionId, location, networkingType
| order by subscriptionId asc, location asc, networkingType asc
```

These are cluster counts, not counts of affected VMs.

## Additional query: historical cluster networking snapshots

Run this query in a Kusto query client, not Resource Graph Explorer. The supplied connection details are:

| Setting | Value |
| --- | --- |
| Cluster URL | `https://aks.kusto.windows.net` |
| Database | `AKSprod` |
| Table | `ManagedClusterSnapshot` |

Connect to the cluster and select `AKSprod`. The query below uses the fully qualified table reference. AKS resource read access does not by itself grant access to this database; separate telemetry permissions are required. The connection details have not been independently tested.

### Set the scope and time window

1. Replace the subscription placeholders with the customer subscription IDs. Keep one entry for a single subscription, or add entries for multiple subscriptions.
2. Adjust `queryFrom` and `queryTo` to span before and after the suspected migration. The example uses the last seven days; for an older incident, replace both expressions with explicit UTC `datetime(...)` values.
3. Run the complete query. Keep all networking modes initially so a Kubenet-to-Overlay change is not hidden by an Overlay-only filter.

```kusto
let querySubscriptionIds = dynamic([
    "<subscription-id-1>",
    "<subscription-id-2>"
]);
let queryTo = now();
let queryFrom = queryTo - 7d;
cluster("https://aks.kusto.windows.net").database("AKSprod").ManagedClusterSnapshot
| where PreciseTimeStamp between (queryFrom .. queryTo)
| where subscription in~ (querySubscriptionIds)
| extend
    k8sCurrentVersion = tostring(orchestratorProfile.orchestratorVersion),
    networkPlugin = tostring(orchestratorProfile.kubernetesConfig.networkPlugin),
    networkPluginMode = tostring(orchestratorProfile.kubernetesConfig.networkPluginMode)
| project
    PreciseTimeStamp,
    subscription,
    name,
    k8sCurrentVersion,
    networkPlugin,
    networkPluginMode
| order by subscription asc, name asc, PreciseTimeStamp asc
```

### How it works

- `between` selects snapshots within the time window, including both endpoints.
- `in~ (querySubscriptionIds)` matches any subscription in the array, case-insensitively. Adding the array alone is insufficient: it must replace the original single-subscription equality filter.
- The nested fields return the reported Kubernetes version, network plugin, and plugin mode.
- The output retains the subscription and timestamp, then sorts snapshots chronologically within each subscription/name group. This sorting is for inspection, not a guarantee of unique cluster identity.

The networking interpretation is the same as for ARG: `kubenet` identifies Kubenet; `azure` together with `overlay` identifies Azure CNI Overlay. The snapshot query does not read a dataplane field, so it does not classify Cilium.

### Example output

Representative rows using only the columns visible in the supplied snapshot output:

| k8sCurrentVersion | networkPlugin | networkPluginMode |
| --- | --- | --- |
| 1.35.1 | azure | overlay |
| 1.35.1 | azure | overlay |
| 1.35.1 | azure | overlay |

The complete query also returns `PreciseTimeStamp`, `subscription`, and `name`. They are not reproduced here; no resource identities or timestamps have been inferred from the cropped output, and these rows are not mapped to the ARG example's cluster aliases.

**What this shows:**

- The displayed snapshots report Kubernetes version `1.35.1` and Azure CNI Overlay.
- Repeated networking values do not establish whether the rows represent different clusters or multiple snapshots of the same cluster. Use the timestamp and a verified stable cluster identifier to distinguish them.
- No earlier Kubenet state is visible in this excerpt, so it does not demonstrate a Kubenet-to-Overlay transition.
- Unlike the ARG output, these columns do not identify the dataplane or provisioning state.

### Use snapshots to investigate a migration

1. Verify the table's schema and identify a stable cluster identifier. Prefer a full cluster resource ID, if exposed, and add the verified field to the output and correlation logic. Do not assume a field name that has not been checked.
2. Correlate snapshots for the same cluster. Subscription and name alone may be ambiguous across resource groups or cluster deletion/recreation.
3. Look for an earlier `networkPlugin = kubenet` snapshot followed by `networkPlugin = azure` and `networkPluginMode = overlay`.
4. Confirm the apparent transition against deployment or operation records. Snapshots show reported configuration, not proof that every node successfully completed the migration.

**This query lists snapshots; it does not automatically detect transitions.** An Overlay snapshot with no earlier Kubenet snapshot does not prove that the cluster was created with Overlay or never migrated.

### Snapshot-specific limitations

- Table schema, retention, collection frequency, and completeness have not been independently verified. The field paths above come from the supplied query.
- A short time window, expired records, missing snapshots, or incomplete telemetry scope can hide a transition. An empty result is not proof of no impact.
- Multiple rows can refer to the same cluster. Do not count snapshot rows as clusters or affected VMs.
- Reducing the output to only the latest snapshot per cluster discards the before-and-after evidence needed for migration analysis.
- Neither encryption configuration nor encrypted VM live-migration failures are evaluated by this query.

## Assess potential encrypted VM live-migration impact

1. **Confirm the issue conditions with the support or engineering owner.** Establish the relevant encryption configuration, migration path, versions, and any other prerequisites. Do not assume all encrypted VMs or all Overlay clusters are affected.
2. **Run the inventory and retain the full cluster IDs.** Overlay clusters are candidates for follow-up. Investigate unknown results and clusters with ongoing or failed updates separately.
3. **Verify migration history.** Use the snapshot query where available, correlating stable cluster identifiers with deployment records, infrastructure configuration history, or retained operation/change records. Current Overlay configuration alone cannot distinguish a newly created Overlay cluster from one migrated from Kubenet or another networking model.
4. **Inspect the candidate clusters' node pools and backing compute resources.** Use `nodeResourceGroup` as the starting point. Verify the encryption type and the remaining issue-specific conditions at the resource level required by the investigation.
5. **Separate candidates from confirmed impact.** Confirm affected resources using the issue's applicability criteria and relevant operation errors or engineering evidence. An Overlay match alone is not confirmation of a live-migration failure.

## Limits and considerations

| Limitation | What to do |
| --- | --- |
| Only readable resources in the selected scope are returned. | Select all intended subscriptions and verify permissions. An empty result is not proof that the customer has no relevant clusters. |
| ARG can lag recent resource changes. | Verify recent migrations and unexpected values with a direct AKS resource read of `networkProfile` and provisioning state. |
| The ARG query reports current indexed configuration, not migration history or per-node transition state. | Use historical snapshots where available, and check deployment/change records and node-pool operation status separately. |
| Neither query evaluates encryption settings or live-migration failures. | Correlate with backing compute configuration and diagnostics before asserting impact. |
| ARG API/CLI responses are paged, with at most 1,000 rows per page. | Retrieve all pages for a complete resource inventory. Avoid `take` or `limit` when assessing the whole estate. |

The examples retain the supplied networking values while replacing or omitting resource-identifying fields. They illustrate query output, not confirmed customer impact. The queries were not rerun as part of this documentation update.

## References

- [Azure CNI powered by Cilium: Overlay and other networking configurations](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium#create-a-new-aks-cluster-with-azure-cni-powered-by-cilium)
- [AKS networking troubleshooting: inspect the network profile](https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/logs/aks-networking-customer-data-collection)
- [Working with Azure Resource Graph results and pagination](https://learn.microsoft.com/azure/governance/resource-graph/concepts/work-with-data)
