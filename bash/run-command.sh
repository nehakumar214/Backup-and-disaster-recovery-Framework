#!/bin/bash

if [ $# -lt 7 ]; then
    echo "Usage: $0 <env_type> <region> <aws_access_keys> <aws_secret_keys> <stack_name> <customer_name> <script-name>  [script-params...]"
    exit 1
fi

env_type="$1"
region="$2"
aws_access_key="$3"
aws_secret_key="$4"
stack_name="$5"
customer_name="$6"
script="$7"
shift 7
params=("$@")

echo "Remove existing AWS credentials"
rm -rf /home/ec2-user/.aws/credentials

aws configure set aws_access_key_id "$aws_access_key"
aws configure set aws_secret_access_key "$aws_secret_key"
aws configure set region "$region"

get_instance_id() {
    local instance_name="$1"
    
    instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$instance_name" \
        --region "$region" \
        --query 'Reservations[].Instances[].[InstanceId]' \
        --output text)

    echo "$instance_id"
}

instance_name="${stack_name}-instance"
bastionInstanceId=$(get_instance_id "$instance_name")
echo "Instance ID of $instance_name: $bastionInstanceId"

s3_bucket="abcinfra-$env_type"

if [ ${#params[@]} -gt 0 ]; then
    command_with_params="/home/bcdr/$script ${params[@]}"
else
    command_with_params="/home/bcdr/$script"
fi

# Initialize command_to_cp_values as empty
command_to_cp_values=""

# Explicitly check for specific scripts to ensure they are downloaded from the correct locations
if [ "$script" == 'rds-snapshot-deploy.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'check-connectivity.sh' ]; then
    command_for_s3_cp="rm -rf ~/.aws && aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'add-snapshot-tags-and-dlm.sh' ]; then
    command_for_s3_cp="rm -rf ~/.aws && aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'create-cluster.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'delete_pv_pvc.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'eks_setup_with_addons.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'alb-deployment-new-cluster.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'eks-storageclass-config.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'pv-cleanup.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
elif [ "$script" == 'pv-pvc-restore.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/scripts/bcdr-tools/$script /home/bcdr/$script"
elif [ "$script" == 'application-deploy.sh' ]; then
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/backups/$script /home/bcdr/$script"
    command_to_cp_values="aws s3 cp s3://$s3_bucket/val/$customer_name.yaml /home/bcdr && chmod +x /home/bcdr/$customer_name.yaml"
else
    command_for_s3_cp="aws s3 cp s3://$s3_bucket/bash/$script /home/bcdr/$script"
fi

# Construct the commands dynamically, ensuring no dangling && when command_to_cp_values is empty
commands="if [ ! -d \"/home/bcdr/\" ]; then mkdir -p \"/home/bcdr/\"; fi && $command_for_s3_cp && chmod +x /home/bcdr/$script"
if [ -n "$command_to_cp_values" ]; then
    commands="$commands && $command_to_cp_values"
fi
commands="$commands && $command_with_params"

# Escape quotes in the commands for valid JSON
commands=$(printf '%s' "$commands" | sed 's/"/\\"/g')

# Send the SSM command
command_id=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$commands\"]}" \
    --targets "Key=instanceids,Values=$bastionInstanceId" \
    --comment "Run $script" \
    --region "$region" \
    --output text \
    --query "Command.CommandId" \
    --output-s3-bucket-name "$s3_bucket" \
    --output-s3-key-prefix command-output/)

echo "SSM_COMMAND_ID=$command_id"

while true; do
    status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$bastionInstanceId" --output text --query "Status")
    
    if [[ "$status" != "InProgress" ]]; then
        if [[ "$status" == "Success" ]]; then
            output=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$bastionInstanceId" --query "StandardOutputContent" --output text)
            echo "Command execution completed successfully:"
            echo "$output"
        else
            output=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$bastionInstanceId" --query "StandardOutputContent" --output text)
            error_output=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$bastionInstanceId" --query "StandardErrorContent" --output text)

            echo "Command execution failed with status: $status"
            echo "Standard Output:"
            echo "$output"
            echo "Error Output:"
            echo "$error_output"
            exit 1
        fi
        break
    fi
    sleep 5
done
