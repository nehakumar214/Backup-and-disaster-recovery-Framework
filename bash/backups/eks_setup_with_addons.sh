#!/bin/bash

# Function to install eksctl if not installed
install_eksctl() {
    if ! command -v eksctl &> /dev/null; then
        echo "eksctl is not installed. Installing eksctl..."
        curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
        sudo mv /tmp/eksctl /usr/local/bin

        if [ $? -eq 0 ]; then
            echo "eksctl installed successfully. Version: $(eksctl version)"
        else
            echo "Failed to install eksctl. Please check your internet connection and try again."
            exit 1
        fi
    else
        echo "eksctl is already installed. Version: $(eksctl version)"
    fi
}

# Ensure arguments are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Usage: $0 <stack_name> <region> <account_id>"
  exit 1
fi

stack_name=$1
eks_cluster="${stack_name}-restored-eks-cluster"
region=$2
account_id=$3
namespace="kube-system"

# Install eksctl if not installed
install_eksctl

echo "Starting EKS setup with add-ons for cluster: $eks_cluster in region: $region"

# Check and create IAM OIDC provider if not already associated
echo "Checking if IAM OIDC provider is associated with the cluster..."
oidc_url=$(aws eks describe-cluster --name $eks_cluster --region $region --query "cluster.identity.oidc.issuer" --output text 2>/dev/null)

if [[ $oidc_url == "https://"* ]]; then
  echo "IAM OIDC provider already associated: $oidc_url"
else
  echo "IAM OIDC provider not found. Associating now..."
  eksctl utils associate-iam-oidc-provider \
    --cluster $eks_cluster \
    --region $region \
    --approve || exit 1
  echo "IAM OIDC provider associated successfully."
fi

# Validate IAM OIDC provider using eksctl describe-stacks
echo "Validating IAM OIDC provider association using eksctl..."
oidc_stack_status=$(eksctl utils describe-stacks --cluster $eks_cluster --region $region | grep -i oidc)

if [[ -z $oidc_stack_status ]]; then
  echo "OIDC provider validation failed. Reassociating OIDC provider..."
  eksctl utils associate-iam-oidc-provider \
    --cluster $eks_cluster \
    --region $region \
    --approve || exit 1
  echo "IAM OIDC provider reassociated successfully."
else
  echo "OIDC provider is valid and associated."
fi

# Function to delete existing service accounts
delete_service_account() {
  local sa_name=$1
  echo "Deleting existing service account: $sa_name in namespace: $namespace"
  eksctl delete iamserviceaccount \
    --cluster $eks_cluster \
    --namespace $namespace \
    --name $sa_name \
    --region $region || echo "No existing service account to delete."
}

# Function to create service accounts and attach the specific policies
create_service_account() {
  local sa_name=$1
  local efs_policy_arn=$2
  local ebs_policy_arn=$3
  local role_name=$4

  echo "Deleting service account: $sa_name if it exists"
  delete_service_account $sa_name

  echo "Creating service account: $sa_name in namespace: $namespace"
  eksctl create iamserviceaccount \
    --cluster $eks_cluster \
    --namespace $namespace \
    --name $sa_name \
    --role-name $role_name \
    --attach-policy-arn $efs_policy_arn \
    --attach-policy-arn $ebs_policy_arn \
    --region $region \
    --approve || exit 1
}

# Create EBS CSI Driver Service Account and attach the relevant policies
echo "Setting up EBS CSI driver service account..."
create_service_account "ebs-csi-controller-sa" \
  "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy" \
  "eksctl-${stack_name}-restored-ebscsirole"

# Create EFS CSI Driver Service Account and attach the relevant policies
echo "Setting up EFS CSI driver service account..."
create_service_account "efs-csi-controller-sa" \
  "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy" \
  "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  "eksctl-${stack_name}-restored-efscsirole"

# Function to check if an IAM role exists
check_iam_role_exists() {
  local role_name=$1
  aws iam get-role --role-name $role_name --region $region &> /dev/null
  return $?
}

# Ensure IAM role exists before creating addon
role_name_ebs="eksctl-${stack_name}-restored-ebscsirole"
role_name_efs="eksctl-${stack_name}-restored-efscsirole"

# Check if the roles exist before adding to the addon
echo "Checking if IAM roles exist for EBS and EFS..."

check_iam_role_exists $role_name_ebs
if [ $? -ne 0 ]; then
  echo "IAM role $role_name_ebs does not exist. Exiting."
  exit 1
fi

check_iam_role_exists $role_name_efs
if [ $? -ne 0 ]; then
  echo "IAM role $role_name_efs does not exist. Exiting."
  exit 1
fi

# Install EBS CSI Driver Add-on
echo "Installing EBS CSI Driver Add-on..."
aws eks create-addon \
  --cluster-name $eks_cluster \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::$account_id:role/$role_name_ebs \
  --region $region \
  --resolve-conflicts OVERWRITE || exit 1

# Install EFS CSI Driver Add-on
echo "Installing EFS CSI Driver Add-on..."
aws eks create-addon \
  --cluster-name $eks_cluster \
  --addon-name aws-efs-csi-driver \
  --service-account-role-arn arn:aws:iam::$account_id:role/$role_name_efs \
  --region $region \
  --resolve-conflicts OVERWRITE || exit 1

echo "EKS setup with add-ons completed successfully!"