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

USER="vault"
COMMENT="Hashicorp vault user"
GROUP="vault"
HOME="/srv/vault"