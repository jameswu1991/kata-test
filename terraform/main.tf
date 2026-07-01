locals {
  name = "james"
  tags = {
    provisioner = "terraform"
  }
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.name
  cidr = "10.19.0.0/16"

  enable_nat_gateway      = true
  map_public_ip_on_launch = true
  single_nat_gateway      = true

  azs             = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.19.1.0/24", "10.19.2.0/24"]
  public_subnets = ["10.19.129.0/24", "10.19.130.0/24"]

  tags = local.tags
}

module "app" {
  source = "terraform-aws-modules/eks/aws"
  version = "21.18.0"

  name    = "${local.name}-cluster"
  kubernetes_version = "1.36"

  addons = {
    vpc-cni = {
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent          = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.public_subnets, module.vpc.private_subnets)
  endpoint_public_access = true

  security_group_additional_rules = {
    ingress-https = {
      from_port                = 443
      to_port                  = 443
      protocol                 = "tcp"
      type                     = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Allow all traffic between nodes and pods"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      type        = "ingress"
      self       = true
    }
    egress_self_all = {
      description = "Allow all traffic between nodes and pods"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      type        = "egress"
      self       = true
    }
  }

  tags = local.tags
}

# --- Dedicated IAM Resources for the Standalone EC2 Instance ---

resource "aws_iam_role" "standalone_node_role" {
  name = "${local.name}-standalone-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.standalone_node_role.name
  policy_arn = each.value
}
resource "aws_iam_instance_profile" "standalone_profile" {
  name = "${local.name}-standalone-instance-profile"
  role = aws_iam_role.standalone_node_role.name
  tags = local.tags
}

# --- Node Bootstrapping Configuration ---

data "cloudinit_config" "node_userdata" {
  gzip          = false
  base64_encode = false

  # Part 1: Install and configure Kata Containers
  part {
    content_type = "text/x-shellscript"
    content      = <<-EOT
      #!/bin/bash
      set -xe

      # 1. Verify nested virtualization (KVM) is functional
      if [ ! -e /dev/kvm ]; then
        echo "KVM is not available. Ensure nested virtualization is enabled."
        exit 1
      fi

      # 2. Download and install Kata
      KATA_VERSION="3.32.0" # Use a stable 3.x release
      curl -fL -o /tmp/kata-static.tar.zst "https://github.com/kata-containers/kata-containers/releases/download/$KATA_VERSION/kata-static-$KATA_VERSION-amd64.tar.zst"
      zstd -d /tmp/kata-static.tar.zst --stdout | tar -x -C /

      # Create symlinks for convenience
      ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime
      ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
      ln -sf /opt/kata/bin/kata-monitor /usr/local/bin/kata-monitor

      # 3. Prepare the devmapper thin pool
      mkdir -p /var/lib/containerd/devmapper
      truncate -s 10G /var/lib/containerd/devmapper/data
      truncate -s 1G /var/lib/containerd/devmapper/metadata
      DATA_DEV=$(losetup --find --show /var/lib/containerd/devmapper/data)
      META_DEV=$(losetup --find --show /var/lib/containerd/devmapper/metadata)
      dmsetup create containerd-pool --table "0 16777216 thin-pool $META_DEV $DATA_DEV 128 32768"

      # 4. Configure containerd to recognize the Kata runtime class
      cat <<EOF >> /etc/containerd/config.toml
      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata]
        runtime_type = "io.containerd.kata.v2"
        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata.options]
          ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-clh.toml"

      [plugins."io.containerd.grpc.v1.cri".containerd]
        discard_unpacked_layers = false # Keep unpacked layers for devmapper snapshotter
        disable_snapshot_annotations = false # cri can pass snapshotter config to image puller

      [plugins."io.containerd.snapshotter.v1.devmapper"]
        pool_name = "containerd-pool"
        root_path = "/var/lib/containerd/devmapper"
        base_image_size = "4GB"

      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata-fc]
        runtime_type = "io.containerd.kata.v2"
        snapshotter = "devmapper"
        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata-fc.options]
          ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"
      EOF

      # Restart containerd to pick up the new configuration snippet
      systemctl restart containerd
    EOT
  }

  # # Part 2: Standard EKS Node Bootstrap Configuration
  part {
    content_type = "application/node.eks.aws"
    content = jsonencode({
      apiVersion = "node.eks.aws/v1alpha1"
      kind       = "NodeConfig"
      spec = {
        cluster = {
          name                 = module.app.cluster_name
          apiServerEndpoint    = module.app.cluster_endpoint
          certificateAuthority = module.app.cluster_certificate_authority_data
          cidr                 = "172.20.0.0/16"
        }
      }
    })
  }
}

resource "aws_eks_access_entry" "standalone_node" {
  cluster_name  = module.app.cluster_name
  principal_arn = aws_iam_role.standalone_node_role.arn
  type          = "EC2_LINUX"
}

resource "aws_instance" "standalone_worker" {
  ami           = "ami-07a47a1de2e8a8904" 
  instance_type = "c8i.large"

  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [module.app.node_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.standalone_profile.name

  user_data = data.cloudinit_config.node_userdata.rendered

  cpu_options {
    nested_virtualization = "enabled"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(local.tags, {
    Name                                          = "standalone-eks-node"
    "kubernetes.io/cluster/${local.name}-cluster" = "owned"
  })

  depends_on = [aws_eks_access_entry.standalone_node]
}