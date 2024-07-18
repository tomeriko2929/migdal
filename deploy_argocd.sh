#!/bin/bash

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Plan Terraform Deployment
echo "Planning Terraform deployment..."
terraform plan

# Apply Terraform Deployment with auto-approve
echo "Applying Terraform deployment..."
terraform apply -auto-approve

# Configure kubectl for EKS
EKS_CLUSTER_NAME="eks_cluster"
REGION="il-central-1"
echo "Configuring kubectl for EKS..."
aws eks --region $REGION update-kubeconfig --name $EKS_CLUSTER_NAME

# Verify if kubectl is configured correctly
if kubectl get nodes; then
    echo "kubectl is configured correctly."
else
    echo "Failed to configure kubectl. Please check your EKS cluster endpoint and network connectivity."
    exit 1
fi

# Apply Kubernetes Deployments
echo "Applying Kubernetes deployments..."
kubectl apply -f manifests/deployment.yaml
kubectl apply -f manifests/argocd-app.yaml

# Get ArgoCD Server URL from Terraform Outputs
argocd_url=$(terraform output argocd_server_url)
echo "ArgoCD server URL: $argocd_url"

# Retrieve ArgoCD Server Pod Name
echo "Retrieving ArgoCD server pod name..."
argocd_server_pod=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | grep server | awk -F'/' '{print $2}')
echo "ArgoCD server pod name: $argocd_server_pod"

# Port-forward ArgoCD server for local access
echo "Port-forwarding ArgoCD server for local access..."
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Edit ArgoCD Server Service
#echo "Editing ArgoCD server service..."
#kubectl edit svc argocd-server -n argocd

# Get ArgoCD Server Service details
echo "Fetching ArgoCD server service details..."
kubectl get svc argocd-server -n argocd

# Get ArgoCD Initial Admin Password
echo "Retrieving ArgoCD initial admin password..."
argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode)
echo "ArgoCD initial admin password retrieved."

# Display Login Information
echo "ArgoCD UI is accessible at: https://localhost:8080"
echo "Username: admin"
echo "Password: $argocd_password"

# Expose ArgoCD Server using LoadBalancer for Public Access
echo "Exposing ArgoCD server using LoadBalancer..."
#kubectl edit svc argocd-server -n argocd
echo "Waiting for LoadBalancer IP..."
sleep 60
lb_ip=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ArgoCD UI is accessible at: https://$lb_ip"
echo "Username: admin"
echo "Password: $argocd_password"

# Create and Sync ArgoCD Application
echo "Creating and syncing ArgoCD application..."
argocd app create hello-world --repo 'https://github.com/tomeriko2929/migdal' --path 'manifests/' --dest-namespace default --dest-server https://kubernetes.default.svc --directory-recurse
argocd app sync hello-world
