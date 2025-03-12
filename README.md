Overview:-

The BCDR framework restores critical infrastructure and applications with minimal downtime using automated workflows for RDS and EKS, including application deployment. framework significantly reduces the Recovery Time, ensuring faster recovery during disasters.

how are we taking backups for RDS and App deployed on EKS:

RDS Backup: We use automated continuous backups that capture every second of data, ensuring zero data loss during a disaster with retention period of 35 days. EKS Backup(component volumes): We implement data lifecycle management for key components daily and weekly volume backups.

ONCE YOU IMPLEMENT THIS FRAMEWORK IN YOUR PROJECT/PRODUCT (Follow below steps).....

Step by step deployment for RDS.. a. Copy the latest snapshot ARN from AWS console from automated backups for RDS. b. Then run the pipeline by selecting appropriate radio button with correct env, region, stack name and paste the snapshot arn which you have copied from aws console for rds restoration. c. Another selection in the pipeline is that what you want to restore…as we are performing for rds we have to choose rds. d. Once the RDS restore pipeline is completed, check the pipeline logs and AWS console for verification. The pipeline renames the old RDS with a timestamp and creates a new RDS from the snapshot. This process is reflected in both the console and logs. e. The last step is to check whether a new state file is created after the RDS restore. This state file is important for matching the Terraform configuration, ensuring proper state sync, and helps in infrastructure upgrades.(first we are taking backup of state file of original rds and then creating state for new restore rds in s3 backend)..

In the pipeline, we use terraform import to import the new RDS configuration, integrating it into the existing framework by calling the infrastructure repository.

Step by step deployment for old EKS/app-deploy..(mostly we will restore volume and app on old eks).. a. First login into the cluster and do helm repo ls to see app is running on which helm repo and latest version. b. once you got the repo name and version, in a same way add it in as a parameter in pipeline.(choose old eks as we are restoring backup volume in the old eks). c. To perform eks/app deploy what actually pipeline is doing. c.1:- First step it will uninstall the application from pipeline. c.2:- After uninstallation, PVs and PVCs remain intact. The pipeline sets finalizers to null in the YAML and then pipeline deleting the PVs and PVCs. c.3:- Post cleanup of everything will start with fresh installation of application. c.4: - After Installation of application will take backups of PV’s and then delete it. c.5:- Finally, it will create a new volume from the latest snapshot in the correct Availability Zone, and it is updating the pv.yaml file with new volume and new AZ, and deploying it using kubectl apply.

d. Once eks pipeline got completed, check the logs first that new volume has been there in the pv.yaml or not? in a same way validate in aws console new volumes are in-use or not? e. it is in-use it means it got perfectly attached with nodes:

Step by step deployment for new EKS/app-deploy..

We have also created a mechanism to restore the application on a new EKS cluster in case the existing cluster is accidentally deleted. This mechanism provisions a new EKS cluster, sets up the storage class, installs the ALB controller, applies necessary add-ons and distributions, and initiates application deployment using the backed-up volume from scratch.

Note: lastly do not forget to validate application by QA...

Framework Deployment Timeline:- a. RDS deployment- 23 mints b. EKS Restoration & Application Deployment - 15 mints c. RTO = 1 hour 38 mints
