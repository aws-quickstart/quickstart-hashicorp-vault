"""This function handles Cluster Node bootstrapping"""
from __future__ import print_function
import os
# os.environ["DB_HOST"]
import boto3
import logging
import json

# Sample event
# {
#    "action": "add",
#    "instance_id": "i-12312313144423"
# }

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

  """Main Lambda Logic"""
  # Setup Logging
  logger = log_config()
  logger.info(event)
  print(event)

  # Get Environment Variables
  AUTOSCALING_GROUPS=[ ""+os.environ["AutoScalingGroup"] ]
  CLUSTER_MEMBERS=os.environ["ClusterMembersSSM"]
  LEADER_ELECTED=os.environ["LeaderElectedSSM"]
  LEADER=os.environ["LeaderSSM"]

  print(AUTOSCALING_GROUPS)
  print(CLUSTER_MEMBERS)
  print(LEADER_ELECTED)
  print(LEADER)
  
  # Get Parameters we are passed
  instance_id=event["instance_id"]
  cluster_members = []

  # Is there an elected leader?
  ssm_client = boto3.client("ssm") 
  leader_elected = get_ssm_parameter(ssm_client, LEADER_ELECTED)
  print("LeaderElected: {}".format(leader_elected))
  
  # No Elected Leader bail out
  if leader_elected != "True":
      logger.info("No elected leader yet no nodes should bootstrap. Bailing out.")
      print("No elected leader yet no nodes should bootstrap. Bailing out.")
      return

  
  # Describe ASG and find nodes.
  asg_client = boto3.client("autoscaling")
  response = asg_client.describe_auto_scaling_groups(
      AutoScalingGroupNames=AUTOSCALING_GROUPS
  )

  cluster_members = []
  print(response)
  for AutoScalingGroup in response.get("AutoScalingGroups"):
      print(AutoScalingGroup)
      for instance in AutoScalingGroup.get("Instances"):
          print(instance)
          cluster_members.append(instance.get("InstanceId"))

          # Find ones that are not healthy or don't exist
          # terminating:wait
  
  # TODO: Remove nodes which are no longer in the Vault API.
  
  # Rewrite the SSM Parameter with cluster members including new node. 
  print(cluster_members)
  
  separator = ","
  cluster_members_string = separator.join(cluster_members)
  
  response = ssm_client.put_parameter(
      Name=CLUSTER_MEMBERS,
      Type="String",
      Value=cluster_members_string,
      Overwrite=True
  )
  print("All done")

  return