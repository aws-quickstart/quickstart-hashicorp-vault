#!/bin/bash

SLEEP=30
SPLAY=$(shuf -i 1-10 -n 1)
LEADER_ELECTED=0
LEADER_ID="" # Get from SSM Parameter
INSTANCE_ID="" # Get from instance metadata
I_AM_LEADER=0

# Include common functions
. ./functions.sh

# Get instance from MDSv2
INSTANCE_ID=$(get_mdsv2 "instance-id")
echo INSTANCE_ID: ${INSTANCE_ID}
VAULT_STORAGE_PATH="/vault/$INSTANCE_ID"

echo 'set +o history' >> /etc/profile  # Disable command history
echo 'ulimit -c 0 > /dev/null 2>&1' > /etc/profile.d/disable-coredumps.sh  # Disable Core Dumps

VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
VAULT_ZIP=$(echo $VAULT_URL | rev | cut -d "/" -f 1 | rev)

# Create Vault User
user_ubuntu

# Install vault
install_vault

# Create systemd service file for Vault
vault_systemctl_file

# Bootstrap Client
# Get list of Hashicorp Vault server cluster members
instance_id_array=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${ASG_NAME}" --region "${AWS_REGION}" | jq -r '.AutoScalingGroups[].Instances[] | select(.LifecycleState == "InService").InstanceId')
echo instance_id_array $instance_id_array

# Get ips from id's
instance_ip_array=()
for i in ${instance_id_array[@]}
do
        echo instance ${i}
        ip_addr=$(aws ec2 describe-instances --instance-id "$i" --region "${AWS_REGION}" | jq -r ".Reservations[].Instances[].PrivateIpAddress")
        echo ip_addr ${ip_addr}
        instance_ip_array+=( ${ip_addr} )
done
echo instance_ip_array $instance_ip_array

# Find one that answers on 8200
VAULT_SERVER_ADDR=""
while true
do
        for i in ${instance_ip_array[@]}
        do
                echo instance ${i}
                curl -fs -o /dev/null $i:8200/v1/sys/init
                if [ $? ] 
                then
                        setting VAULT_SERVER_ADDR to $i
                        VAULT_SERVER_ADDR="$i"
                        break
                fi
                sleep 2
                echo "$i Vault Cluster member not ready trying next server"
        done
        if [ "${VAULT_SERVER_ADDR}X" != "X" ]
        then
          break
        fi
done

# Setup environment pointing to the VAULT cluster
# Disable Swap: disable_mlock = true
cat << EOF | sudo tee /etc/vault.d/vault.hcl
storage "file" {
  path = "/opt/vault"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
disable_mlock = true
ui=true
EOF

sudo chmod 0664 /lib/systemd/system/vault.service
sudo systemctl daemon-reload
sudo chown -R vault:vault /etc/vault.d
sudo chmod -R 0644 /etc/vault.d/*

# Setup environment for Vault to use Vault Cluster address 
sudo tee -a /etc/environment <<EOF
export VAULT_ADDR="http://${VAULT_SERVER_ADDR}:8200"
export VAULT_SKIP_VERIFY=true
EOF

source /etc/environment

sudo systemctl enable vault

# Configure Vault HCL for using AWS Authentication mechanism
#### For Vault Agent Auth #####
cat << EOF > /home/ubuntu/vault-agent-wrapped.hcl
exit_after_auth = true
pid_file = "./pidfile"
auto_auth {
   method "aws" {
       mount_path = "auth/aws"
       config = {
           type = "iam"
           role = "${VAULT_CLIENT_ROLE_NAME}"
       }
   }
   sink "file" {
       wrap_ttl = "5m"
       config = {
           path = "/home/ubuntu/vault-token-via-agent"
       }
   }
}
vault {
   address = "http://${VAULT_SERVER_ADDR}:8200"
}
EOF

sudo chmod 0775 /home/ubuntu/vault-agent-wrapped.hcl

# Test Vault by Adding and retrieving a secret using our Instance Profile IAM Role using AWS Vault Auth mechanism
# Login to vault using Client Role
vault login -method=aws role=${VAULT_CLIENT_ROLE_NAME}

# Signal success if we can login as a client
/usr/local/bin/cfn-signal -e $? --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultClientAutoScalingGroup"