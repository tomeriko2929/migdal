#!/bin/bash

terraform init
terraform plan
terraform apply -auto-approve

# Configure kubectl for EKS
aws eks --region il-central-1 update-kubeconfig --name eks_cluster

kubectl apply -f deployment.yaml
kubectl apply -f argocd-app.yaml
terraform output argocd_server_url
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | grep server | awk -F'/' '{print $2}'
# Port-forward ArgoCD server (for local access)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

kubectl edit svc argocd-server -n argocd
kubectl get svc argocd-server -n argocd
# Get ArgoCD initial admin password
argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode)

# Display login information
echo "ArgoCD UI is accessible at: https://localhost:8080"
echo "Username: admin"
echo "Password: $argocd_password"

# Expose ArgoCD server using LoadBalancer (for public access)

kubectl edit svc argocd-server -n argocd
echo "Waiting for LoadBalancer IP..."
sleep 60
lb_ip=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ArgoCD UI is accessible at: https://$lb_ip"
echo "Username: admin"
echo "Password: $argocd_password"

argocd app create hello-world --repo 'https://github.com/tomeriko2929/migdal' --path 'manifests/' --dest-namespace default --dest-server https://kubernetes.default.svc --directory-recurse
argocd app sync hello-world


