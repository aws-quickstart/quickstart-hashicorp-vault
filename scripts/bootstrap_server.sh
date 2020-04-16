#/usr/bin/env bash

SLEEP=30
SPLAY=$(shuf -i 1-10 -n 1)
LEADER_ELECTED=0
LEADER_ID="" # Get from SSM Parameter
INSTANCE_ID="" # Get from instance metadata
I_AM_LEADER=0

# TODO: as these should come from common functions file
get_ssm_param () {
        local value=$(aws ssm get-parameter --region ${AWS_REGION} --name "$1"| jq -r ".Parameter|.Value" )
        echo $value
}

user_ubuntu () {
  # UBUNTU user setup
  if ! getent group ${GROUP} >/dev/null
  then
    sudo addgroup --system ${GROUP} >/dev/null
  fi

  if ! getent passwd ${USER} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup ${GROUP} \
      --home ${HOME} \
      --no-create-home \
      --gecos "${COMMENT}" \
      --shell /bin/false \
      ${USER}  >/dev/null
  fi
}

# TODO: test that included functions work
. ./functions.sh

# TODO: turn into MDSv2 function and include in functions.sh
# MDSv2
INSTANCE_ID=$(get_mdsv2 "instance-id")
echo INSTANCE_ID: ${INSTANCE_ID}

# TODO: General Setup happens here
#/usr/local/bin/cfn-init --verbose --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultServerAutoScalingGroup" --configsets vault_install
# TODO: If this fails bail out
# if [ $? -ne 0 ]; then exit; fi

# Minimum Security Measures
echo 'set +o history' >> /etc/profile  # Disable command history
echo 'ulimit -c 0 > /dev/null 2>&1' > /etc/profile.d/disable-coredumps.sh  # Disable Core Dumps

# TODO: MDSv2 these requests so we can lock instances down further
PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)

# Create Vault User
user_ubuntu

# Adjusting ulimits for vault user
cat << EOF > /etc/security/limits.conf
vault          soft    nofile          64000
vault          hard    nofile          64000
vault          soft    nproc           64000
vault          hard    nproc           64000
EOF

VAULT_ZIP=$(echo $VAULT_URL | rev | cut -d "/" -f 1 | rev)

VAULT_STORAGE_PATH="/vault/$INSTANCE_ID"
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


ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --instance-ids "$INSTANCE_ID" --region "${AWS_REGION}" | jq -r ".AutoScalingInstances[].AutoScalingGroupName")
echo ASG_NAME $ASG_NAME

instance_id_array=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${ASG_NAME}" --region "${AWS_REGION}" | jq -r '.AutoScalingGroups[].Instances[] | select(.LifecycleState == "InService").InstanceId')
echo instance_id_array $instance_id_array

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

setcap cap_ipc_lock=+ep /usr/local/bin/vault

# TODO: Andrew Code here 
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
                vault operator init -recovery-shares=${VAULT_NUMBER_OF_KEYS} -recovery-threshold=${VAULT_NUMBER_OF_KEYS_FOR_UNSEAL} | tee /etc/vault/vault-init.txt
                aws put-secret-value --secret-id ${VAULT_SECRET} --secret-string "$(cat /etc/vault/vault-init.txt)"
                sudo chown ubuntu:ubuntu /etc/vault/vault-init.txt
        else
                echo "Vault is already initialized"
        fi

        sealed=$(curl -fs localhost:8200/v1/sys/seal-status | jq -r .sealed)
        unseal_key=$(awk '{ if (match($0,/Recovery Key 1: (.*)/,m)) print m[1] }' /etc/vault/vault-init.txt)
        root_token=$(awk '{ if (match($0,/Initial Root Token: (.*)/,m)) print m[1] }' /etc/vault/vault-init.txt)

        echo $unseal_key > /etc/vault/unseal-key.txt 
        echo $root_token > /etc/vault/root-token.txt
  
        if [ "$sealed" == "true" ]; then
                echo "Unsealing Vault"
                vault operator unseal $unseal_key 
        else
                echo "Vault is already unsealed"
        fi

        sleep 10s 

        # Enable AWS Auth
        vault login token=$root_token
        vault auth enable aws

        # Create client-role-iam role
        vault write auth/aws/role/${VAULT_CLIENT_ROLE_NAME} auth_type=iam \
                bound_iam_principal_arn=${VAULT_CLIENT_ROLE} \
                policies=vaultclient \
                ttl=24h

        # Signal based on cfn-init commands status code
        /usr/local/bin/cfn-signal -e $? --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultServerAutoScalingGroup"
        # Bailout
        exit 0
fi

# Only Vault cluster members are here so 
sleep 60
echo "Checking if I am able to bootstrap further: "
# Loop until I show up in CLUSTER_MEMBER SSM Parameter
while true
do
        echo "Invoking Cluster Bootstrap Lambda"
        # Invoke Bootstrap Lambda
        # TODO: Add vault cleanup to lambda if needed
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
                # TODO: We may need to rather interrogate Vault for this bit to make sure the Lambda publishes only nodes added to vault(and ourselves)
                # TODO: Could be safer to check vault for this check list
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

# TODO: enable and start vault
# /usr/local/bin/cfn-init --verbose --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultServerAutoScalingGroup" --configsets vault_install
sudo systemctl enable vault
sudo systemctl start vault

# Don't signal until we report that we have started
until curl -fs -o /dev/null localhost:8200/v1/sys/init; do
        echo "Waiting for Vault to start..."
        sleep 1
done

# Vault has started signal success to Cloudformation
/usr/local/bin/cfn-signal -e 0 --stack ${CFN_STACK_NAME} --region ${AWS_REGION} --resource "VaultServerAutoScalingGroup"