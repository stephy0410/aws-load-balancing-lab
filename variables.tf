variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "academy"
}

variable "instance_name" {
  description = "Name tag prefix for the EC2 instances"
  type        = string
  default     = "sd-lab02"
}

variable "instance_type" {
  description = "EC2 instance type (Learner Lab allows nano/micro/small/medium/large)"
  type        = string
  default     = "t3.micro"
}

variable "instance_count" {
  description = "Number of static EC2 instances behind the load balancer. Lab02 is intentionally fixed at 2 (not an autoscaling group — that's lab03)."
  type        = number
  default     = 2
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair Terraform will create"
  type        = string
  default     = "sd-lab02-key"
}

variable "public_key_path" {
  description = "Path to the local SSH public key to register as the key pair"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "private_key_path" {
  description = "Path to the matching local private key, used only to build the ssh_command outputs"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GiB"
  type        = number
  default     = 8
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22). If null, your current public IP is detected and used."
  type        = string
  default     = null
}

# --- Tailscale Funnel edge (trusted HTTPS front door, outside AWS) ---
# See tailscale-edge-setup.sh for the one-time bootstrap on that machine.

variable "edge_ssh_host" {
  description = "Tailscale IP (or MagicDNS name) of the always-on machine running the Tailscale Funnel + reverse-proxy edge"
  type        = string
  default     = "100.97.18.50"
}

variable "edge_ssh_user" {
  description = "SSH user on the edge machine"
  type        = string
  default     = "steph"
}
