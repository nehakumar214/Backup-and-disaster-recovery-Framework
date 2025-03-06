#!/bin/bash

# Input Parameters
customer_name=$1
namespace=$2
if [ -z "$customer_name" ] || [ -z "$namespace" ]; then
  echo "Usage: $0 <customer_name> <namespace>"
  exit 1
fi

# Define kubeconfig path
KUBECONFIG_PATH="/root/.kube/config"

# Process PVCs and PVs for each generic component
for term in component1 component2 component3 component4; do
  echo "Processing PVC and PV for: $term"

  case "$term" in
    component1)
      pvc_name="data-${customer_name}-${customer_name}-component1-0"
      ;;
    component2)
      pvc_name="data-${customer_name}-component2-0"
      ;;
    component3)
      pvc_name="data-${customer_name}-component3-0"
      ;;
    component4)
      pvc_name="data-${customer_name}-component4-0"
      ;;
    *)
      echo "Unknown term: $term"
      continue
      ;;
  esac

  # Step 1: Delete PVC first
  pvc_exists=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pvc -n "$namespace" "$pvc_name" --ignore-not-found)
  if [ -n "$pvc_exists" ]; then
    echo "Deleting PVC: $pvc_name in namespace: $namespace"
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete pvc "$pvc_name" -n "$namespace" --wait=true
    echo "Waiting for PVC $pvc_name to be deleted..."
    sleep 10
  else
    echo "No PVC found for: $pvc_name, skipping PVC deletion..."
  fi

  # Step 2: Fetch the PV associated with the deleted PVC
  pv_name=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pv -o jsonpath="{.items[?(@.spec.claimRef.name=='$pvc_name')].metadata.name}")
  if [ -z "$pv_name" ]; then
    echo "No PV found for PVC: $pvc_name, skipping PV deletion..."
    continue
  fi

  # Step 3: Remove finalizer and delete PV
  for attempt in {1..5}; do
    echo "Attempt $attempt: Patching finalizer and deleting PV: $pv_name"

    kubectl --kubeconfig "$KUBECONFIG_PATH" patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}'

    timeout 60 kubectl --kubeconfig "$KUBECONFIG_PATH" delete pv "$pv_name" && echo "PV $pv_name deleted." || echo "Timed out waiting for PV deletion."

    echo "Waiting for PV $pv_name to be deleted..."
    sleep 15

    remaining_pv=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pv "$pv_name" --ignore-not-found)
    if [ -z "$remaining_pv" ]; then
      echo "PV $pv_name successfully deleted."
      break
    else
      echo "PV $pv_name still exists, retrying..."
      kubectl --kubeconfig "$KUBECONFIG_PATH" patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}'
      sleep 10
    fi
  done

  # Force deletion if stuck
  if [ -n "$remaining_pv" ]; then
    echo "PV deletion still stuck. Force deleting PV: $pv_name"
    kubectl --kubeconfig "$KUBECONFIG_PATH" patch pv "$pv_name" -p '{"metadata":{"finalizers":null},"status":{"phase":"Released"}}'
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete pv "$pv_name"
    echo "Force deleted PV $pv_name."
  fi

  echo "Successfully processed PVC and PV for $term."
done

echo "Script completed successfully."
