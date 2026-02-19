#!/bin/bash
#/ Usage:
#/ export AWS_REGION=<AWS-Region>
#/ export EKS_CLUSTER_MANAGER_ROLE=<ARN-of-IAM-role>
#/ target can be one of [ cluster | nodegroup ]
#/ cluster_autoscalar_image_version option is not required for [nodegroup] target
#/ ./upgrade_operation.sh <target> eks_cluster_name eks_version cluster_autoscalar_image_version
set -ex

# Function to update kubeconfig at ~/.kube/config
function update_kubeconfig() {

  eksctl utils write-kubeconfig \
    --cluster ${1} \
    --authenticator-role-arn ${2} \
    --region ${3}

  kubectl config get-contexts
}

# Function to upgrade eks control plane
function upgrade_eks_control_plane() {

  eksctl upgrade cluster \
    --name ${1} \
    --version ${2} \
    --timeout 180m \
    --approve
}

# Function to control scaling of cluster autoscalar
function scale_cluster_autoscalar() {
  kubectl scale deployments/cluster-autoscaler \
    --replicas=${1} \
    -n kube-system
}
# Function to upgrade autoscalar image
function upgrade_autoscalar_image() {
  kubectl -n kube-system \
    set image deployment.apps/cluster-autoscaler cluster-autoscaler=k8s.gcr.io/autoscaling/cluster-autoscaler:${1}
}

# Function to upgrade nodegroups
function upgrade_nodegroups() {
  CLUSTER=${1}
  EKS_VERSION=${2}
  REGION=${3}
  ERROR_LOG=${4}

  LIST_NODE_GROUPS=$(eksctl get nodegroup --cluster ${CLUSTER} -o json | jq -r '.[].Name')

  if [ -n "${LIST_NODE_GROUPS}" ]; then

    for NODEGROUP in ${LIST_NODE_GROUPS}; do
      # Get current nodegroup AMI type
      NODEGROUP_INFO=$(eksctl get nodegroup --cluster ${CLUSTER} --name ${NODEGROUP} --region ${REGION} -o json)
      CURRENT_AMI_TYPE=$(echo ${NODEGROUP_INFO} | jq -r '.[0].ImageID // "AL2_x86_64"')
      
      echo "Nodegroup ${NODEGROUP} current AMI type: ${CURRENT_AMI_TYPE}"
      
      # Check if current AMI is AL2 (needs recreation for EKS 1.33+)
      if [[ "${CURRENT_AMI_TYPE}" == "AL2_x86_64" ]] || [[ "${CURRENT_AMI_TYPE}" == "AL2_ARM_64" ]] || [[ "${CURRENT_AMI_TYPE}" == *"AL2_"* ]]; then
        echo "AL2 detected. Checking if upgrade to AL2023 is needed..."
        
        # Check if target EKS version requires AL2023 (1.33+)
        if [[ "${EKS_VERSION}" == "1.33" ]] || [[ "${EKS_VERSION}" > "1.33" ]]; then
          echo "EKS ${EKS_VERSION} requires AL2023. Recreating nodegroup ${NODEGROUP}..."
          
          # Get current nodegroup configuration
          INSTANCE_TYPE=$(echo ${NODEGROUP_INFO} | jq -r '.[0].InstanceType // "m5.xlarge"')
          DESIRED_CAPACITY=$(echo ${NODEGROUP_INFO} | jq -r '.[0].DesiredCapacity // 2')
          MIN_SIZE=$(echo ${NODEGROUP_INFO} | jq -r '.[0].MinSize // 1')
          MAX_SIZE=$(echo ${NODEGROUP_INFO} | jq -r '.[0].MaxSize // 4')
          VOLUME_SIZE=$(echo ${NODEGROUP_INFO} | jq -r '.[0].VolumeSize // 80')
          
          # Get labels and tags if they exist
          LABELS=$(echo ${NODEGROUP_INFO} | jq -r '.[0].Labels // {}' | jq -r 'to_entries | map("--node-labels \(.key)=\(.value)") | join(" ")')
          
          # Determine new AMI family based on architecture
          if [[ "${CURRENT_AMI_TYPE}" == "AL2_ARM_64" ]] || [[ "${CURRENT_AMI_TYPE}" == *"ARM_64"* ]]; then
            NEW_AMI_FAMILY="AmazonLinux2023/ARM_64"
          else
            NEW_AMI_FAMILY="AmazonLinux2023"
          fi
          
          # Delete old AL2 nodegroup
          eksctl delete nodegroup \
            --cluster ${CLUSTER} \
            --name ${NODEGROUP} \
            --drain \
            --region ${REGION} \
            --wait || echo "${NODEGROUP}-delete" >> ${ERROR_LOG}
          
          # Create new AL2023 nodegroup
          eksctl create nodegroup \
            --cluster ${CLUSTER} \
            --name ${NODEGROUP} \
            --node-type ${INSTANCE_TYPE} \
            --nodes ${DESIRED_CAPACITY} \
            --nodes-min ${MIN_SIZE} \
            --nodes-max ${MAX_SIZE} \
            --node-volume-size ${VOLUME_SIZE} \
            --node-ami-family ${NEW_AMI_FAMILY} \
            --region ${REGION} \
            ${LABELS} || echo "${NODEGROUP}-create" >> ${ERROR_LOG}
        else
          # AL2 is still supported for this version, do standard upgrade
          echo "EKS ${EKS_VERSION} still supports AL2. Performing standard upgrade..."
          eksctl upgrade nodegroup \
            --name ${NODEGROUP} \
            --cluster ${CLUSTER} \
            --kubernetes-version ${EKS_VERSION} \
            --timeout 90m \
            --region ${REGION} || echo "${NODEGROUP}" >> ${ERROR_LOG}
        fi
      else
        # Already on AL2023 or other AMI type, do standard upgrade
        echo "AMI type ${CURRENT_AMI_TYPE} detected. Performing standard upgrade..."
        eksctl upgrade nodegroup \
          --name ${NODEGROUP} \
          --cluster ${CLUSTER} \
          --kubernetes-version ${EKS_VERSION} \
          --timeout 90m \
          --region ${REGION} || echo "${NODEGROUP}" >> ${ERROR_LOG}
      fi
    done
  else
    echo "No Nodegroups present in the EKS cluster ${1}"
  fi
}

#Function to upgrade core k8s components
function update_eksctl_utils() {
  LIST_ADDONS=$(eksctl get addon --cluster ${CLUSTER}  -o json | jq -r '.[].Name')

  if [ -n "${LIST_ADDONS}" ]; then
    for ADDONS in ${LIST_ADDONS}; do
      eksctl update addon \
        --name ${ADDONS} \
        --cluster ${1} \
        --region ${2}
    done
  else
    echo "No addons present in the EKS cluster ${CLUSTER}"
  fi
}

if [ $# -lt 3 ]; then
  echo "usage: ${0} target eks_cluster_name eks_version cluster_autoscalar_image_version"
  exit 1
fi

if [ -z "${AWS_REGION}" ]; then
  echo "AWS region not configured"
  exit 1
fi

TARGET=${1}
CLUSTER=${2}
EKS_VERSION=${3}
ERROR_LOG=${4}
CLUSTER_AUTOSCALAR_IMAGE_VERSION=${5}

if [ -n "${EKS_CLUSTER_MANAGER_ROLE}" ]; then
  update_kubeconfig ${CLUSTER} ${EKS_CLUSTER_MANAGER_ROLE} ${AWS_REGION}
fi

if [ "${TARGET}" = "CLUSTER" ]; then
  #scale to 0 to avoid unwanted scaling
  scale_cluster_autoscalar 0
  upgrade_autoscalar_image ${CLUSTER_AUTOSCALAR_IMAGE_VERSION}
  upgrade_eks_control_plane ${CLUSTER} ${EKS_VERSION}
  upgrade_nodegroups ${CLUSTER} ${EKS_VERSION} ${AWS_REGION} ${ERROR_LOG}
  update_eksctl_utils ${CLUSTER} ${AWS_REGION}
  #scale back to 1
  scale_cluster_autoscalar 1
elif [ "${TARGET}" = "NODEGROUP" ]; then
  upgrade_nodegroups ${CLUSTER} ${EKS_VERSION} ${AWS_REGION} ${ERROR_LOG}
fi
