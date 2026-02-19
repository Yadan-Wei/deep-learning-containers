# EKS 1.33 Upgrade Notes

## Breaking Change: AL2 → AL2023

EKS 1.33 **dropped support for Amazon Linux 2 (AL2)** and only supports **Amazon Linux 2023 (AL2023)**.

This means nodegroups cannot be upgraded in-place - they must be **recreated** with AL2023.

## What Was Changed

### 1. `upgrade_operation.sh`
- Modified `upgrade_nodegroups()` function to detect EKS 1.33+
- For 1.33+: Deletes old AL2 nodegroups and recreates with AL2023
- For older versions: Uses standard `eksctl upgrade nodegroup`
- Preserves nodegroup configuration (instance type, capacity, etc.)

### 2. `create_cluster.sh`
- Modified `create_node_group()` function to automatically use AL2023 for EKS 1.33+
- Adds `--node-ami-family AmazonLinux2023` flag when creating nodegroups on 1.33+
- Applies to all nodegroup types: static, GPU, Inferentia, Graviton

### 3. `build_param.json`
- Changed operation from `upgrade-cluster` to `upgrade_nodegroup`
- This allows retrying just the nodegroup upgrade without touching the control plane

## How to Fix Your Current Situation

Your cluster control plane is already at 1.33, but nodegroups are still at 1.32 with AL2.

### Option 1: Run the Updated Script (Recommended)

```bash
cd fork-deep-learning-containers/deep-learning-containers/eks_infrastructure
bash build.sh
```

This will:
1. Delete each AL2 nodegroup (with 15min drain timeout)
2. Recreate it with AL2023 and EKS 1.33
3. Preserve instance types and capacity settings

### Option 2: Manual Fix Per Cluster

For each cluster that failed:

```bash
export AWS_REGION=<your-region>
export EKS_CLUSTER_MANAGER_ROLE=<your-role-arn>

# For each nodegroup
CLUSTER="dlc-pytorch-PR"  # or dlc-tensorflow-PR, dlc-vllm-PR
NODEGROUP="<nodegroup-name>"

# Delete old AL2 nodegroup
eksctl delete nodegroup \
  --cluster ${CLUSTER} \
  --name ${NODEGROUP} \
  --drain-timeout 15m \
  --region ${AWS_REGION}

# Create new AL2023 nodegroup
eksctl create nodegroup \
  --cluster ${CLUSTER} \
  --name ${NODEGROUP} \
  --node-type <instance-type> \
  --nodes <desired-count> \
  --nodes-min <min> \
  --nodes-max <max> \
  --node-ami-family AmazonLinux2023 \
  --region ${AWS_REGION}
```

## Important Notes

1. **Downtime**: Nodegroups will be unavailable during recreation (pods will be drained)
2. **Workload Migration**: Pods will be rescheduled to new nodes automatically
3. **No Rollback**: Once on 1.33, you cannot downgrade the control plane
4. **Future Upgrades**: All future EKS versions will require AL2023

## Verification

After upgrade, verify nodegroups are running AL2023:

```bash
# Check nodegroup AMI family
eksctl get nodegroup --cluster <cluster-name> -o json | jq -r '.[].AMIType'

# Should show: AL2023_x86_64_STANDARD or AL2023_ARM_64_STANDARD
```

## References

- [EKS 1.33 Release Notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html#kubernetes-1.33)
- [Amazon Linux 2023 for EKS](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html#amazon-linux-2023)
