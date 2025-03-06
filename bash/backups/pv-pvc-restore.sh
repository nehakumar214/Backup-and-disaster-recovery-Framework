#!/bin/bash

# Define kubeconfig path
KUBECONFIG_PATH="/root/.kube/config"

# Input Parameters
customer_name=$1
namespace=$2
region=$3

if [ -z "$customer_name" ] || [ -z "$namespace" ] || [ -z "$region" ]; then
  echo "Usage: $0 <customer_name> <namespace> <region>"
  exit 1
fi

# Fetch and filter the latest snapshots by the specified tag
snapshots=$(aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*${customer_name}*" \
  --query "Snapshots[*].{SnapshotId:SnapshotId,StartTime:StartTime,AZ:AvailabilityZone,Tags:Tags}" \
  --output json | jq -c '[group_by(.Tags[] | select(.Key=="kubernetes.io/created-for/pvc/name").Value)[] | max_by(.StartTime)]')

# Check if any snapshots were found
if [ -z "$snapshots" ] || [ "$snapshots" == "[]" ]; then
  echo "No snapshots found matching the tag for customer: $customer_name"
  exit 1
fi

# Output the snapshots for debugging
echo "Latest snapshots found for customer '$customer_name':"
echo "$snapshots" | jq .

# Function to extract component name from snapshot tags
get_component_name() {
  tag_value=$(echo "$1" | jq -r '.Tags[] | select(.Key == "kubernetes.io/created-for/pvc/name").Value')

  # Extract component name based on expected tag structure
  if [[ "$tag_value" =~ ^.*-(consul|rabbitmq|ai|postgresql)-.*$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Process snapshots
echo "$snapshots" | jq -c '.[]' | while read snapshot; do
  snapshot_id=$(echo "$snapshot" | jq -r '.SnapshotId')
  az=$(echo "$snapshot" | jq -r '.AZ')
  tags=$(echo "$snapshot" | jq -c '.Tags')
  component=$(get_component_name "$snapshot")

  # Skip if the component name is not identified
  if [ -z "$component" ]; then
    echo "Unknown component for snapshot $snapshot_id. Skipping..."
    continue
  fi

  # Determine YAML file for the component
  case "$component" in
    1)
      pv_yaml="pv-component1.yaml"
      pod_label="app=consul"
      ;;
    2)
      pv_yaml="pv-component2.yaml"
      pod_label="app=xyz"
      ;;
    3)
      pv_yaml="pv-component3.yaml"
      pod_label="app=abc"
      ;;
    4)
      pv_yaml="pv-component4.yaml"
      pod_label="app=pg"
      ;;
    *)
      echo "Unknown component '$component' for snapshot $snapshot_id. Skipping..."
      continue
      ;;
  esac

  # Check if AZ is empty and fetch a valid AZ
  if [ -z "$az" ] || [ "$az" == "null" ]; then
    echo "No AZ found for snapshot $snapshot_id. Fetching a valid AZ..."
    az=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
    echo "Using AZ: $az"
  fi

  # Fetch the Kubernetes pod running the component to find the associated node
  pod_name=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get pod -n "$namespace" -l "$pod_label" -o=jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod_name" ]; then
    echo "No pod found for component '$component'. Skipping volume attachment..."
    continue
  fi

  # Fetch the node name that the pod is running on
  node_name=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.nodeName}')
  if [ -z "$node_name" ]; then
    echo "No node found for pod $pod_name. Skipping volume attachment..."
    continue
  fi

  # Fetch the EC2 instance ID associated with the node
  instance_id=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get node "$node_name" -o jsonpath='{.metadata.labels.kubernetes\.io/instance-id}')

  # Fallback to providerID if instance ID label is missing
  if [ -z "$instance_id" ]; then
    echo "No EC2 instance ID found in labels. Trying providerID..."
    instance_id=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get node "$node_name" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
  fi

  if [ -z "$instance_id" ]; then
    echo "No EC2 instance ID found for node $node_name. Skipping volume attachment..."
    continue
  fi

  # Fetch the AZ of the EC2 instance to avoid AZ mismatch
  instance_az=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text)

  # Ensure the volume is created in the same AZ as the EC2 instance
  if [ "$az" != "$instance_az" ]; then
    echo "Warning: Snapshot AZ ($az) does not match instance AZ ($instance_az). Creating volume in instance AZ..."
    az="$instance_az"
  fi

  echo "Creating volume from snapshot $snapshot_id in AZ $az for component $component..."

  # Create the volume
  new_volume_id=$(aws ec2 create-volume --snapshot-id "$snapshot_id" --availability-zone "$az" --query 'VolumeId' --output text)

  if [ -n "$new_volume_id" ]; then
    echo "Successfully created volume: $new_volume_id"

    # Reapply tags to the new volume
    if [ -n "$tags" ]; then
      filtered_tags=$(echo "$tags" | jq '[.[] | select(.Key | startswith("aws:") | not)]')
      aws ec2 create-tags --resources "$new_volume_id" --tags "$filtered_tags"
      echo "Tags applied to volume $new_volume_id: $filtered_tags"
    fi

    if [ -f "/home/bcdr/$pv_yaml" ]; then
      echo "Updating $pv_yaml with the new volume $new_volume_id and AZ $az..."
      sed -i "s|volumeHandle:.*|volumeHandle: $new_volume_id|" "/home/bcdr/$pv_yaml"
      sed -i "/values:/,/]/{/values:/!d}" "/home/bcdr/$pv_yaml"
      sed -i "/values:/a\          - $az" "/home/bcdr/$pv_yaml"
      echo "$pv_yaml updated successfully."
    else
      echo "YAML file $pv_yaml does not exist. Skipping update for component $component."
    fi
  else
    echo "Failed to create volume from snapshot $snapshot_id."
  fi
done

for term in consul rabbitmq ai postgresql; do
  pv_yaml="/home/bcdr/pv-$term.yaml"
  if [ -f "$pv_yaml" ]; then
    echo "Applying $pv_yaml to bind with PVC..."
    kubectl --kubeconfig="$KUBECONFIG_PATH" apply -f "$pv_yaml"
  fi
done

echo "Listing PVs..."
kubectl --kubeconfig="$KUBECONFIG_PATH" get pv

echo "Patching PVs to update storageClassName to 'ebs-sc'..."
kubectl --kubeconfig="$KUBECONFIG_PATH" get pv -o json | jq -r '.items[].metadata.name' | while read pv_name; do
  kubectl --kubeconfig="$KUBECONFIG_PATH" patch pv "$pv_name" -p '{"spec":{"storageClassName": "ebs-sc"}}'
done

echo "Fetching Auto Scaling Group for customer '$customer_name'..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$region" --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'eks-${customer_name}-node-group')].AutoScalingGroupName | [0]" --output text)

if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" == "None" ]; then
  echo "No Auto Scaling Group found. Exiting..."
  exit 1
fi

echo "Auto Scaling Group found: $ASG_NAME"
aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME"
echo "Auto Scaling Group refresh triggered successfully."
