## HashiCorp Vault on the AWS Cloud
VAULT_VERSION 0.10.4

CONSUL_VERSION '1.2.2'

CONSUL_TEMPLATE_VERSION='0.19.5'

### Deployment options:
* Deployment of HashiCorp Vault into a new VPC (end-to-end deployment) builds a new VPC with public and private subnets, and then deploys HashiCorp Vault into that infrastructure.
* Deployment of HashiCorp Vault into an existing VPC provisions HashiCorp Vault into your existing infrastructure. 

### Architecture
![quickstart-hashicorp-consul](https://d1.awsstatic.com/partner-network/QuickStart/datasheets/hashicorp-vault-on-aws-arch.9f69be520f58e8ecc71bd00636eb954800a5c8b2.png)

### Change Log:
* Added Support for Consul version to '1.2.2'

### Template Changes
* Added Master template (Create VPC and Consul environment)
  * Creates VPC using QuickStart Scalable VPC template https://fwd.aws/rdXz7
  * Creates Consul environment using QuickStart Consul template as dependency https://fwd.aws/Xymjw

* Workload Template
 * Added CloudWatch logs for vault audit-logs
 * Added Vault SNS Topic
 * Uses Consul DNS to discover Consul
