packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.3"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "rds_domain" {
  type    = string
}

variable "db_username" {
  type    = string
}

variable "db_password" {
  type    = string
}

variable "efs_domain" {
  type    = string
}

variable "subnet_id" {
  type = string
}

source "amazon-ebs" "wordpress" {
  ami_name      = "wordpress-al2023-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  instance_type = var.instance_type
  region        = var.region
  subnet_id     = var.subnet_id
  associate_public_ip_address = true
  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }
  ssh_username = "ec2-user"
}

build {
  name = "wordpress"
  sources = [
    "source.amazon-ebs.wordpress"
  ]

  provisioner "shell" {
    environment_vars = [
      "DB_USERNAME=${var.db_username}",
      "DB_PASSWORD=${var.db_password}",
      "EFS_DOMAIN=${var.efs_domain}",
      "RDS_DOMAIN=${var.rds_domain}"
    ]
    
    inline = [
      "nslookup $RDS_DOMAIN",

      "sudo mkdir -p /var/www/html",
      "sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport $EFS_DOMAIN:/ /var/www/html",
      "sudo dnf update -y",
      "sudo dnf install -y httpd php php-mysqlnd",
      "sudo systemctl enable httpd",
      "sudo systemctl start httpd",
      "sudo usermod -a -G apache ec2-user",
      "sudo chown -R ec2-user:apache /var/www",
      "sudo chmod 2775 /var/www",
      #"sudo find /var/www -type d -print0 | xargs -0 sudo chmod 2775",
      #"sudo find /var/www -type f -print0 | xargs -0 sudo chmod 0664",
      "echo '<?php phpinfo(); ?>' | sudo tee /var/www/html/phpinfo.php",
      "curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar",
      "chmod +x wp-cli.phar",
      "sudo mv wp-cli.phar /usr/local/bin/wp",
      "cd /var/www/html",
      "sudo wp core download --allow-root",
      "echo sudo wp config create --dbname=wordpressdb --dbuser=$DB_USERNAME --dbpass=$DB_PASSWORD --dbhost=$RDS_DOMAIN --allow-root", 
      "sudo wp config create --dbname=wordpressdb --dbuser=$DB_USERNAME --dbpass=$DB_PASSWORD --dbhost=$RDS_DOMAIN --allow-root",
      "wp core install --url=example.com --title='My Site' --admin_user=admin --admin_password=password --admin_email=admin@example.com",
      "sudo chown -R apache:apache /var/www/html"
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}