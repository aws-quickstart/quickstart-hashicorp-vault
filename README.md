## Change Log: (tagged v1.0)

### Template Changes
* Added Master template (Create VPC and Consul Enviornment)
  * Creates VPC using QuickStart Scaleable VPC template https://github.com/aws-quickstart/quickstart-aws-vpc
  * Creates Consul enviornment using QuickStart Consul template as depedency https://github.com/aws-quickstart/quickstart-hashicorp-consul

* Workload Template
 * Added CloudWatch logs for vault audit-logs
 * Added Vault SNS Topic
 * Uses Consul DNS to discover Consul
