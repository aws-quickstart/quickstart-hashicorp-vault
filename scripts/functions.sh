# Common functions for bootstrap
get_ssm_param () {
        local value=$(aws ssm get-parameter --region ${AWS_REGION} --name "$1"| jq -r ".Parameter|.Value" )
        echo $value
}

get_secret () {
        local value=$(aws secretsmanager --region ${AWS_REGION} get-secret-value --secret-id "$1" | jq --raw-output .SecretString)
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

get_mdsv2 () {
    echo $(TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null` \
&& curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/${1} 2>/dev/null)
}

vault_systemctl_file () {
cat << EOF > /lib/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl
[Service]
User=${USER}
Group=${GROUP}
ExecStart=/usr/local/bin/vault server -config /etc/vault.d -log-level=warn
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
KillSignal=SIGINT
TimeoutStopSec=30
StartLimitInterval=60
StartLimitIntervalSec=60
StartLimitBurst=3
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
}

install_vault () {
  curl --silent --output /tmp/${VAULT_ZIP} ${VAULT_URL}
  unzip -o /tmp/${VAULT_ZIP} -d /usr/local/bin/
  chmod 0755 /usr/local/bin/vault
  chown ${USER}:${GROUP} /usr/local/bin/vault
  mkdir -pm 0755 /etc/vault.d
  mkdir -pm 0755 ${VAULT_STORAGE_PATH}
  chown -R vault:vault ${VAULT_STORAGE_PATH}
  chmod -R a+rwx ${VAULT_STORAGE_PATH}
}

USER="vault"
COMMENT="Hashicorp vault user"
GROUP="vault"
HOME="/srv/vault"