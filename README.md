## HashiCorp Vault on the AWS Cloud
> Vault version 0.7.0

> Consul version 0.8.0

### Deployment options:
* Deployment of HashiCorp Vault into a new VPC (end-to-end deployment) builds a new VPC with public and private subnets, and then deploys HashiCorp Vault into that infrastructure.
* Deployment of HashiCorp Vault into an existing VPC provisions HashiCorp Vault into your existing infrastructure. 

### Architecture
![quickstart-hashicorp-consul](/images/vault.png)

### Change Log:
* Added Linux Bastion (Entry point for Consul and Vault)
* Added Support for Consul version to '0.8.0'

### Template Changes
* Added Master template (Create VPC and Consul Enviornment)
  * Creates VPC using QuickStart Scaleable VPC template https://github.com/aws-quickstart/quickstart-aws-vpc
  * Creates Consul enviornment using QuickStart Consul template as depedency https://github.com/aws-quickstart/quickstart-hashicorp-consul

* Workload Template
 * Added CloudWatch logs for vault audit-logs
 * Added Vault SNS Topic
 * Uses Consul DNS to discover Consul
