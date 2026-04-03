#!/bin/bash
yum install -y httpd
systemctl start httpd
echo "Hello, Httpd!" > /var/www/html/index.html
