#!/bin/bash
yum install -y nginx
systemctl start nginx
echo "Hello, Nginx!" > /usr/share/nginx/html/index.html
