# GPG Key for verifying packages pulled from HashiCorp
cat << EOF > /tmp/hashicorp.asc
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQENBFMORM0BCADBRyKO1MhCirazOSVwcfTr1xUxjPvfxD3hjUwHtjsOy/bT6p9f
W2mRPfwnq2JB5As+paL3UGDsSRDnK9KAxQb0NNF4+eVhr/EJ18s3wwXXDMjpIifq
fIm2WyH3G+aRLTLPIpscUNKDyxFOUbsmgXAmJ46Re1fn8uKxKRHbfa39aeuEYWFA
3drdL1WoUngvED7f+RnKBK2G6ZEpO+LDovQk19xGjiMTtPJrjMjZJ3QXqPvx5wca
KSZLr4lMTuoTI/ZXyZy5bD4tShiZz6KcyX27cD70q2iRcEZ0poLKHyEIDAi3TM5k
SwbbWBFd5RNPOR0qzrb/0p9ksKK48IIfH2FvABEBAAG0K0hhc2hpQ29ycCBTZWN1
cml0eSA8c2VjdXJpdHlAaGFzaGljb3JwLmNvbT6JAU4EEwEKADgWIQSRpuf4XQXG
VjC+8YlRhS2HNI/8TAUCXn0BIQIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAK
CRBRhS2HNI/8TJITCACT2Zu2l8Jo/YLQMs+iYsC3gn5qJE/qf60VWpOnP0LG24rj
k3j4ET5P2ow/o9lQNCM/fJrEB2CwhnlvbrLbNBbt2e35QVWvvxwFZwVcoBQXTXdT
+G2cKS2Snc0bhNF7jcPX1zau8gxLurxQBaRdoL38XQ41aKfdOjEico4ZxQYSrOoC
RbF6FODXj+ZL8CzJFa2Sd0rHAROHoF7WhKOvTrg1u8JvHrSgvLYGBHQZUV23cmXH
yvzITl5jFzORf9TUdSv8tnuAnNsOV4vOA6lj61Z3/0Vgor+ZByfiznonPHQtKYtY
kac1M/Dq2xZYiSf0tDFywgUDIF/IyS348wKmnDGjuQENBFMORM0BCADWj1GNOP4O
wJmJDjI2gmeok6fYQeUbI/+Hnv5Z/cAK80Tvft3noy1oedxaDdazvrLu7YlyQOWA
M1curbqJa6ozPAwc7T8XSwWxIuFfo9rStHQE3QUARxIdziQKTtlAbXI2mQU99c6x
vSueQ/gq3ICFRBwCmPAm+JCwZG+cDLJJ/g6wEilNATSFdakbMX4lHUB2X0qradNO
J66pdZWxTCxRLomPBWa5JEPanbosaJk0+n9+P6ImPiWpt8wiu0Qzfzo7loXiDxo/
0G8fSbjYsIF+skY+zhNbY1MenfIPctB9X5iyW291mWW7rhhZyuqqxN2xnmPPgFmi
QGd+8KVodadHABEBAAGJATwEGAECACYCGwwWIQSRpuf4XQXGVjC+8YlRhS2HNI/8
TAUCXn0BRAUJEvOKdwAKCRBRhS2HNI/8TEzUB/9pEHVwtTxL8+VRq559Q0tPOIOb
h3b+GroZRQGq/tcQDVbYOO6cyRMR9IohVJk0b9wnnUHoZpoA4H79UUfIB4sZngma
enL/9magP1uAHxPxEa5i/yYqR0MYfz4+PGdvqyj91NrkZm3WIpwzqW/KZp8YnD77
VzGVodT8xqAoHW+bHiza9Jmm9Rkf5/0i0JY7GXoJgk4QBG/Fcp0OR5NUWxN3PEM0
dpeiU4GI5wOz5RAIOvSv7u1h0ZxMnJG4B4MKniIAr4yD7WYYZh/VxEPeiS/E1CVx
qHV5VVCoEIoYVHIuFIyFu1lIcei53VD6V690rmn0bp4A5hs+kErhThvkok3c
=+mCN
-----END PGP PUBLIC KEY BLOCK-----
EOF

# Common functions for bootstrap
get_ssm_param () {
        local value=$(aws ssm get-parameter --region ${AWS_REGION} --name "$1" $2| jq -r ".Parameter|.Value" )
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
  VAULT_SIG_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"
  # Fetch installation file
  curl --silent --output /tmp/${VAULT_ZIP} ${VAULT_URL}
  
  # Fetch SHA256SUM files and sig
  curl --silent --output /tmp/vault_${VAULT_VERSION}_SHA256SUMS ${VAULT_SIG_URL}
  curl --silent --output /tmp/vault_${VAULT_VERSION}_SHA256SUMS.sig ${VAULT_SIG_URL}.sig
  
  # import GPG 
  gpg --import /tmp/hashicorp.asc

  # Verify the signature file is untampered.
  gpg --verify /tmp/vault_${VAULT_VERSION}_SHA256SUMS.sig /tmp/vault_${VAULT_VERSION}_SHA256SUMS

  # Check the download SHA256 matches the SHA256 file
  cd /tmp
  grep "${VAULT_ZIP}" vault_${VAULT_VERSION}_SHA256SUMS | sha256sum -c
  cd -

  unzip -o /tmp/${VAULT_ZIP} -d /usr/local/bin/
  chmod 0755 /usr/local/bin/vault
  chown ${USER}:${GROUP} /usr/local/bin/vault
  mkdir -pm 0755 /etc/vault.d
  mkdir -pm 0755 ${VAULT_STORAGE_PATH}
  chown -R ${USER}:${GROUP} ${VAULT_STORAGE_PATH}
  chmod -R a+rwx ${VAULT_STORAGE_PATH}

  mkdir -pm 0755 ${VAULT_LOG_PATH}
  chown -R ${USER}:${GROUP} ${VAULT_LOG_PATH}
  chmod -R a+rwx ${VAULT_LOG_PATH}
}

cloud_watch_log_config () {
cat << EOF >/etc/awslogs-config-file
[general]
state_file = /var/awslogs/state/agent-state

[/var/log/syslog]
file = ${VAULT_LOG_PATH}/vault-audit.log
log_group_name = ${VAULT_LOG_GROUP}
log_stream_name = {instance_id}
datetime_format = %b %d %H:%M:%S
EOF
}

cloud_watch_logs () {
  cloud_watch_log_config
  curl -s https://s3.amazonaws.com/aws-cloudwatch/downloads/latest/awslogs-agent-setup.py --output /usr/local/awslogs-agent-setup.py
  # CIS ubuntu tries to hide OS details breaking the installer 
  cp /etc/issue /etc/issue.old && echo Ubuntu | cat - /etc/issue > /etc/issue.temp && mv /etc/issue.temp /etc/issue
  python /usr/local/awslogs-agent-setup.py -n -r ${AWS_REGION} -c /etc/awslogs-config-file
  # CIS ubuntu tries to hide OS details breaking the installer remove
  mv /etc/issue.old /etc/issue
  systemctl enable awslogs
  systemctl start awslogs
}

get_kubernetes_ca () {
cat <<EOF > /etc/vault.d/ca.crt
$(get_ssm_param ${VAULT_KUBERNETES_CERTIFICATE})
EOF
chown ${USER}.${GROUP} /etc/vault.d/ca.crt
chmod 600 /etc/vault.d/ca.crt
# # The newlines get lost ... just fix the cert
# sed -zi 's/IN CE/IN_CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ND CE/ND_CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ /\n/g' /etc/vault.d/ca.crt
# sed -zi 's/IN_CE/IN CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ND_CE/ND CE/g' /etc/vault.d/ca.crt
}

get_kubernetes_jwt () {
cat <<EOF > /etc/vault.d/jwt.token
$(get_ssm_param ${VAULT_KUBERNETES_JWT} " --with-decryption")
EOF
chown ${USER}.${GROUP} /etc/vault.d/jwt.token
chmod 600 /etc/vault.d/jwt.token
# # The newlines get lost ... just fix the cert
# sed -zi 's/IN CE/IN_CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ND CE/ND_CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ /\n/g' /etc/vault.d/ca.crt
# sed -zi 's/IN_CE/IN CE/g' /etc/vault.d/ca.crt
# sed -zi 's/ND_CE/ND CE/g' /etc/vault.d/ca.crt
}

USER="vault"
COMMENT="Hashicorp vault user"
GROUP="vault"
HOME="/srv/vault"