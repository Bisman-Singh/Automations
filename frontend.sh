#!/bin/bash

# Read instance IDs from the file
source instance_ids.txt

# Fetch the public IP address of the frontend instance
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $Frontend_Instance_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Fetch the private IP address of the backend instance
PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $Backend_Instance_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# Check if PUBLIC_IP and PRIVATE_IP are empty or not
if [ -z "$PUBLIC_IP" ] || [ -z "$PRIVATE_IP" ]; then
    echo "Failed to fetch IP addresses."
    exit 1
fi

echo "Frontend Instance ID: $Frontend_Instance_ID"
echo "Backend Instance ID: $Backend_Instance_ID"

# Fetch database details from AWS Parameter Store
DATABASE_NAME=$(aws ssm get-parameter --name "Database_Name" --query "Parameter.Value" --output text)
MYSQL_USERNAME=$(aws ssm get-parameter --name "Database_Username" --query "Parameter.Value" --output text)
MYSQL_PASSWORD=$(aws ssm get-parameter --name "Database_Password" --with-decryption --query "Parameter.Value" --output text)

# Check if database details are fetched
if [ -z "$DATABASE_NAME" ] || [ -z "$MYSQL_USERNAME" ] || [ -z "$MYSQL_PASSWORD" ]; then
    echo "Failed to fetch database details from AWS Parameter Store."
    exit 1
fi

# Send commands directly via SSM
COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=$Frontend_Instance_ID" \
    --parameters commands="[
        \"sudo apt update\",
        \"sudo apt install -y nginx\",
        \"sudo apt install -y php-fpm php-mysql php-xml php-curl php-mbstring php-zip\",
        \"cd /tmp\",
        \"wget https://wordpress.org/latest.tar.gz\",
        \"tar -xvzf latest.tar.gz\",
        \"sudo mv wordpress/* /var/www/html/\",
        \"sudo chown -R www-data:www-data /var/www/html/*\",
        \"sudo chmod -R 755 /var/www/html/\",
        \"sudo cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php\",

        \"sudo sed -i 's/database_name_here/${DATABASE_NAME}/' /var/www/html/wp-config.php\",
        \"sudo sed -i 's/username_here/${MYSQL_USERNAME}/' /var/www/html/wp-config.php\",
        \"sudo sed -i 's/password_here/${MYSQL_PASSWORD}/' /var/www/html/wp-config.php\",
        \"sudo sed -i 's/localhost/${PRIVATE_IP}/' /var/www/html/wp-config.php\"

        \"echo 'server {
            listen 80;
            server_name $PUBLIC_IP;
            root /var/www/html;
            index index.php index.html index.htm;
            
            location / {
                try_files \\\$uri \\\$uri/ /index.php?\\\$args;
            }
            
            location ~ \\\.php$ {
                include snippets/fastcgi-php.conf;
                fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
                fastcgi_param SCRIPT_FILENAME \\\$document_root\\\$fastcgi_script_name;
                include fastcgi_params;
            }
            
            location ~* \\\\.(css|js|jpg|jpeg|png|gif|ico|svg)$ {
                expires max;
                log_not_found off;
            }
            
            location = /favicon.ico {
                log_not_found off;
                access_log off;
            }
            
            location = /robots.txt {
                allow all;
                log_not_found off;
                access_log off;
            }
        }' | sudo tee /etc/nginx/sites-available/wordpress_site\",

        \"sudo ln -s /etc/nginx/sites-available/wordpress_site /etc/nginx/sites-enabled/\",
        \"sudo systemctl start nginx\",
        \"sudo systemctl enable nginx\",
        \"sudo systemctl restart nginx\"

    ]" \
    --query "Command.CommandId" \
    --output text)

# Check if command was sent successfully
if [ $? -eq 0 ]; then
    echo "Script sent to instance $Frontend_Instance_ID with Command ID $COMMAND_ID"
else
    echo "Failed to send script to instance $Frontend_Instance_ID"
    exit 1
fi

# Wait for command execution and fetch invocation result
sleep 120

STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$Frontend_Instance_ID" --query 'Status' --output text)

# Check the status of the command execution
if [ "$STATUS" == "Success" ]; then
    echo "Command executed successfully on instance $Frontend_Instance_ID"
else
    echo "Command failed on instance $Frontend_Instance_ID with status $STATUS"
    exit 1
fi
