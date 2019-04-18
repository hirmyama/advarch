#!/bin/bash
yum update -y
yum install -y ruby wget
wget https://aws-codedeploy-us-west-2.s3.amazonaws.com/latest/install
chmod +x ./install
./install auto

yum install -y httpd
systemctl enable --now httpd.service
