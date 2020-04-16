#/usr/bin/env bash

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

# TODO: General Vault Installation happens here
#/usr/local/bin/cfn-init --verbose --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultClientAutoScalingGroup" --configsets vault_install
# TODO: If this fails bail out
# if [ $? -ne 0 ]; then /usr/local/bin/cfn-signal -e 1 --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultClientAutoScalingGroup"; echo "Vault setup failed";exit 1; fi

# Minimum Security Measures
echo 'set +o history' >> /etc/profile  # Disable command history
echo 'ulimit -c 0 > /dev/null 2>&1' > /etc/profile.d/disable-coredumps.sh  # Disable Core Dumps

# TODO: Cleanupt this as it should come from parameter
#VAULT_URL="https://releases.hashicorp.com/vault/1.4.0/vault_1.4.0_linux_amd64.zip"
VAULT_ZIP=$(echo $VAULT_URL | rev | cut -d "/" -f 1 | rev)

# Create Vault User
user_ubuntu

curl --silent --output /tmp/${VAULT_ZIP} ${VAULT_URL}
unzip -o /tmp/${VAULT_ZIP} -d /usr/local/bin/
chmod 0755 /usr/local/bin/vault
chown vault:vault /usr/local/bin/vault
mkdir -pm 0755 /etc/vault.d
mkdir -pm 0755 ${VAULT_STORAGE_PATH}
chown -R vault:vault ${VAULT_STORAGE_PATH}
chmod -R a+rwx ${VAULT_STORAGE_PATH}

cat << EOF > /lib/systemd/system/vault.service
[Unit]
Description=Vault Agent
Requires=network-online.target
After=network-online.target
[Service]
Restart=on-failure
PermissionsStartOnly=true
ExecStartPre=/sbin/setcap 'cap_ipc_lock=+ep' /usr/local/bin/vault
ExecStart=/usr/local/bin/vault server -config /etc/vault.d
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGTERM
User=vault
Group=vault
[Install]
WantedBy=multi-user.target
EOF

# TODO: Bootstrap Client
# TODO: Find a member of the Vault Cluster by describing the AutoScalingGroup
# Get list of cluster members
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
                sleep 1
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
           role = "client-role-iam"
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
# TODO: Allow this vault client-role-iam value to be customized
vault login -method=aws role=${VAULT_CLIENT_ROLE_NAME}

# Signal success if we can login as a client
/usr/local/bin/cfn-signal -e $? --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultClientAutoScalingGroup"