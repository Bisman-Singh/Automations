#!/bin/bash

# Read instance IDs from the file
source instance_ids.txt

# Fetch the private IP address of the backend instance
PRIVATE_IP=$(aws ec2 describe-instances --instance-ids $Backend_Instance_ID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# Check if PRIVATE_IP is empty or not
if [ -z "$PRIVATE_IP" ]; then
    echo "Failed to fetch private IP for instance $Backend_Instance_ID"
    exit 1
fi

# Prompt for database details
read -p "Enter the database name: " DATABASE_NAME
read -p "Enter the MySQL username: " MYSQL_USERNAME
read -sp "Enter the MySQL password: " MYSQL_PASSWORD
echo

# Store database details in AWS Parameter Store
aws ssm put-parameter --name "Database_Name" --value "$DATABASE_NAME" --type "String"
aws ssm put-parameter --name "Database_Username" --value "$MYSQL_USERNAME" --type "String"
aws ssm put-parameter --name "Database_Password" --value "$MYSQL_PASSWORD" --type "SecureString"

# Send the script via SSM
COMMAND_ID=$(aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceids,Values=$Backend_Instance_ID" \
    --parameters commands="[
        \"sudo apt -y update && sudo apt install -y mysql-server\",
        \"echo 'n\ny\ny\ny\ny' | sudo mysql_secure_installation\",
        \"sudo mysql -e 'CREATE DATABASE ${DATABASE_NAME};'\",
        \"sudo mysql -e \\\"CREATE USER '${MYSQL_USERNAME}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';\\\"\",
        \"sudo mysql -e \\\"GRANT ALL PRIVILEGES ON ${DATABASE_NAME}.* TO '${MYSQL_USERNAME}'@'%';\\\"\",
        \"sudo mysql -e 'FLUSH PRIVILEGES;'\",
        \"sudo sed -i 's/^bind-address.*/bind-address = ${PRIVATE_IP}/' /etc/mysql/mysql.conf.d/mysqld.cnf\",
        \"sudo systemctl restart mysql\"
    ]" \
    --query "Command.CommandId" \
    --output text)

if [ $? -eq 0 ]; then
    echo "Script sent to instance $Backend_Instance_ID with Command ID $COMMAND_ID"
else
    echo "Failed to send script to instance $Backend_Instance_ID"
    exit 1
fi

# Wait for command execution and fetch invocation result
sleep 120

STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$Backend_Instance_ID" --query 'Status' --output text)

# Check the status of the command execution
if [ "$STATUS" == "Success" ]; then
    echo "Command executed successfully on instance $Backend_Instance_ID"
else
    echo "Command failed on instance $Backend_Instance_ID with status $STATUS"
    exit 1
fi
