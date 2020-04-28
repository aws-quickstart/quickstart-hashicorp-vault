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
User=${USER}
Group=${GROUP}
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

cloud_watch_log_config () {
cat << EOF >/etc/awslogs-config-file
[general]
state_file = /var/awslogs/state/agent-state

[/var/log/syslog]
file = /var/log/vault_audit.logstatus
log_group_name = ${VAULT_LOG_GROUP}
log_stream_name = {instance_id}
datetime_format = %b %d %H:%M:%S
EOF
}

cloud_watch_logs () {
  cloud_watch_log_config
  # CIS ubuntu tries to hide OS details breaking the installer 
  cp /etc/issue /etc/issue.old && echo Ubuntu | cat - /etc/issue > /etc/issue.temp && mv /etc/issue.temp /etc/issue
  python /usr/local/awslogs-agent-setup.py -n -r ${AWS_REGION} -c /etc/awslogs-config-file
  # CIS ubuntu tries to hide OS details breaking the installer remove
  mv /etc/issue.old /etc/issue
  systemctl enable awslogs
  systemctl start awslogs
}

USER="vault"
COMMENT="Hashicorp vault user"
GROUP="vault"
HOME="/srv/vault"