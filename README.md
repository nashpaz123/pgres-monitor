# PostgreSQL Monitoring with Jenkins, Grafana, and Traefik on Kubernetes

This project deploys a complete monitoring and CI/CD solution on Kubernetes (Minikube) with the following components:

- **Traefik**: Load balancer and Ingress controller
- **Jenkins**: CI/CD server with dynamic Kubernetes worker pods
- **PostgreSQL**: Persistent database for Jenkins configuration and job history
- **Grafana**: Monitoring and visualization dashboards

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Traefik Ingress                          │
│              (Load Balancer / Ingress Controller)            │
└──────────────┬──────────────────┬──────────────────────────┘
               │                  │
               │                  │
    ┌──────────▼──────────┐  ┌───▼──────────┐
    │   Jenkins Server    │  │   Grafana    │
    │   (Master Pod)      │  │   Dashboard  │
    └──────────┬──────────┘  └──────^───────┘
               │                    |                   
               │                    |
    ┌──────────▼──────────┐         |
    │  Jenkins Worker Pods │        |
    │  (Dynamic K8s Pods)  │        |
    └──────────┬───────────┘        |
               │                    |
               │                    |
    ┌──────────▼──────────┐         |
    │   PostgreSQL DB     │---------
    │   (Persistent)       │
    └─────────────────────┘
```

## Prerequisites

- macOS (tested on macOS)
- Docker Desktop installed and running
- kubectl, Helm, Minikube, and Terraform installed

### Installing Dependencies

If you need to install dependencies:

```bash
# Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install kubectl
brew install kubectl

# Install Helm
brew install helm

# Install Minikube
brew install minikube

# Install Terraform
brew install terraform
```

## Quick Start

### Deploy the Solution

Deploy all components to Minikube:

```bash
chmod +x deploy.sh
./deploy.sh install
```

This script will:
1. Set up Minikube cluster
2. Deploy Traefik Ingress Controller
3. Deploy PostgreSQL with persistent storage
4. Deploy Jenkins with Kubernetes plugin configured
5. Configure Jenkins jobs (runs every 5 minutes)
6. Deploy Grafana
7. Configure Grafana dashboards using Terraform
8. Create Ingress resources for all services

### Access the Services

After deployment, you can access the services:

**Get Minikube IP:**
```bash
minikube ip
```

**Access URLs:**
- **Jenkins**: `http://jenkins.local` (or `http://<minikube-ip>`)
- **Grafana**: `http://grafana.local` (or `http://<minikube-ip>`)
- **Traefik Dashboard**: `http://traefik.local` (or `http://<minikube-ip>`)

**To add local hostnames (optional):**
Add to `/etc/hosts`:
```bash
MINIKUBE_IP=$(minikube ip)
echo "$MINIKUBE_IP jenkins.local" | sudo tee -a /etc/hosts
echo "$MINIKUBE_IP grafana.local" | sudo tee -a /etc/hosts
echo "$MINIKUBE_IP traefik.local" | sudo tee -a /etc/hosts
```

**Credentials:**
- Jenkins admin password: Saved to `.jenkins-password` file
- Grafana admin password: Saved to `.grafana-password` file
- Default username for both: `admin`

### Check Status

```bash
./deploy.sh status
```

### Uninstall

To remove all components:

```bash
./deploy.sh uninstall
```

## Project Structure

```
pgres-monitor/
├── README.md                 # This file
├── deploy.sh                 # Main deployment script
├── .gitignore               # Git ignore file
├── helm/                    # Helm values files
│   ├── traefik-values.yaml
│   ├── postgres-values.yaml
│   ├── jenkins-values.yaml
│   └── grafana-values.yaml
├── jenkins/                 # Jenkins configuration
│   └── job-dsl.groovy       # Job DSL script
├── k8s/                     # Kubernetes manifests
│   └── ingress.yaml         # Ingress configuration
└── terraform/               # Terraform configuration
    ├── main.tf              # Grafana dashboard configuration
    └── versions.tf          # Terraform version requirements
```

## Components Details

### Traefik

- **Purpose**: Ingress controller and load balancer
- **Namespace**: `kube-system`
- **Ports**: 
  - HTTP: 30080 (NodePort)
  - Dashboard: 9000
- **Configuration**: `helm/traefik-values.yaml`

### PostgreSQL

- **Purpose**: Persistent storage for Jenkins data and job timestamps
- **Namespace**: `monitoring`
- **Database**: `jenkins`
- **User**: `postgres`
- **Password**: `postgres123` (stored in Kubernetes Secret)
- **Storage**: 10Gi persistent volume
- **Configuration**: `helm/postgres-values.yaml`

### Jenkins

- **Purpose**: CI/CD server with dynamic Kubernetes worker pods
- **Namespace**: `monitoring`
- **Mode**: High Availability (HA) with dynamic agents
- **Storage**: 20Gi persistent volume
- **Plugins**:
  - Kubernetes Plugin
  - Job DSL
  - Configuration as Code
  - Timestamper
  - AnsiColor
- **Configuration**: `helm/jenkins-values.yaml`

#### Jenkins Jobs

The deployment creates a job called `k8s-worker-job` that:
- Runs every 5 minutes (cron: `*/5 * * * *`)
- Launches dynamic Kubernetes worker pods
- Each pod records its timestamp in PostgreSQL
- Creates/updates the `job_timestamps` table

**Job DSL Script**: `jenkins/job-dsl.groovy`

### Grafana

- **Purpose**: Monitoring and visualization
- **Namespace**: `monitoring`
- **Storage**: 10Gi persistent volume
- **Dashboards**: Configured via Terraform
- **Data Source**: PostgreSQL
- **Configuration**: `helm/grafana-values.yaml`

#### Grafana Dashboards

Terraform automatically configures a PostgreSQL monitoring dashboard with:
- Job execution rate graph
- Recent job timestamps table
- Total records stat
- Records in last hour
- Unique pods count
- Average jobs per minute

**Terraform Configuration**: `terraform/main.tf`

## Database Schema

The Jenkins job creates and populates the following table:

```sql
CREATE TABLE job_timestamps (
    id SERIAL PRIMARY KEY,
    pod_name VARCHAR(255) NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    job_name VARCHAR(255),
    build_number INTEGER
);
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n monitoring
kubectl get pods -n kube-system
```

### View Logs

```bash
# Jenkins
kubectl logs -n monitoring -l app.kubernetes.io/component=jenkins-master

# PostgreSQL
kubectl logs -n monitoring -l app.kubernetes.io/name=postgresql

# Grafana
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# Traefik
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

### Restart Services

```bash
# Restart Jenkins
kubectl rollout restart deployment/jenkins -n monitoring

# Restart PostgreSQL
kubectl rollout restart statefulset/postgresql -n monitoring

# Restart Grafana
kubectl rollout restart deployment/grafana -n monitoring
```

### Access Jenkins CLI

```bash
JENKINS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/component=jenkins-master -o jsonpath='{.items[0].metadata.name}')
JENKINS_PASSWORD=$(cat .jenkins-password)

kubectl exec -n monitoring $JENKINS_POD -- jenkins-cli -s http://localhost:8080 -auth admin:$JENKINS_PASSWORD list-jobs
```

### Check Ingress

```bash
kubectl get ingress -n monitoring
kubectl describe ingress -n monitoring
```

### Minikube Issues

If Minikube is not starting:

```bash
# Delete and recreate
minikube delete
minikube start --memory=4096 --cpus=4 --disk-size=20g

# Check status
minikube status

# Enable addons
minikube addons enable ingress
minikube addons enable metrics-server
```

### Jenkins Job Not Running

1. Check if job exists:
```bash
JENKINS_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/component=jenkins-master -o jsonpath='{.items[0].metadata.name}')
JENKINS_PASSWORD=$(cat .jenkins-password)
kubectl exec -n monitoring $JENKINS_POD -- jenkins-cli -s http://localhost:8080 -auth admin:$JENKINS_PASSWORD list-jobs
```

2. Manually trigger the job:
```bash
kubectl exec -n monitoring $JENKINS_POD -- jenkins-cli -s http://localhost:8080 -auth admin:$JENKINS_PASSWORD build k8s-worker-job
```

## Configuration Files

### Credentials

- **PostgreSQL**: 
  - User: `postgres`
  - Password: `postgres123`
  - Database: `jenkins`

- **Jenkins**: 
  - User: `admin`
  - Password: Saved in `.jenkins-password`

- **Grafana**: 
  - User: `admin`
  - Password: Saved in `.grafana-password`

### Customization

To customize the deployment:

1. **PostgreSQL**: Edit `helm/postgres-values.yaml`
2. **Jenkins**: Edit `helm/jenkins-values.yaml`
3. **Grafana**: Edit `helm/grafana-values.yaml`
4. **Traefik**: Edit `helm/traefik-values.yaml`
5. **Ingress**: Edit `k8s/ingress.yaml`
6. **Grafana Dashboards**: Edit `terraform/main.tf`

## Security Notes

⚠️ **Important**: This setup uses default passwords for demonstration purposes. In production:

1. Use strong, unique passwords
2. Store secrets in a secrets management system (e.g., HashiCorp Vault)
3. Enable TLS/SSL for all services
4. Use RBAC policies
5. Enable network policies
6. Regularly update all components

## Requirements

- **Minikube**: v1.28+
- **kubectl**: v1.28+
- **Helm**: v3.12+
- **Terraform**: v1.0+
- **Docker**: v20.10+

## License

This project is provided as-is for educational and demonstration purposes.

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review component logs
3. Verify all prerequisites are met
4. Ensure Docker Desktop is running

TODOs: true persistant storage, storage for Tform state file, 