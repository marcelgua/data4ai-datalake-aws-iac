# Initial Ingestion Setup Specification

## Purpose
This capability provides the foundational infrastructure for ingesting external data into the data lake. It addresses the need for a local, testable development environment that mirrors production AWS S3 and AWS-based Airbyte deployment, combined with a self-managed data integration platform. The setup serves data engineers who need to develop, test, and validate ingestion pipelines locally before promoting them to production, reducing cloud costs and shortening iteration cycles.

## Requirements

### R1: LocalStack AWS Emulation
The system SHALL provide a local AWS-compatible storage and compute emulation via LocalStack, enabling development and testing of S3 and Airbyte deployment operations without connecting to real AWS infrastructure.

#### Scenario: Start LocalStack with S3 and EC2/ECS services
- GIVEN a developer has Docker installed and running
- WHEN the developer starts LocalStack with the S3 and EC2/ECS services enabled
- THEN local AWS-compatible API endpoints SHALL be available
- AND the endpoints SHALL accept AWS API operations for S3 and compute resources (EC2/ECS)

#### Scenario: Create and verify an S3 bucket locally
- GIVEN LocalStack is running with S3 enabled
- WHEN a client sends a CreateBucket request for a new bucket named `staging-bucket`
- THEN the bucket SHALL be created successfully
- AND subsequent ListBuckets requests SHALL include `staging-bucket`

---

### R2: Environment-Aware Terraform S3 Bucket Provisioning
The system SHALL use Terraform to provision a staging S3 bucket with configuration that adapts to the target environment — LocalStack for local/development and real AWS for production — based on a selectable environment input.

#### Scenario: Provision bucket in local environment using LocalStack
- GIVEN the Terraform workspace is set to the `local` environment
- AND LocalStack is running with S3 on the local endpoint
- WHEN `terraform apply` is executed
- THEN a staging S3 bucket SHALL be created in LocalStack
- AND the bucket name SHALL follow the pattern `<project>-staging-<environment>` (e.g., `data4ai-staging-local`)
- AND the bucket SHALL be configured with versioning enabled
- AND the bucket SHALL have server-side encryption enabled (AES256)

#### Scenario: Provision bucket in production environment using real AWS
- GIVEN the Terraform workspace is set to the `prod` environment
- AND valid AWS credentials are configured
- WHEN `terraform apply` is executed
- THEN a staging S3 bucket SHALL be created in the real AWS account
- AND the bucket name SHALL follow the pattern `<project>-staging-<environment>` (e.g., `data4ai-staging-prod`)
- AND the bucket SHALL be configured with versioning and AES256 encryption enabled

---

### R3: Airbyte AWS Deployment via Terraform
The system SHALL define the infrastructure for the self-managed Airbyte deployment as AWS resources (e.g., EC2 instance or ECS/EKS resources) using Terraform. In the `local` environment, this configuration SHALL target LocalStack's emulated services for testing, while in `prod`, it targets real AWS.

#### Scenario: Provision Airbyte compute resource in LocalStack
- GIVEN the Terraform workspace is set to the `local` environment
- AND LocalStack is running with compute emulation (EC2 or ECS)
- WHEN `terraform apply` is executed
- THEN the compute resources for Airbyte SHALL be provisioned in LocalStack
- AND the S3 bucket destination configured in Airbyte SHALL target LocalStack S3

#### Scenario: Provision Airbyte compute resource in Production AWS
- GIVEN the Terraform workspace is set to the `prod` environment
- AND valid AWS credentials are configured
- WHEN `terraform apply` is executed
- THEN the compute resources for Airbyte (e.g., EC2 instance or ECS service) SHALL be provisioned in the production AWS account
- AND it SHALL be configured to use the production staging S3 bucket as its destination

---

### R4: Network and Access Integration
The system SHALL ensure that the deployed Airbyte instance (whether running locally or in production) has the network access and IAM permissions required to write to the staging S3 bucket.

#### Scenario: Local S3 connection test
- GIVEN the local Airbyte deployment and LocalStack are running
- WHEN a test connection is initiated from Airbyte to the local S3 endpoint
- THEN the connection test SHALL succeed

---

### R5: Environment Configuration Management
The system SHALL provide a mechanism to select and toggle between environments (local vs. production) without modifying the core infrastructure code, using Terraform input variables or workspace-based configuration.

---

### R6: Partitioned S3 Target Paths
The S3 staging data paths configured in the Airbyte destination connection or the ingestion flow SHALL be partitioned by the source table name, followed by Hive-style partitioning on the ingestion timestamp.

#### Scenario: Verify Hive-style partitioned file output on local S3
- GIVEN Airbyte has executed a synchronization from a source table named `users` to S3
- WHEN files are written to the local S3 staging bucket `data4ai-staging-local`
- THEN the output path format SHALL follow the schema: `users/year=YYYY/month=MM/day=DD/hour=HH/`
- AND the files written under this prefix SHALL contain the sync data

---

### R7: AVRO Output Format
The staging data files written by the Airbyte destination to S3 SHALL be in AVRO format with appropriate compression/compaction.

#### Scenario: Verify AVRO file suffix and schema on local S3
- GIVEN Airbyte has executed a synchronization to the staging bucket
- WHEN files are written to the staging bucket
- THEN the file names SHALL end with `.avro`
- AND the files SHALL be valid AVRO files containing schema metadata and compressed data records
