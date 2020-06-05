## HashiCorp Vault on the AWS Cloud
Vault version: 1.4

HashiCorp Vault is a product that centrally secures, stores and controls access to tokens, passwords, certificates, and encryption keys through a UI, CLI, or an HTTP API. Vault’s core use cases include:

* Secrets management: Securely manage and deploy secrets across different environments, applications, and services.
* Encryption and data protection: Manage encryption and keys for developers and operators across different environments, applications, and services.
* Privileged-access management: Secure workloads for application-to-application and user-to-application credential management across different environments and services.

HashiCorp Vault is designed for DevOps professionals and application developers who want to manage their secrets, data, and key-value stores. It’s built using the open-source version of Vault, but it’s also compatible with Vault Enterprise. Supplemental details, with instructions and screenshots, are available on the HashiCorp [Vault](https://www.vaultproject.io/) and [Vault Enterprise](https://www.hashicorp.com/vault.html) websites.

Each stack in this deployment takes approximately 20 minutes to create. For more information and step-by-step deployment instructions, see the [deployment guide](https://fwd.aws/j4xqw).

### Deployment options
* Deployment of HashiCorp Vault into a new VPC (end-to-end deployment) builds a new VPC with public and private subnets, and then deploys HashiCorp Vault into that infrastructure.
* Deployment of HashiCorp Vault into an existing VPC provisions HashiCorp Vault into your existing infrastructure.

### Architecture
![quickstart-hashicorp-consul](https://d0.awsstatic.com/partner-network/QuickStart/datasheets/hashicorp-vault-on-aws-architecture.png)

### Change log (June 2020)
* Upgraded to HashiCorp Vault 1.4 using best practices
* Updated AWS architecture
* Updated templates:
  * [Deploy HashiCorp Vault into a new VPC on AWS](https://fwd.aws/wN73v)
  * [Deploy HashiCorp Vault into an existing VPC on AWS](https://fwd.aws/keAD3) 
  
For architectural details, best practices, step-by-step instructions, and customization options, see the [deployment guide](https://fwd.aws/j4xqw).

To post feedback, submit feature ideas, or report bugs, use the **Issues** section of this GitHub repo.
If you'd like to submit code for this Quick Start, please review the [AWS Quick Start Contributor's Kit](https://aws-quickstart.github.io/).
