resource "aws_security_group" "bastion_sg" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion-sg"
    KubernetesCluster = "${var.cluster_name}"
  }
}

resource "tls_private_key" "rsa-4096-bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion_key_pair" {
  key_name   = "bastion-key-pair"
  public_key = tls_private_key.rsa-4096-bastion.public_key_openssh
}

resource "local_file" "bastion_private_key" {
  content  = tls_private_key.rsa-4096-bastion.private_key_pem
  filename = "${path.module}/bastion-key.pem"
  file_permission = "0600"
}

# --- EC2 Bastion Host ---
resource "aws_instance" "bastion" {
  ami           = "ami-00578e5c7b5d64f2a"
  instance_type = "t3.micro"
  subnet_id     = var.public_subnet_id
  key_name      = aws_key_pair.bastion_key_pair.key_name

  vpc_security_group_ids = [aws_security_group.bastion_sg.id]

  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -xe

              # Update packages
              apt-get update -y

              # Install unzip and curl
              apt-get install -y unzip curl

              # --- Install AWS CLI v2 ---
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              rm -rf awscliv2.zip aws

              # --- Install kubectl ---
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
              rm kubectl

              echo "AWS CLI version: $(aws --version)" >> /etc/motd
              echo "kubectl version: $(kubectl version --client --short)" >> /etc/motd
              echo "Bastion setup complete!" >> /etc/motd
              EOF

  tags = {
    Name = "${var.cluster_name}-bastion-host"
    KubernetesCluster = "${var.cluster_name}"
  }
}