//Setting up the provider for the terraform connection that is AWS here.

provider "aws"{
    region = "ap-south-1"
    profile = "rahul"
}

//Creating the security group for the website that will allow SSH and HTTP connection.

resource "aws_security_group" "security" {
  name        = "security_group"
  description = "Allow SSH and HTTP protocols"
  vpc_id      = "vpc-03f4e96b"

  ingress {
    description = "For_SSH_connection"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "For_HTTP_Connection"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "security_group"
  }
}

// Creating the key for the instance.

variable "key_name" {
    type = string
    default = "deploykey"
}

resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = var.key_name
  public_key = tls_private_key.key.public_key_openssh
}

resource "local_file" "key_file"{
  content = tls_private_key.key.private_key_pem
  filename = "deploykey.pem"
}

//Creating the EC2 instance

resource "aws_instance" "web" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.generated_key.key_name
  security_groups = [aws_security_group.security.name]

  connection{
    type = "ssh"
    port = 22
    user = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
    host = aws_instance.web.public_ip
  }

  provisioner "remote-exec"{
    inline = [
      "sudo yum install httpd php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "OS_terraform"
  }
}

//Creating the EBS storage for the instance

resource "aws_ebs_volume" "ebs_vol" {
  availability_zone = aws_instance.web.availability_zone
  size              = 1

  tags = {
    Name = "web_ebs"
  }
}

resource "aws_volume_attachment" "ebs_attachment"{
  device_name = "/dev/xvdf"
  volume_id = aws_ebs_volume.ebs_vol.id
  instance_id = aws_instance.web.id
  force_detach = true
}

//Mounting the EBS volume to the EC2 instance.

resource "null_resource" "ebs_mount"{
  depends_on = [
      aws_volume_attachment.ebs_attachment,
      aws_instance.web,
  ]

  connection{
    type = "ssh"
    port = 22
    user = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
    host = aws_instance.web.public_ip
  }

  provisioner "remote-exec"{
    inline = [
      "sudo mkfs.ext4 /dev/xvdf",
      "sudo mount /dev/xvdf   /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/iamrahulsil/Terraform.git  /var/www/html",
    ]
  }
}

//Creating a S3 bucket and keeping the images there.

resource "aws_s3_bucket" "silbucket"{
    bucket = "silbucket"
    acl = "public-read"

    tags = {
      Name = "silbucket"
    }
}

resource "aws_s3_bucket_object" "silbucket_object"{
  bucket = aws_s3_bucket.silbucket.bucket
  key = "image.jpg"
  source = "C:/Users/RAHUL SIL/Pictures/image.jpg"
  acl = "public-read"
}

//Creating the CloudFront Distribution

locals {
  s3_origin_id = aws_s3_bucket.silbucket.id
}

resource "aws_cloudfront_distribution" "s3_distribution" {

  depends_on = [
    aws_s3_bucket_object.silbucket_object,
  ]

  origin {
    domain_name = aws_s3_bucket.silbucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "AWS CloudFront Distribution"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["IN"]
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  retain_on_delete = true

}

//Dumping the S3 bucket image into the code

resource "null_resource" "dump"{
  depends_on = [
    aws_instance.web,
    aws_cloudfront_distribution.s3_distribution,
  ]
  
  connection{
    type = "ssh"
    port = 22
    user = "ec2-user"
    private_key = tls_private_key.key.private_key_pem
    host = aws_instance.web.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo su << EOF",
      "echo '<img src = 'http://${aws_cloudfront_distribution.s3_distribution.domain_name}/image.jpg' height = 400px width = 400px>' >> /var/www/html/index.html" ,
      "EOF",
    ]
  }

  provisioner "local-exec"{
        command = "start chrome ${aws_instance.web.public_ip}"
  }
}

//Creating EBS snapshot

resource "aws_ebs_snapshot" "snapshot"{
  volume_id = aws_ebs_volume.ebs_vol.id

  tags = {
    name = "snapshotvolume"
  }
}