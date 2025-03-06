#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
    echo "Usage: $0 <stack_name> <region> <aws_account_number> <env_type>"
    exit 1
fi

stack_name=$1
region=$2
aws_account_number=$3
env_type=$4

# Function to download and prepare the update-auth.sh script
prepare_update_auth_script() {
    echo "Downloading update-auth.sh script from S3 bucket..."
    aws s3 cp s3://bcdr-$env_type/scripts/update-auth.sh /home/bcdr/

    cd /home/bcdr/

    echo "Making the downloaded script executable..."
    chmod +x update-auth.sh
}

# Function to update AWS credentials
clean_aws_credentials() {
    echo "Removing existing AWS credentials..."
    rm -rf ~/.aws
}

# Function to update auth for a specific cluster
update_auth_for_cluster() {
    local cluster_name=$1
    echo "Running update-auth.sh for cluster: $cluster_name"
    ./update-auth.sh $cluster_name $region $aws_account_number

    # Update kubeconfig for the selected cluster
    aws eks --region $region update-kubeconfig --name $cluster_name
    kubectl config use-context arn:aws:eks:$region:$aws_account_number:cluster/$cluster_name
}

# Function to check if the restored cluster exists
check_restored_cluster() {
    echo "Checking if the restored cluster exists: ${stack_name}-restored-eks-cluster"
    aws eks --region $region describe-cluster --name ${stack_name}-restored-eks-cluster > /dev/null 2>&1
    return $?
}

# Function to wait for the cluster to become ACTIVE
wait_for_cluster_active() {
    local cluster_name=$1
    local region=$2
    local max_retries=20
    local retries=0

    echo "Waiting for cluster $cluster_name to become ACTIVE..."
    while [ $retries -lt $max_retries ]; do
        status=$(aws eks describe-cluster --name $cluster_name --region $region --query "cluster.status" --output text)
        if [ "$status" == "ACTIVE" ]; then
            echo "Cluster $cluster_name is now ACTIVE."
            break
        fi
        echo "Cluster $cluster_name is not ready yet (status: $status). Retrying in 30 seconds... ($((retries + 1))/$max_retries)"
        sleep 30
        retries=$((retries + 1))
    done

    if [ $retries -eq $max_retries ]; then
        echo "Error: Cluster $cluster_name did not become ACTIVE within the expected time."
        exit 1
    fi
}

# Function to list Kubernetes pods in the cluster
list_kubernetes_pods() {
    echo "Listing all pods in all namespaces for the active cluster..."
    kubectl get pods -A --kubeconfig /root/.kube/config

    if [ $? -ne 0 ]; then
        echo "No connectivity achieved. Exiting..."
        exit 1
    fi
    echo "Successfully listed Kubernetes pods."
}

main() {
    echo "Script started..."

    prepare_update_auth_script
    clean_aws_credentials

    check_restored_cluster
    if [ $? -eq 0 ]; then
        echo "Restored cluster is available. Switching to ${stack_name}-restored-eks-cluster."
        wait_for_cluster_active "${stack_name}-restored-eks-cluster" "$region"
        clean_aws_credentials
        update_auth_for_cluster "${stack_name}-restored-eks-cluster"
    else
        echo "Restored cluster is not available yet. Updating auth for ${stack_name}-eks-cluster."
        update_auth_for_cluster "${stack_name}-eks-cluster"
    fi

    list_kubernetes_pods

    echo "Script execution completed."
}

main
