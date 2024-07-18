# Define the AWS provider
provider "aws" {
  region = "il-central-1"
}

# Define the Kubernetes provider
provider "kubernetes" {
  config_path = "~/.kube/config"
}

# Define the Helm provider
provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Create public subnets
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  map_public_ip_on_launch = true
  availability_zone       = element(["il-central-1a", "il-central-1b"], count.index)
}

# Create an Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Create a public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# Associate the route table with the subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

# Create a Network ACL
resource "aws_network_acl" "public_acl" {
  vpc_id = aws_vpc.main.id
}

# Associate the Network ACL with the subnets
resource "aws_network_acl_association" "public_acl_association" {
  count          = 2
  subnet_id      = element(aws_subnet.public.*.id, count.index)
  network_acl_id = aws_network_acl.public_acl.id
}

# Create IAM role for EKS cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks_cluster_role"

  assume_role_policy = jsonencode({
    Version: "2012-10-17",
    Statement: [{
      Action: "sts:AssumeRole",
      Effect: "Allow",
      Principal: {
        Service: "eks.amazonaws.com"
      }
    }]
  })
}

# Attach policies to the IAM role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_controller_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Create the EKS cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks_cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = aws_subnet.public[*].id
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
    aws_iam_role_policy_attachment.eks_vpc_controller_policy
  ]
}

# Wait for the EKS cluster endpoint to be resolvable
resource "null_resource" "wait_for_eks" {
  provisioner "local-exec" {
    command = <<EOT
COUNT=0
MAX_RETRIES=30
SLEEP_INTERVAL=10
while ! nslookup ${aws_eks_cluster.eks_cluster.endpoint} && [ $COUNT -lt $MAX_RETRIES ]; do
  echo "Waiting for EKS endpoint to be resolvable..."
  COUNT=$((COUNT + 1))
  sleep $SLEEP_INTERVAL
done
if [ $COUNT -eq $MAX_RETRIES ]; then
  echo "EKS endpoint could not be resolved after $MAX_RETRIES attempts."
  exit 1
fi
EOT
  }
  depends_on = [aws_eks_cluster.eks_cluster]
}

# Configure kubectl for EKS
resource "null_resource" "configure_kubectl" {
  provisioner "local-exec" {
    command = "aws eks --region il-central-1 update-kubeconfig --name eks_cluster"
  }
  depends_on = [null_resource.wait_for_eks]
}

# Wait until the EKS cluster is fully available
resource "null_resource" "wait_for_eks_cluster" {
  provisioner "local-exec" {
    command = <<EOT
while true; do
  if kubectl get nodes --kubeconfig ~/.kube/config > /dev/null 2>&1; then
    echo "EKS cluster is ready"
    break
  else
    echo "Waiting for EKS cluster to be ready..."
    kubectl cluster-info
    sleep 30
  fi
done
EOT
  }
  depends_on = [
    null_resource.configure_kubectl
  ]
}

# Create an IAM role for EKS node group
resource "aws_iam_role" "eks_node_group_role" {
  name = "eks_node_group_role"

  assume_role_policy = jsonencode({
    Version: "2012-10-17",
    Statement: [{
      Action: "sts:AssumeRole",
      Effect: "Allow",
      Principal: {
        Service: "ec2.amazonaws.com"
      }
    }]
  })
}

# Attach policies to the IAM role
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_readonly_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create a security group for the EKS node group
resource "aws_security_group" "eks_node_group" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create an EKS node group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name  = aws_eks_cluster.eks_cluster.name
  node_role_arn = aws_iam_role.eks_node_group_role.arn
  subnet_ids    = aws_subnet.public[*].id

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.ecr_readonly_policy
  ]
}

# Create a security group for the ALB
resource "aws_security_group" "lb" {
  name        = "lb_sg"
  description = "Allow all HTTP and HTTPS traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create an Application Load Balancer (ALB)
resource "aws_lb" "example" {
  name               = "example-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb.id]
  subnets            = aws_subnet.public[*].id
}

# Create a listener for the ALB
resource "aws_lb_listener" "frontend" {
  load_balancer_arn = aws_lb.example.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.example.arn
  }
}

# Create a target group for the ALB
resource "aws_lb_target_group" "example" {
  name     = "example-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
    port = "traffic-port"
  }
}

# Create a namespace for ArgoCD in Kubernetes
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
  depends_on = [null_resource.wait_for_eks_cluster]
}

# Install ArgoCD CRDs
resource "null_resource" "install_argocd_crds" {
  provisioner "local-exec" {
    command = "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds.yaml"
  }
  depends_on = [kubernetes_namespace.argocd]
}

# Install ArgoCD using a Helm chart
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  depends_on = [null_resource.install_argocd_crds]
}

# Check if the ArgoCD service already exists
data "kubernetes_service" "existing_argocd" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
  depends_on = [null_resource.wait_for_eks_cluster]
}

# Create the ArgoCD service if it does not exist
resource "kubernetes_service" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }
  spec {
    selector = {
      app = "argocd-server"
    }
    port {
      port        = 80
      target_port = 8080
    }
    type = "LoadBalancer"
  }
  depends_on = [helm_release.argocd]
  lifecycle {
    ignore_changes = [
      metadata,
      spec,
    ]
    prevent_destroy = true
  }
}

# Local value to extract the load balancer hostname
locals {
  argocd_server_status = try(kubernetes_service.argocd.status[0], data.kubernetes_service.existing_argocd.status[0])
}

output "argocd_server_url" {
  value = "http://${local.argocd_server_status.load_balancer[0].ingress[0].hostname}"
}

# Ensure the security group rule for the ALB allowing inbound traffic on port 80
resource "null_resource" "alb_sg_rule_http" {
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-security-groups --group-ids ${aws_security_group.lb.id} --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\` && ToPort==\`80\` && IpProtocol==\`tcp\` && IpRanges[0].CidrIp==\`0.0.0.0/0\`]" --output text | grep -q .; then
  aws ec2 authorize-security-group-ingress --group-id ${aws_security_group.lb.id} --protocol tcp --port 80 --cidr 0.0.0.0/0
fi
EOT
  }
  depends_on = [aws_security_group.lb]
}

# Ensure the Network ACL rule to allow inbound traffic on port 80
resource "null_resource" "nacl_rule_http_inbound" {
  count = 2
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.public_acl.id} --query "NetworkAcls[0].Entries[?RuleNumber==\`${100 + count.index}\`]" --output text | grep -q .; then
  aws ec2 create-network-acl-entry --network-acl-id ${aws_network_acl.public_acl.id} --rule-number ${100 + count.index} --protocol tcp --port-range From=80,To=80 --egress false --cidr-block 0.0.0.0/0 --rule-action allow
fi
EOT
  }
  depends_on = [aws_network_acl.public_acl]
}

# Ensure the Network ACL rule to allow outbound traffic on port 80
resource "null_resource" "nacl_rule_http_outbound" {
  count = 2
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.public_acl.id} --query "NetworkAcls[0].Entries[?RuleNumber==\`${200 + count.index}\`]" --output text | grep -q .; then
  aws ec2 create-network-acl-entry --network-acl-id ${aws_network_acl.public_acl.id} --rule-number ${200 + count.index} --protocol tcp --port-range From=80,To=80 --egress true --cidr-block 0.0.0.0/0 --rule-action allow
fi
EOT
  }
  depends_on = [aws_network_acl.public_acl]
}

# Define output for the ALB DNS name
output "alb_dns_name" {
  value = aws_lb.example.dns_name
}

# Ensure the security group rule for the ALB allowing inbound traffic on port 443
resource "null_resource" "alb_sg_rule_https" {
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-security-groups --group-ids ${aws_security_group.lb.id} --query "SecurityGroups[0].IpPermissions[?FromPort==\`443\` && ToPort==\`443\` && IpProtocol==\`tcp\` && IpRanges[0].CidrIp==\`0.0.0.0/0\`]" --output text | grep -q .; then
  aws ec2 authorize-security-group-ingress --group-id ${aws_security_group.lb.id} --protocol tcp --port 443 --cidr 0.0.0.0/0
fi
EOT
  }
  depends_on = [aws_security_group.lb]
}

# Ensure the Network ACL rule to allow inbound traffic on port 443
resource "null_resource" "nacl_rule_https_inbound" {
  count = 2
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.public_acl.id} --query "NetworkAcls[0].Entries[?RuleNumber==\`${300 + count.index}\`]" --output text | grep -q .; then
  aws ec2 create-network-acl-entry --network-acl-id ${aws_network_acl.public_acl.id} --rule-number ${300 + count.index} --protocol tcp --port-range From=443,To=443 --egress false --cidr-block 0.0.0.0/0 --rule-action allow
fi
EOT
  }
  depends_on = [aws_network_acl.public_acl]
}

# Ensure the Network ACL rule to allow outbound traffic on port 443
resource "null_resource" "nacl_rule_https_outbound" {
  count = 2
  provisioner "local-exec" {
    command = <<EOT
if ! aws ec2 describe-network-acls --network-acl-ids ${aws_network_acl.public_acl.id} --query "NetworkAcls[0].Entries[?RuleNumber==\`${400 + count.index}\`]" --output text | grep -q .; then
  aws ec2 create-network-acl-entry --network-acl-id ${aws_network_acl.public_acl.id} --rule-number ${400 + count.index} --protocol tcp --port-range From=443,To=443 --egress true --cidr-block 0.0.0.0/0 --rule-action allow
fi
EOT
  }
  depends_on = [aws_network_acl.public_acl]
}
