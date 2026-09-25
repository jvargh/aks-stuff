# AKS and VMSS Tag Counts with Azure Resource Graph

Use these read-only queries to count tags on AKS clusters and their associated VMSS resources, then identify resources with limited tag capacity.

### How to run

1.  Open **Azure portal > Resource Graph Explorer** and select the subscriptions to assess.
2.  Paste a complete query below into the editor and select **Run query**. Run both queries to check cluster and VMSS tags separately.
3.  Review `tagCount`, `remainingTagSlots`, and `tagRisk`. To list only resources above 80% utilization, add `| where tagCount > 40` before the final `order by` and rerun.

You need read access to the AKS resources and their node resource groups. The tables below illustrate the output using generic resource names.

Both queries return a `tagRisk` column:

| Tag count | tagRisk |
| --- | --- |
| 0-39 | Healthy |
| 40-44 | Warning |
| 45-49 | Critical |
| 50 or more | LimitReached |

`remainingTagSlots` is **50 minus the tag count**. Together with `tagRisk`, it describes current tag capacity, not overall AKS health or guaranteed operation success. Exactly 50 tags is allowed, but leaves no room for another key.

**Above 80%** means more than 40 tags (`> 40`); **at or above 80%** includes 40 (`>= 40`). The default queries retain all rows, including `Healthy` resources.

## 1\. AKS Cluster Tags

### What it does

*   Lists AKS cluster resources, their resource groups, and their node resource groups.
*   Returns tag names and counts on the cluster resource itself.
*   Reports zero when the returned tag bag is absent or empty.
*   Shows remaining slots out of 50 and `tagRisk`, with the highest tag counts first.

Query file: [kql\_clusters.kql](kql_clusters.kql).

```
Resources
| where type =~ 'microsoft.containerservice/managedclusters'
| project id, name, subscriptionId, resourceGroup, location,
    nodeResourceGroup = tostring(properties.nodeResourceGroup),
    tagNames = bag_keys(tags),
    tagCount = coalesce(array_length(bag_keys(tags)), 0)
| extend remainingTagSlots = 50 - tagCount,
    tagRisk = case(
        tagCount >= 50, 'LimitReached',
        tagCount >= 45, 'Critical',
        tagCount >= 40, 'Warning',
        'Healthy')
| order by tagCount desc, id asc
```

### Example output

Selected columns, sorted by descending tag count:

| Cluster | Resource group | Tag count | Remaining slots | tagRisk |
| --- | --- | --- | --- | --- |
| aks-cluster-03 | rg-aks-03 | 48 | 2 | Critical |
| aks-cluster-01 | rg-aks-01 | 47 | 3 | Critical |
| aks-cluster-04 | rg-aks-04 | 46 | 4 | Critical |
| aks-cluster-02 | rg-aks-02 | 41 | 9 | Warning |

All four example clusters are above 80% utilization.

**These counts apply only to the AKS cluster resources**, not their node resource groups or backing VMSS resources. A zero cluster tag count does not mean its VMSS resources have no tags.

## 2\. AKS-Associated VMSS Tags

### What it does

*   Finds VMSS resources in AKS node resource groups and identifies their associated clusters.
*   Counts all tags, including AKS-managed tags.
*   Returns remaining slots and `tagRisk` for each VMSS. These counts do not include individual VM instance tags.

Query file: [kql\_vmss.kql](kql_vmss.kql).

### How the query works

1.  **Select and count:** `where` selects VMSS resources. `bag_keys(tags)` lists their tag names, `array_length()` counts them, and `coalesce(..., 0)` handles an empty or missing tag bag.
2.  **Normalize matching fields:** `tolower()` makes subscription, resource-group, and pool-name comparisons case-insensitive.
3.  **Inner join - identify the cluster:** Match the VMSS subscription and resource group to an AKS cluster's subscription and `properties.nodeResourceGroup`. Only VMSS with a matching cluster record remain; unrelated VMSS are excluded.
4.  **Left outer join - add the pool name:** `mv-expand` turns the cluster's pool list into one row per pool. The join matches the VMSS pool-name value to a pool in that same cluster. Unlike the inner join, it keeps the VMSS even when no pool matches; the pool name then displays as `Unknown`, while tag counting still works.
5.  **Calculate and display:** `extend` calculates remaining slots and risk. `case()` checks the highest threshold first, so a resource with 50 tags receives `LimitReached`, not `Critical`. The final `project` selects the output columns, and `order by` puts the highest tag counts first.

```
Resources
| where type =~ 'microsoft.compute/virtualmachinescalesets'
| project id, name, type, subscriptionId, resourceGroup, location,
    poolNameFromTag = tostring(tags['aks-managed-poolName']),
    tagNames = bag_keys(tags),
    tagCount = coalesce(array_length(bag_keys(tags)), 0)
| extend subscriptionKey = tolower(subscriptionId),
    nodeResourceGroupKey = tolower(resourceGroup),
    nodePoolKey = tolower(poolNameFromTag)
| join kind=inner (
    Resources
    | where type =~ 'microsoft.containerservice/managedclusters'
    | project clusterResourceId = id, clusterName = name,
        clusterResourceGroup = resourceGroup,
        subscriptionKey = tolower(subscriptionId),
        nodeResourceGroupKey = tolower(tostring(properties.nodeResourceGroup))
    | where isnotempty(nodeResourceGroupKey)
) on subscriptionKey, nodeResourceGroupKey
| extend clusterKey = tolower(clusterResourceId)
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.containerservice/managedclusters'
    | mv-expand pool = properties.agentPoolProfiles limit 2000
    | project clusterKey = tolower(id), nodePoolKey = tolower(tostring(pool.name)),
        matchedPoolName = tostring(pool.name)
    | where isnotempty(nodePoolKey)
) on clusterKey, nodePoolKey
| extend nodePoolName = iff(isnotempty(matchedPoolName), matchedPoolName, 'Unknown'),
    poolMappingStatus = case(
        isempty(poolNameFromTag), 'MissingPoolTag',
        isempty(matchedPoolName), 'UnmatchedPoolTag',
        'MatchedPoolTag'),
    remainingTagSlots = 50 - tagCount,
    tagRisk = case(
        tagCount >= 50, 'LimitReached',
        tagCount >= 45, 'Critical',
        tagCount >= 40, 'Warning',
        'Healthy')
| project id, name, type, subscriptionId, resourceGroup, location,
    clusterResourceId, clusterName, clusterResourceGroup, nodePoolName,
    poolNameFromTag, poolMappingStatus, tagNames, tagCount, remainingTagSlots,
    tagRisk
| order by tagCount desc, id asc
```

### Example output

This example shows six VMSS across four clusters.

| AKS cluster | VMSS | Node pool | Tag count | Remaining slots | tagRisk |
| --- | --- | --- | --- | --- | --- |
| aks-cluster-03 | vmss-cluster-03-nodepool1 | nodepool1 | 50 | 0 | LimitReached |
| aks-cluster-01 | vmss-cluster-01-syspool | syspool | 47 | 3 | Critical |
| aks-cluster-04 | vmss-cluster-04-nodepool1 | nodepool1 | 46 | 4 | Critical |
| aks-cluster-02 | vmss-cluster-02-syspool | syspool | 41 | 9 | Warning |
| aks-cluster-01 | vmss-cluster-01-userpool | userpool | 15 | 35 | Healthy |
| aks-cluster-02 | vmss-cluster-02-userpool | userpool | 14 | 36 | Healthy |

Filtering with `tagCount > 40` returns the first four VMSS: one `LimitReached`, two `Critical`, and one `Warning`. The two `Healthy` VMSS are excluded.

**Cluster and VMSS counts are independent:** in this example, `aks-cluster-03` has 48 cluster tags, while its VMSS has 50. Check both resource types rather than treating a cluster's tag count as its VMSS count.

## Limits and considerations

| Applies to | Limitation | What to do |
| --- | --- | --- |
| Both queries | Only resources in the selected scope that you can read are returned. Inaccessible resources are absent, not zero-tag rows. | Select the intended subscriptions and ensure read access to the cluster and node resource groups. |
| Both queries | ARG API/CLI responses return at most 1,000 rows per page. | Retrieve all pages for larger inventories. Avoid `take` or `limit` when you need complete results. |
| Both queries | ARG can lag recent resource changes. | Rerun after indexing catches up, or use a direct resource read when an immediate count is needed. |
| Both queries | Counts reflect stored tags, not additional tags an operation might attempt to add. | Use the results to assess headroom, not to guarantee an upgrade, migration, or reconciliation will succeed. |
| VMSS query | The inner join excludes VMSS without a visible matching AKS cluster and node resource group. | Investigate unexpectedly missing resources; an empty result does not establish that all resources are healthy. |
| VMSS query | Only VMSS resource tags are counted, not individual instance tags or standalone VM resources. | Use a separate inventory if those resource types are also required. |

Empty or missing tag bags are counted as zero. Missing or unmatched pool metadata does not remove a VMSS already matched to a cluster; its pool name is shown as `Unknown`.

## Adjust the queries

Add filters before the final `order by`:

- **Above 80% utilization:** `| where tagCount > 40`
- **At or above 80% utilization:** `| where tagCount >= 40`
- **Only Critical and LimitReached:** `| where tagCount >= 45`
- **A specific cluster in Query 1:** `| where name =~ 'your-cluster-name'`
- **A specific cluster's VMSS in Query 2:** `| where clusterName =~ 'your-cluster-name'`

Cluster names can repeat across subscriptions or resource groups. Add a subscription/resource-group filter or use the full resource ID when an exact target is required.

To change warning or critical thresholds, edit `40` and `45` in the `tagRisk` calculation in both queries and update any corresponding filters. Keep `50` unchanged: it is the resource tag limit, not a configurable threshold.

When extending Query 2:

- Keep `mv-expand ... limit 2000`. This caps pool expansion per input row at ARG's maximum of 2,000; omitting it defaults to 128. It is separate from the 1,000-row response-page limit.
- The query uses two joins and one `mv-expand`. Check [ARG operator limits](https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language#supported-tabulartop-level-operators) before adding more joins, unions, or expansions.
- Keep the scalar `id` column and deterministic sorting when implementing [pagination](https://learn.microsoft.com/azure/governance/resource-graph/concepts/work-with-data#paging-results). Resource changes during collection can still affect results.