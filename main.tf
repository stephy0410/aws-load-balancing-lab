# Latest Amazon Linux 2023 AMI (x86_64), resolved from the public SSM parameter
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Default VPC in the region
data "aws_vpc" "default" {
  default = true
}

# Default subnets (one per AZ) inside the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Your current public IP, used to lock down SSH ingress
data "http" "myip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  ssh_cidr = var.allowed_ssh_cidr != null ? var.allowed_ssh_cidr : "${trimspace(data.http.myip.response_body)}/32"

  # Deterministic ordering so subnet/instance placement doesn't shuffle between applies
  subnet_ids = sort(data.aws_subnets.default.ids)

  # One subnet per instance, spread across AZs (wraps if instance_count > number of subnets)
  instance_subnet_ids = [for i in range(var.instance_count) : local.subnet_ids[i % length(local.subnet_ids)]]
}

# Brand-new EC2 key pair, built from a local SSH public key
resource "aws_key_pair" "lab" {
  key_name   = var.key_pair_name
  public_key = file(pathexpand(var.public_key_path))
}

# --- Security groups ---

resource "aws_security_group" "alb" {
  name        = "${var.instance_name}-alb-sg"
  description = "Internet-facing: allow HTTP+HTTPS in, all egress"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-alb-sg"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.instance_name}-sg"
  description = "Allow HTTP only from the ALB, SSH from a single CIDR, all egress"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# --- Self-signed TLS certificate, imported into ACM ---
# No public domain is available in this Learner Lab account, so this generates
# a self-signed cert and imports it into ACM for the ALB's HTTPS listener.
# Browsers/curl will flag it as untrusted (expected) but the traffic is real TLS.

resource "tls_private_key" "self" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self" {
  private_key_pem = tls_private_key.self.private_key_pem

  subject {
    common_name  = "${var.instance_name}.local"
    organization = "SD Lab02"
  }

  validity_period_hours = 8760 # 1 year
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self" {
  private_key      = tls_private_key.self.private_key_pem
  certificate_body = tls_self_signed_cert.self.cert_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.instance_name}-self-signed"
  }
}

# --- EC2 instances (2 static, fixed) ---

resource "aws_instance" "web" {
  count = var.instance_count

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.instance_subnet_ids[count.index]
  key_name               = aws_key_pair.lab.key_name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  associate_public_ip_address = true

  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  # Enforce IMDSv2
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.instance_name}-${count.index}"
  }
}

# --- Application Load Balancer, round-robin across both instances ---

resource "aws_lb" "this" {
  name               = "${var.instance_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids

  tags = {
    Name = "${var.instance_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.instance_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  # Default ALB routing algorithm is round robin
  load_balancing_algorithm_type = "round_robin"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.instance_name}-tg"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count = var.instance_count

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

# HTTP listener: redirect everything to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS listener: terminate TLS with the self-signed ACM cert, forward round robin.
# Browsers/curl will flag the cert as untrusted (curl -k) — no public domain is
# available in this Learner Lab account. Kept as a fallback/internal path; the
# trusted public entry point is the Tailscale Funnel edge machine (see the note
# further down and tailscale-edge-setup.sh).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.self.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# NOTE on the trusted-HTTPS front door: instead of a 3rd AWS resource here, the
# Tailscale Funnel edge runs on an already-on, already-owned machine outside AWS
# (see tailscale-edge-setup.sh at the repo root for the one-time bootstrap). That
# keeps 100% of this Learner Lab account's resources scoped to what's actually
# required (2 EC2 + ALB), adds zero new AWS attack surface, and costs nothing
# beyond what's already running.
#
# The ALB's DNS name changes every time it's destroyed/recreated (e.g. a
# destroy-before-class, apply-in-class cycle), so the edge machine's reverse
# proxy target would otherwise go stale. This resource re-syncs it automatically
# on every apply: it re-writes the proxy's target and restarts it over SSH
# whenever aws_lb.this.dns_name changes. Requires the edge SSH key unlocked in
# your local ssh-agent (`ssh-add ~/.ssh/id_ed25519`) before running apply.
resource "null_resource" "edge_proxy_sync" {
  triggers = {
    alb_dns_name = aws_lb.this.dns_name
  }

  connection {
    type    = "ssh"
    host    = var.edge_ssh_host
    user    = var.edge_ssh_user
    agent   = true
    timeout = "15s"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ~/edge-proxy",
      "cat > ~/edge-proxy/env <<ENVFILE\nALB_TARGET=${aws_lb.this.dns_name}\nPORT=8080\nENVFILE",
      "systemctl --user restart edge-proxy",
      "sleep 1",
      "curl -sf -o /dev/null http://127.0.0.1:8080/health && echo 'edge proxy synced OK -> ${aws_lb.this.dns_name}' || echo 'edge proxy sync FAILED'",
    ]
  }
}
