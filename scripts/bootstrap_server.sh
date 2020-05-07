#/usr/bin/env bash -e

SLEEP=20
SPLAY=$(shuf -i 1-10 -n 1)
LEADER_ELECTED="" # Get from SSM Parameter
LEADER_ID="" # Get from SSM Parameter
INSTANCE_ID="" # Get from instance metadata

# Included functions shared for clients/servers
. ./functions.sh

# Get instance id from AWS IMDSv2
INSTANCE_ID=$(get_mdsv2 "instance-id")
echo INSTANCE_ID: ${INSTANCE_ID}

echo 'set +o history' >> /etc/profile  # Disable command history
echo 'ulimit -c 0 > /dev/null 2>&1' > /etc/profile.d/disable-coredumps.sh  # Disable Core Dumps

# Git local IP Address from AWS IMDSv2
PRIVATE_IP=$(get_mdsv2 "local-ipv4")
PUBLIC_IP=$(get_mdsv2 "local-ipv4")

# Create Vault User
user_ubuntu

# Adjusting ulimits for vault user
cat << EOF > /etc/security/limits.conf
vault          soft    nofile          65536
vault          hard    nofile          65536
vault          soft    nproc           65536
vault          hard    nproc           65536
EOF

VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
VAULT_ZIP=$(echo $VAULT_URL | rev | cut -d "/" -f 1 | rev)

VAULT_STORAGE_PATH="/vault/$INSTANCE_ID"
VAULT_LOG_PATH="/vault/log"

# Install Vault
install_vault

# Allow local firewall Access (Required to open local FW access for Vault Server on CIS images) 
# Test if we are on CIS or ubuntu
iptables -I INPUT 6 -p tcp -m tcp --dport 8200 -j ACCEPT 2>&1 > /dev/null || echo Ubuntu
iptables -I INPUT 7 -p tcp -m tcp --dport 8201 -j ACCEPT 2>&1 > /dev/null || echo Ubuntu

# Create systemd service file for Vault
vault_systemctl_file

# install awslogs agent
cloud_watch_logs

# Find AWS AutoScaling Group ID from this instance
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --instance-ids "$INSTANCE_ID" --region "${AWS_REGION}" | jq -r ".AutoScalingInstances[].AutoScalingGroupName")
echo ASG_NAME $ASG_NAME

# Find all members of our AWS AutoScaling Group
instance_id_array=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${ASG_NAME}" --region "${AWS_REGION}" | jq -r '.AutoScalingGroups[].Instances[] | select(.LifecycleState == "InService").InstanceId')
echo instance_id_array $instance_id_array

# Find all IP Addresses for instances in our AWS AutoScaling Group
instance_ip_array=()
for i in ${instance_id_array[@]}
do
        echo instance ${i}
        ip_addr=$(aws ec2 describe-instances --instance-id "$i" --region "${AWS_REGION}" | jq -r ".Reservations[].Instances[].PrivateIpAddress")
        echo ip_addr ${ip_addr}
        instance_ip_array+=( ${ip_addr} )
done
echo instance_ip_array $instance_ip_array

# Disable Swap: disable_mlock = true
cat << EOF > /etc/vault.d/vault.hcl
storage "raft" {
  path    = "${VAULT_STORAGE_PATH}"
  node_id = "${INSTANCE_ID}"
$(
        for i in ${instance_ip_array[@]}; do
                echo "  retry_join {
                        leader_api_addr = \"http://$i:8200\"
                }"
done
)
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  cluster_address     = "0.0.0.0:8201"
  tls_disable = 1
}

seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${KMS_KEY}"

}

api_addr = "http://${PRIVATE_IP}:8200"
cluster_addr = "http://${PRIVATE_IP}:8201"
disable_mlock = true
ui = true
EOF

chmod 0664 /lib/systemd/system/vault.service
systemctl daemon-reload
chown -R vault:vault /etc/vault.d
chmod -R 0644 /etc/vault.d/*

cat << EOF > /etc/environment
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
EOF

. /etc/environment

# So each node doesn't start same time spread out the starts
echo Sleeping for a splay time: $SPLAY
sleep ${SPLAY}

# Check for leader
while true
do
        echo Invoking leader election:
        # invoke ElectLeader Lambda Asynchronously
        aws lambda invoke --region $AWS_REGION --function-name ${LEADER_ELECTION_LAMBDA} --invocation-type Event --payload "{\"instance_id\": \"$INSTANCE_ID\" }" leader_election.out

        echo -n Sleeping for $SLEEP seconds to allow for election:
        sleep $SLEEP
        echo done

        echo -n Checking if leader election has happened:
        LEADER_ELECTED=$(get_ssm_param $LEADER_ELECTED_SSM_PARAMETER)
        echo $LEADER_ELECTED
        if [ "$LEADER_ELECTED" = "True" ]
        then
                echo Leader has been elected continue bootstrapping
                break
        fi
        echo "No leader elected trying again..."
done

echo -n Who was elected leader:
LEADER_ID=$(get_ssm_param "$LEADER_ID_SSM_PARAMETER")
echo $LEADER_ID

# If I am the leader do the leader bootstrap stuff
if [ "$LEADER_ID" = "$INSTANCE_ID" ]
then
        # Do leader stuff
        echo "I was elected leader doing leader stuff"
        sleep $SLEEP
        echo done

        sudo systemctl enable vault
        sudo systemctl start vault

        until curl -fs -o /dev/null localhost:8200/v1/sys/init; do
                echo "Waiting for Vault to start..."
                sleep 1
        done

        init=$(curl -fs localhost:8200/v1/sys/init | jq -r .initialized)

        if [ "$init" == "false" ]; then
                echo "Initializing Vault"
                install -d -m 0755 -o vault -g vault /etc/vault
                SECRET_VALUE=$(vault operator init -recovery-shares=${VAULT_NUMBER_OF_KEYS} -recovery-threshold=${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL})
                echo "storing vault init values in secrets manager"
                aws secretsmanager put-secret-value --region ${AWS_REGION} --secret-id ${VAULT_SECRET} --secret-string "${SECRET_VALUE}" 
        else
                echo "Vault is already initialized"
        fi

        sealed=$(curl -fs localhost:8200/v1/sys/seal-status | jq -r .sealed)

        VAULT_SECRET_VALUE=$(get_secret ${VAULT_SECRET})
        
        root_token=$(echo ${VAULT_SECRET_VALUE} | awk '{ if (match($0,/Initial Root Token: (.*)/,m)) print m[1] }' | cut -d " " -f 1) 
        # Handle a variable number of unseal keys
        for UNSEAL_KEY_INDEX in {1..${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL}}
        do
                unseal_key+=($(echo ${VAULT_SECRET_VALUE} | awk '{ if (match($0,/Recovery Key '${UNSEAL_KEY_INDEX}': (.*)/,m)) print m[1] }'| cut -d " " -f 1))
        done
        
        # Should Auto unseal using KMS but this is for demonstration for manual unseal
        if [ "$sealed" == "true" ]; then
                echo "Unsealing Vault"
                # Handle variable number of unseal keys
                for UNSEAL_KEY_INDEX in {1..${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL}}
                do
                        vault operator unseal $unseal_key[${UNSEAL_KEY_INDEX}] 
                done
        else
                echo "Vault is already unsealed"
        fi

        sleep ${SLEEP} 

        # Login to Vault
        vault login token=$root_token 2>&1 > /dev/null  # Hide this output from the console

        # Enable Vault audit logs
        vault audit enable file file_path=${VAULT_LOG_PATH}/vault-audit.log

        # Enable AWS Auth
        vault auth enable aws

        # Create client-role-iam role
        vault write auth/aws/role/${VAULT_CLIENT_ROLE_NAME} auth_type=iam \
                bound_iam_principal_arn=${VAULT_CLIENT_ROLE} \
                policies=vaultclient \
                ttl=24h


        # Kubernetes auth adding (https://www.vaultproject.io/docs/auth/kubernetes.html)
        if [ "${VAULT_KUBERNETES_ENABLE}" = "true" ]
        then
                vault auth enable kubernetes

                get_kubernetes_ca
                
                vault write auth/kubernetes/config \
                        token_reviewer_jwt="reviewer_service_account_jwt" \
                        kubernetes_host=${VAULT_KUBERNETES_HOST_URL} \
                        kubernetes_ca_cert=@/etc/vault.d/ca.crt
                
                vault write auth/kubernetes/role/${VAULT_KUBERNETES_ROLE_NAME} \
                        bound_service_account_names=vault-auth \
                        bound_service_account_namespaces=default \
                        policies=default \
                        ttl=1h
        fi

        # Take a raft snapshot
        vault operator raft snapshot save postinstall.snapshot

        # Bailout
        exit 0
fi

# Only Vault cluster members are here so 
sleep ${SLEEP}
echo "Checking if I am able to bootstrap further: "
# Loop until I show up in CLUSTER_MEMBER SSM Parameter
while true
do
        echo "Invoking Cluster Bootstrap Lambda"
        # Invoke Bootstrap Lambda
        aws lambda invoke --region $AWS_REGION --function-name ${CLUSTER_BOOTSTRAP_LAMBDA}  --invocation-type Event --payload "{ \"instance_id\": \"$INSTANCE_ID\" }" cluster_bootstrap.out
        echo "Sleeping $SLEEP seconds to allow Lambda time to execute: "
        sleep $SLEEP
        echo done

        echo -n "Checking the cluster members to see if I am allowed to bootstrap: "
        # Check if my instance id exists in the list
        CLUSTER_MEMBERS=$(get_ssm_param $VAULT_CLUSTER_MEMBERS_SSM_PARAMETER)
        echo $CLUSTER_MENBERS
        echo $CLUSTER_MEMBERS | grep "$INSTANCE_ID"
        I_CAN_BOOTSTRAP=$?  # Check exit status of grep command
        echo $(get_ssm_param $VAULT_CLUSTER_MEMBERS_SSM_PARAMETER)
        if [ $I_CAN_BOOTSTRAP -eq 0 ]
        then
                # TODO: We may need to rather interrogate Vault for this bit to make sure the Lambda publishes only nodes added to vault(and ourselves) 2 nodes coming up at the same time race condition
                UNHEALTHY_COUNT=0
                # Check each node in the cluster is okay (Except myself)
                for i in $(echo $CLUSTER_MEMBERS|tr "," "\n"); do
                        if [ $i != $INSTANCE_ID ]  # Don't check ourselves since we have not joined
                        then
                                NODE_IP=$(aws ec2 describe-instances --instance-id "$i" --region "${AWS_REGION}" | jq -r ".Reservations[].Instances[].PrivateIpAddress")
                                status=$(curl -s "http://${NODE_IP}:8200/v1/sys/init" | jq -r .initialized)
                                # increment counter if a node is initialized
                                if [ "$status" != true ]; then
                                        ((++UNHEALTHY_COUNT))
                                fi
                        fi
                done

                #if [ UNHEALTHY_COUNT -eq 0 ]
                #then
                        echo "I am a cluster member now and all nodes healthy start vault"
                        break
                #fi
        fi
        echo "I am NOT a cluster member or other nodes unhealthy trying again..."
done

# Enable and start vault
sudo systemctl enable vault
sudo systemctl start vault

# Don't signal until we report that we have started
until curl -fs -o /dev/null localhost:8200/v1/sys/init; do
        echo "Waiting for Vault to start..."
        sleep 2
done

# Vault has started signal success to Cloudformation
exit 0
