import logging
import boto3
import os


def lambda_handler(event, context):
  """Main Lambda Handler"""
  
  def log_config(loglevel=None, botolevel=None):
    """Setup logging"""
    if 'ResourceProperties' in event.keys():
        if 'loglevel' in event['ResourceProperties'] and not loglevel:
            loglevel = event['ResourceProperties']['loglevel']
        if 'botolevel' in event['ResourceProperties'] and not botolevel:
            botolevel = event['ResourceProperties']['botolevel']
    if not loglevel:
        loglevel = 'warning'
    if not botolevel:
        botolevel = 'error'

    # Set log verbosity levels
    loglevel = getattr(logging, loglevel.upper(), 20)
    botolevel = getattr(logging, botolevel.upper(), 40)
    mainlogger = logging.getLogger()
    mainlogger.setLevel(loglevel)
    logging.getLogger('boto3').setLevel(botolevel)
    logging.getLogger('botocore').setLevel(botolevel)

    mylogger = logging.getLogger("lambda_handler")
    mylogger.setLevel(loglevel)

    return logging.LoggerAdapter(
        mylogger,
        {'requestid': event.get('RequestId','__None__')}
    )

  def get_ssm_parameter(ssm_client, ssm_parameter_name):
    param_value = ssm_client.get_parameter(
        Name=ssm_parameter_name,
        WithDecryption=False
    )
       
    return param_value.get('Parameter').get('Value')
    
  def set_ssm_parameter(ssm_client, ssm_parameter_name, value, Overwrite=True, Type="String"):
    response = ssm_client.put_parameter(
        Name=ssm_parameter_name,
        Value=value,
        Overwrite=True,
        Type="String"
    )
       
    return response

  """Main Lambda Logic"""
  # Configure Logging
  logger = log_config()
  logger.info(event)

  AUTOSCALING_GROUP = os.environ["AutoScalingGroup"]
  LEADER_ELECTED = os.environ["LeaderElectedSSM"]
  LEADER = os.environ["LeaderSSM"]
  INSTANCE_ID = event.get("instance_id")

  try:
    ssm_client = boto3.client('ssm')
    # Check if Leader Election in progress, Leader Elected or Leader SSM Parameters are set. If so bail out.
    leader_elected = get_ssm_parameter(ssm_client, LEADER_ELECTED)
    if leader_elected == "True" or leader_elected == "inprogress":
      logger.info("Leader election is 'True' or is 'inprogress'. Bailing out")
      print("Leader election is 'True' or is 'inprogress'. Bailing out")
      return 0 
  
    # Set Leader Election in progress.
    logger.info("Setting Leader election in progress.")
    print("Setting Leader election in progress.")
    response = set_ssm_parameter(ssm_client,LEADER_ELECTED,"inprogress")
  
    # TODO: Confirm instance in Our ASG
    
  
    # Elect a Leader
    logger.info("Setting Leader SSM Variable to '{}'.".format(INSTANCE_ID))
    print("Setting Leader SSM Variable to '{}'.".format(INSTANCE_ID))
    response = set_ssm_parameter(ssm_client, LEADER, INSTANCE_ID)
  
    # Bootstrap the leader.
    logger.info("BootStrapping Vault Leader: {}.".format(INSTANCE_ID))
    print("Bootstrap Vault Leader: {}".format(INSTANCE_ID))
    # TODO: Insert bootstrap leader actions here
  
    # Set Leader Elected SSM Parameter.
    logger.info("Setting Leader Elected SSM Variable to 'True'.")
    print("Setting Leader Elected SSM Variable to 'True'.")
    response = set_ssm_parameter(ssm_client, LEADER_ELECTED, "True")
    logger.info("All done")
    print("All done")
  except Exception as e:
    # Reset our flags

    ssm_client = boto3.client("ssm")
    set_ssm_parameter(ssm_client, LEADER_ELECTED, "False")
    set_ssm_parameter(ssm_client, LEADER, "null")
  return
