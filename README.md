# SmartTrip - Academy Lerner AWS Infrastructure

[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg?style=flat-square)](https://github.com/RichardLitt/standard-readme)

> AWS CLI infrastructure for Academy Lerner tourism platform, compliant with AWS Academy Learner Lab constraints

This AWS CLI infrastructure defines the complete AWS resources for the Academy Lerner tourism platform, specifically designed to work within AWS Academy Learner Lab Foundation Services restrictions while maintaining full system functionality.

## Table of Contents

- [Academy Lerner AWS Infrastructure](#academy-lerner-aws-infrastructure)
  - [Table of Contents](#table-of-contents)
  - [Background](#background)
  - [Install](#install)
  - [Usage](#usage)
    - [Prerequisites](#prerequisites)
    - [Quick Start](#quick-start)
    - [Configuration](#configuration)
    - [Deployment](#deployment)
  - [Architecture](#architecture)
    - [System Components](#system-components)
    - [Infrastructure Diagram](#infrastructure-diagram)
    - [Academy Lab Compliance](#academy-lab-compliance)
  - [Security](#security)
  - [Contributing](#contributing)
  - [License](#license)

## Background

The Academy Lerner platform is a comprehensive tourism intelligent system that provides AI-powered travel recommendations, user profiling, and intelligent matching between travelers. This infrastructure was originally designed for production AWS environments but has been refactored to comply with AWS Academy Learner Lab constraints while maintaining all essential functionality.

The infrastructure supports:
- **React Web Frontend** - Tourism platform web interface
- **Android Mobile App** - Native mobile client (deployed separately)
- **Java Spring Boot Backend** - Core business logic and API services
- **Python FastAPI AI Service** - Travel recommendations and ML capabilities
- **PostgreSQL Database** - Data persistence layer
- **Object Storage** - Media assets and static content

> Your infrastructure is complete when it can be deployed without ever having to look at its code. This makes it possible to separate your infrastructure's documented interface from its internal implementation.

## Install

### Prerequisites

- [AWS CLI](https://aws.amazon.com/cli/) >= 2.0
- [jq](https://stedolan.github.io/jq/) for JSON processing
- Bash shell environment
- AWS Academy Learner Lab account

### Setup

1. Clone this repository
2. Ensure AWS CLI is configured with Academy Lab credentials
3. Install jq for JSON processing
4. Make all scripts executable:

```bash
chmod +x *.sh
```

## Usage

### Quick Start

Deploy the complete SmartTrip infrastructure with a single command:

```bash
./setup-infrastructure.sh
```

This will:
1. Validate prerequisites
2. Load configuration from `config.json`
3. Create all AWS resources in dependency order
4. Validate the deployment
5. Generate a comprehensive report

### Configuration

Edit `config.json` to customize your deployment:

```json
{
  "project": {
    "name": "smarttrip",
    "environment": "production",
    "region": "us-east-1"
  },
  "database": {
    "backend": {
      "username": "smarttrip_user",
      "password": "YourSecurePassword123!"
    }
  }
}
```

### Individual Component Deployment

Deploy specific components:

```bash
./setup-vpc.sh           # VPC and networking
./setup-security.sh      # Security groups
./setup-databases.sh     # RDS PostgreSQL
./setup-compute.sh       # EC2 instances and load balancer
./setup-storage.sh       # S3 buckets
./setup-networking.sh    # API Gateway and message queues
./setup-monitoring.sh    # CloudWatch and alarms
```

### Validation

Validate your deployment:

```bash
./validate-infrastructure.sh
```

### Cleanup

Remove all resources:

```bash
./destroy-infrastructure.sh
```

## Architecture

### System Components

| Component | Technology | Purpose | AWS Resources |
|-----------|------------|---------|---------------|
| **Web Frontend** | React | Tourism platform interface | S3 + CloudFront |
| **Mobile App** | Kotlin | Native mobile experience | Google Play Store |
| **Backend API** | Spring Boot | Core business logic | EC2 Auto Scaling |
| **AI Service** | FastAPI | ML recommendations | EC2 Auto Scaling |
| **API Gateway** | AWS API Gateway | Service routing | API Gateway |
| **Message Queues** | SQS/SNS | Asynchronous events | SQS + SNS |
| **Database** | PostgreSQL 15.4 | Data persistence | RDS (db.t3.micro) |
| **Storage** | S3 | Media assets | S3 + CloudFront |

### Infrastructure Diagram

```mermaid
flowchart LR

%% Clients
WebBrowser[Web Browser]
MobileApp[Mobile App]

%% Edge Layer
CloudFront[CloudFront CDN]
S3Frontend[S3 (React App)]

%% API Layer
APIGateway[API Gateway]

%% Compute Layer
ALB[Application Load Balancer]
Backend[Backend Service (Spring Boot)\nPort 8080]
AI[AI Service (FastAPI)\nPort 8000]

%% Data Layer
RDS[(PostgreSQL RDS db.t3.micro)]
S3Storage[(S3 Media Storage)]

%% Messaging
SNS[SNS Topics]
SQS[SQS Queues]

%% Observability
CloudWatch[CloudWatch Logs & Metrics]

%% Frontend Flow
WebBrowser --> CloudFront --> S3Frontend
CloudFront --> APIGateway
MobileApp --> APIGateway

%% API Routing
APIGateway --> ALB

%% Backend Services
ALB --> Backend
ALB --> AI

%% Data Access
Backend --> RDS
AI --> RDS

Backend --> S3Storage
AI --> S3Storage

%% Messaging Flow (fixed pattern)
Backend --> SNS
AI --> SNS
SNS --> SQS
SQS --> Backend

%% Monitoring
Backend --> CloudWatch
AI --> CloudWatch
APIGateway --> CloudWatch
ALB --> CloudWatch
```

### Academy Lab Compliance

**Resource Constraints:**
- **Instance Types**: t3.micro only (maximum 9 instances)
- **Region**: us-east-1 only
- **IAM**: LabRole and LabInstanceProfile only
- **VPC**: No NAT Gateway or EIP
- **Database**: Single-AZ, no encryption
- **Storage**: Standard storage classes only

**Cost Optimization:**
- Auto-scaling with minimum capacity
- S3 lifecycle policies
- CloudWatch log retention (14 days)
- Resource tagging for cost allocation

## Security

### Network Security

- **Security Groups**: Separate for each service
- **Network ACLs**: Prevent direct service-to-service communication
- **API Gateway**: Centralized entry point with throttling
- **VPC**: Isolated network environment

### Data Protection

- **Database**: PostgreSQL with strong passwords
- **Storage**: Private S3 buckets with encryption
- **Communication**: HTTPS/TLS for all external traffic
- **Access Control**: Least privilege IAM policies

### Monitoring

- **CloudWatch**: Comprehensive logging and metrics
- **Alarms**: CPU, memory, and performance thresholds
- **Health Checks**: Service endpoint monitoring
- **Audit Logs**: Complete audit trail

## Service Endpoints

After deployment, your services will be available at:

### Frontend
- **Website**: `http://[frontend-bucket].s3-website-us-east-1.amazonaws.com`

### APIs
- **Backend API**: `https://[api-id].execute-api.us-east-1.amazonaws.com/prod/backend`
- **AI Service API**: `https://[api-id].execute-api.us-east-1.amazonaws.com/prod/ai`

### Internal Services
- **Backend Service**: `http://[load-balancer-dns]:8080`
- **AI Service**: `http://[load-balancer-dns]:8000`

### Databases
- **Backend DB**: `[endpoint]:5432/smarttrip_backend`
- **AI Service DB**: `[endpoint]:5432/smarttrip_ai`

## Environment Variables

### Database Configuration
- `DB_HOST`: Database endpoint (auto-generated)
- `DB_NAME`: Database name
- `DB_USERNAME`: Database username
- `DB_PASSWORD`: Database password

### Service Configuration
- `AWS_REGION`: AWS region (us-east-1)
- `API_GATEWAY_URL`: API Gateway endpoint
- `SQS_USER_EVENTS_QUEUE`: User events queue URL
- `SNS_RECOMMENDATION_EVENTS_TOPIC`: Recommendation events topic ARN

## Verification

### Health Checks

Verify your deployment:

```bash
# Check load balancer
aws elbv2 describe-load-balancers --names smarttrip-alb

# Check databases
aws rds describe-db-instances --db-instance-identifier smarttrip-backend-db

# Check API Gateway
aws apigateway get-rest-api --rest-api-id [api-id]

# Check S3 buckets
aws s3 ls
```

### Service Testing

Test service endpoints:

```bash
# Backend health check
curl http://[load-balancer-dns]:8080/actuator/health

# AI service health check
curl http://[load-balancer-dns]:8000/health

# API Gateway test
curl https://[api-id].execute-api.us-east-1.amazonaws.com/prod/backend/health
```

## Troubleshooting

### Common Issues

**AWS Credentials Not Found:**
```bash
aws configure
# Enter Academy Lab credentials
```

**Instance Type Not Available:**
- Ensure you're using t3.micro only
- Check Academy Lab resource limits

**Permission Denied:**
- Verify LabRole is attached to instances
- Check Academy Lab session status

**Database Connection Failed:**
- Verify security group allows database access
- Check database endpoint and credentials

### Debug Commands

```bash
# Check resource status
./validate-infrastructure.sh

# View logs
tail -f infrastructure-setup-$(date +%Y%m%d)*.log

# Check resource IDs
cat resource-ids.txt
```

## Contributing

### Development Workflow

1. **Fork** the repository
2. **Create** a feature branch
3. **Test** changes in Academy Lab environment
4. **Validate** with `./validate-infrastructure.sh`
5. **Submit** a pull request

### Code Standards

- Use Bash shell scripts with proper error handling
- Follow AWS CLI best practices
- Include comprehensive logging
- Add resource tagging for all resources
- Ensure Academy Lab compliance

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.

### License Summary

- **Commercial Use**: Yes
- **Modification**: Yes
- **Distribution**: Yes
- **Private Use**: Yes
- **Liability**: No
- **Warranty**: No

### Copyright

© 2026 Voyager Team. All rights reserved.

---

**Note**: This infrastructure is specifically designed for AWS Academy Learner Lab environments and may require modifications for production deployments.
