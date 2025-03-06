#!/bin/bash

# Input validation
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: $0 <cluster_name> <region> <aws_account_number>"
    exit 1
fi

cluster_name=$1
region=$2
aws_account_number=$3

# Assume the admin role and obtain temporary credentials
session_name="update-auth-session-$(date +%Y%m%d%H%M%S)"
credentials=$(aws sts assume-role --role-arn arn:aws:iam::$aws_account_number:role/sys-role --role-session-name $session_name)

if [ -z "$credentials" ]; then
    echo "Failed to assume role. Exiting."
    exit 1
fi

aws_access_key_id=$(echo "$credentials" | jq -r '.Credentials.AccessKeyId')
aws_secret_access_key=$(echo "$credentials" | jq -r '.Credentials.SecretAccessKey')
aws_session_token=$(echo "$credentials" | jq -r '.Credentials.SessionToken')

if [ -z "$aws_access_key_id" ] || [ -z "$aws_secret_access_key" ] || [ -z "$aws_session_token" ]; then
    echo "Failed to parse credentials. Exiting."
    exit 1
fi

# Configure AWS CLI with temporary credentials
echo "Configuring AWS CLI..."
aws configure set aws_access_key_id "$aws_access_key_id"
aws configure set aws_secret_access_key "$aws_secret_access_key"
aws configure set aws_session_token "$aws_session_token"
aws configure set region "$region"

# Update kubeconfig
echo "Updating kubeconfig for cluster: $cluster_name in region: $region..."
aws eks update-kubeconfig --name "$cluster_name" --region "$region"

if [ $? -ne 0 ]; then
    echo "Error updating kubeconfig. Please check your inputs and IAM permissions. Exiting."
    exit 1
fi

echo "Kubeconfig updated successfully."
