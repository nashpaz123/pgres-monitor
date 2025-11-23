# PostgreSQL Monitoring with Jenkins, Grafana, and Traefik on Kubernetes

This project deploys a monitoring and CI/CD solution on Kubernetes (Minikube) with the following components:

- **Traefik**: Load balancer and Ingress controller, exposes traffic to Jenkins, Grafna
- **Jenkins**: CI/CD server with dynamic Kubernetes worker pods,  populates Pgres DB
- **PostgreSQL**: Persistent database for Jenkins "job history"
- **Grafana**: Monitoring and visualization dashboards of Pgres DB usage 

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

-(tested on macOS)
- Docker Desktop installed and running (minikube req)
- kubectl, Helm, Minikube, and Terraform installed

## Quick Start

### Deploy the Solution

Deploy all components to Minikube:

```bash
chmod +x deploy.sh
./deploy.sh install
```

This script will:
1. Set up Minikube cluster (if not already running)
2. Deploy Traefik Ingress Controller as LoadBalancer
3. Start `minikube tunnel` for LoadBalancer access (requires sudo)
4. Wait for LoadBalancer to get EXTERNAL-IP
5. Deploy PostgreSQL with persistent storage
6. Deploy Jenkins with Kubernetes plugin configured
7. Configure Jenkins root URL for path-based access (`/jenkins`)
8. Create Jenkins jobs via Job DSL (runs every 5 minutes)
9. Deploy Grafana with sub-path configuration (`/grafana`)
10. Configure Grafana dashboards using Terraform
11. Create IngressRoute resources for all services (Middleware for /jenkins URL resolution)
12. Display access credentials and URLs

### Access the Services

After deployment, you can access the services via `minikube tunnel` (automatically started by the deploy script):

**Access URLs:**
- **Jenkins**: `http://127.0.0.1/jenkins`
- **Grafana**: `http://127.0.0.1/grafana`

**Note**: The deploy script automatically starts `minikube tunnel` in the background (requires sudo) to expose LoadBalancer services. If you need to restart it manually:

```bash
sudo minikube tunnel
```

**Credentials:**
The deploy script will display credentials after installation. You can also check them with:
```bash
./deploy.sh status
```

Default credentials:
- **Jenkins**: 
  - Username: `admin`
  - Password: Saved in `.jenkins-password` file or displayed by the script
- **Grafana**: 
  - Username: `admin`
  - Password: Saved in `.grafana-password` file or displayed by the script

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
│   ├── ingress.yaml         # Standard Ingress configuration
│   └── ingressroute.yaml    # Traefik IngressRoute configuration
└── terraform/               # Terraform configuration
    └── main.tf              # Grafana dashboard configuration
```

## Components Details

### Traefik

- **Purpose**: Ingress controller and load balancer
- **Namespace**: `kube-system`
- **Service Type**: LoadBalancer (exposed via `minikube tunnel`)
- **Entry Points**: 
  - HTTP: Port 80 (via minikube tunnel)
- **Configuration**: `helm/traefik-values.yaml`
- **Routing**: Uses Traefik IngressRoute CRD for path-based routing (`/jenkins`, `/grafana`)

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
# Check Traefik IngressRoutes
kubectl get ingressroute -n monitoring
kubectl describe ingressroute -n monitoring

# Check standard Ingress (if used)
kubectl get ingress -n monitoring
kubectl describe ingress -n monitoring

# Check Traefik service and LoadBalancer status
kubectl get svc -n kube-system traefik
```

### Minikube Issues

If Minikube is not starting:

```bash
# Delete and recreate
minikube delete
minikube start --memory=4096 --cpus=4 --disk-size=20g

# Check status
minikube status

# Enable addons (ingress addon should be DISABLED for Traefik)
minikube addons enable metrics-server
minikube addons disable ingress  # Traefik replaces the default ingress
```

### LoadBalancer / minikube tunnel Issues

If services are not accessible:

```bash
# Check if tunnel is running
sudo pgrep -af "minikube tunnel"

# Restart tunnel manually
sudo pkill -f "minikube tunnel"
sudo minikube tunnel

# Check LoadBalancer status
kubectl get svc -n kube-system traefik
# Should show EXTERNAL-IP (not <pending>)
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
5. **Ingress Routing**: Edit `k8s/ingressroute.yaml` (Traefik IngressRoute) or `k8s/ingress.yaml` (standard Ingress)
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

TODOs: Dynamic Middleware for jenkins, Grafana secuirty, external storage for pgres, external storage for Tform state file, smoke test for minikub tunnel , https://github.com/Rahn-IT/traefik-gui
