data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Latest Amazon Linux 2023 (arm64) AMI ID. A public parameter, not a secret
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  ssm_parameter_arn_prefix = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter"
}

# ---------- Security Group ----------

# No inbound at all (not even SSH). Outbound is unrestricted
resource "aws_security_group" "exit_node" {
  name        = "${var.name}-exit-node"
  description = "Tailscale exit node: no inbound, all outbound"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-exit-node"
  }
}

# ---------- IAM (instance role) ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exit_node" {
  name               = "${var.name}-exit-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# For SSM Session Manager
resource "aws_iam_role_policy_attachment" "exit_node_ssm_core" {
  role       = aws_iam_role.exit_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "exit_node_authkey" {
  statement {
    sid       = "ReadTailscaleAuthKey"
    actions   = ["ssm:GetParameter"]
    resources = ["${local.ssm_parameter_arn_prefix}${var.tailscale_authkey_parameter_name}"]
  }
}

resource "aws_iam_role_policy" "exit_node_authkey" {
  name   = "read-tailscale-authkey"
  role   = aws_iam_role.exit_node.id
  policy = data.aws_iam_policy_document.exit_node_authkey.json
}

resource "aws_iam_instance_profile" "exit_node" {
  name = "${var.name}-exit-node"
  role = aws_iam_role.exit_node.name
}

# ---------- EC2 ----------

resource "aws_instance" "exit_node" {
  ami           = nonsensitive(data.aws_ssm_parameter.al2023_arm64.value)
  instance_type = "t4g.nano"

  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.exit_node.id]
  associate_public_ip_address = true # No EIP, so no IPv4 charge while stopped
  iam_instance_profile        = aws_iam_instance_profile.exit_node.name

  # A shutdown from inside the OS stops the instance instead of terminating it
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    auto_stop_minutes      = var.auto_stop_minutes
    aws_region             = var.aws_region
    authkey_parameter_name = var.tailscale_authkey_parameter_name
    tailscale_tag          = var.tailscale_tag
    tailscale_hostname     = var.tailscale_hostname
  })

  tags = {
    Name = "${var.name}-exit-node"
  }

  lifecycle {
    # Replacing the instance wipes the Tailscale state and requires a new auth key,
    # so AMI updates and user-data edits do not trigger it (use -replace to apply them).
    # A stopped instance has no public IP and reads back associate_public_ip_address = false,
    # which would otherwise force a replacement on every plan made while it is stopped
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }

  depends_on = [aws_route_table_association.public]
}
