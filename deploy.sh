#!/bin/bash

set -e

NAMESPACE="monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    for cmd in kubectl helm minikube terraform docker; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies first"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi
    
    log_info "All dependencies are installed"
}

setup_minikube() {
    log_info "Setting up Minikube cluster..."
    
    if minikube status &> /dev/null; then
        log_warn "Minikube cluster already exists"
        log_info "Using existing Minikube cluster"
        minikube start 2>/dev/null || true
    else
        log_info "Starting Minikube cluster..."
        minikube start --memory=4096 --cpus=4 --disk-size=20g
    fi
    
    log_info "Disabling default ingress addon (using Traefik instead)..."
    minikube addons disable ingress 2>/dev/null || true
    minikube addons enable metrics-server 2>/dev/null || true
    
    log_info "Minikube cluster is ready"
}

install_traefik() {
    log_info "Installing Traefik Ingress Controller..."
    
    helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
    helm repo update
    
    if helm list -n kube-system | grep -q traefik; then
        log_warn "Traefik already installed, upgrading..."
        helm upgrade traefik traefik/traefik \
            -n kube-system \
            -f "${SCRIPT_DIR}/helm/traefik-values.yaml" \
            --timeout=5m
    else
        helm install traefik traefik/traefik \
            -n kube-system \
            --create-namespace \
            -f "${SCRIPT_DIR}/helm/traefik-values.yaml" \
            --timeout=5m
    fi
    
    log_info "Waiting for Traefik to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=300s || true
    
    log_info "Traefik installed successfully"
    
    # Start minikube tunnel for LoadBalancer access (no NodePort needed)
    log_info "Starting minikube tunnel for LoadBalancer access..."
    log_warn "This requires sudo for privileged ports (80, 443)"
    
    # Stop any existing tunnel
    pkill -f "minikube tunnel" 2>/dev/null || true
    sudo pkill -f "minikube tunnel" 2>/dev/null || true
    sleep 2
    
    # Start tunnel in background with sudo
    log_info "Starting minikube tunnel in background (requires sudo password)..."
    if sudo -n true 2>/dev/null; then
        # Sudo access available without password, start tunnel in background
        sudo -b minikube tunnel > /tmp/minikube-tunnel.log 2>&1
    else
        log_warn "Sudo password required for minikube tunnel"
        log_info "Starting minikube tunnel in background (you'll be prompted for sudo password)..."
        sudo -b minikube tunnel > /tmp/minikube-tunnel.log 2>&1
    fi
    
    # Wait for LoadBalancer to get an EXTERNAL-IP (with retries)
    log_info "Waiting for LoadBalancer to get EXTERNAL-IP..."
    local tunnel_wait=0
    local max_tunnel_wait=120  # Wait up to 2 minutes
    local tunnel_ready=false
    
    while [ $tunnel_wait -lt $max_tunnel_wait ]; do
        EXTERNAL_IP=$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
            log_info "✅ LoadBalancer EXTERNAL-IP assigned: $EXTERNAL_IP"
            tunnel_ready=true
            break
        fi
        
        # Check if tunnel process is still running
        if ! pgrep -f "minikube tunnel" > /dev/null && ! sudo pgrep -f "minikube tunnel" > /dev/null; then
            log_warn "minikube tunnel process not found, restarting..."
            sudo -b minikube tunnel > /tmp/minikube-tunnel.log 2>&1
            sleep 3
        fi
        
        sleep 5
        tunnel_wait=$((tunnel_wait + 5))
        if [ $((tunnel_wait % 15)) -eq 0 ]; then
            log_info "Still waiting for LoadBalancer EXTERNAL-IP... (${tunnel_wait}s/${max_tunnel_wait}s)"
        fi
    done
    
    if [ "$tunnel_ready" = true ]; then
        log_info "✅ minikube tunnel is working and LoadBalancer is ready"
    else
        log_warn "⚠️  LoadBalancer did not get EXTERNAL-IP within ${max_tunnel_wait}s"
        log_warn "   The tunnel may need more time or manual intervention"
        log_warn "   Check tunnel status: sudo pgrep -af 'minikube tunnel'"
        log_warn "   Or restart manually: sudo minikube tunnel"
    fi
}

install_postgres() {
    log_info "Installing PostgreSQL..."
    
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update
    
    # Create namespace if it doesn't exist
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    
    # Create PostgreSQL secret
    kubectl create secret generic postgres-secret \
        --from-literal=postgres-password=postgres123 \
        --from-literal=postgres-user=postgres \
        --from-literal=postgres-db=jenkins \
        -n $NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f -
    
    if helm list -n $NAMESPACE | grep -q postgresql; then
        log_warn "PostgreSQL already installed, upgrading..."
        helm upgrade postgresql bitnami/postgresql \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/postgres-values.yaml" \
            --wait \
            --timeout=10m
    else
        helm install postgresql bitnami/postgresql \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/postgres-values.yaml" \
            --wait \
            --timeout=10m
    fi
    
    log_info "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n $NAMESPACE --timeout=300s || true
    
    log_info "PostgreSQL installed successfully"
}

install_jenkins() {
    log_info "Installing Jenkins..."
    
    helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
    helm repo update
    
    # Check if Jenkins is in failed state and clean it up
    if helm list -n $NAMESPACE | grep -q jenkins; then
        HELM_STATUS=$(helm list -n $NAMESPACE | grep jenkins | awk '{print $8}')
        if [ "$HELM_STATUS" = "failed" ]; then
            log_warn "Jenkins installation is in failed state, cleaning up..."
            helm uninstall jenkins -n $NAMESPACE --ignore-not-found=true
            kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/name=jenkins --ignore-not-found=true
            sleep 5
        fi
    fi
    
    # Install or upgrade Jenkins
    if helm list -n $NAMESPACE | grep -q jenkins; then
        log_warn "Jenkins already installed, upgrading..."
        helm upgrade jenkins jenkins/jenkins \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/jenkins-values.yaml" \
            --timeout=15m || {
            log_error "Jenkins upgrade failed, trying fresh install..."
            helm uninstall jenkins -n $NAMESPACE --ignore-not-found=true
            kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/name=jenkins --ignore-not-found=true
            sleep 5
            helm install jenkins jenkins/jenkins \
                -n $NAMESPACE \
                -f "${SCRIPT_DIR}/helm/jenkins-values.yaml" \
                --timeout=15m
        }
    else
        helm install jenkins jenkins/jenkins \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/jenkins-values.yaml" \
            --timeout=15m || {
            log_error "Jenkins installation failed, retrying with clean state..."
            helm uninstall jenkins -n $NAMESPACE --ignore-not-found=true
            kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/name=jenkins --ignore-not-found=true
            sleep 5
            helm install jenkins jenkins/jenkins \
                -n $NAMESPACE \
                -f "${SCRIPT_DIR}/helm/jenkins-values.yaml" \
                --timeout=15m
        }
    fi
    
    log_info "Waiting for Jenkins pod to be ready..."
    local max_wait=600
    local waited=0
    while [ $waited -lt $max_wait ]; do
        POD_STATUS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/component=jenkins-master -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$POD_STATUS" = "Running" ]; then
            READY=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/component=jenkins-master -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [ "$READY" = "true" ]; then
                break
            fi
        fi
        if [ "$POD_STATUS" = "CrashLoopBackOff" ]; then
            log_warn "Jenkins pod is crashing, checking logs..."
            kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=jenkins-master --tail=20 | grep -i "error\|exception" | head -5
            log_error "Jenkins pod is in CrashLoopBackOff. Cleaning up and retrying..."
            helm uninstall jenkins -n $NAMESPACE --ignore-not-found=true
            kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/name=jenkins --ignore-not-found=true
            sleep 5
            helm install jenkins jenkins/jenkins \
                -n $NAMESPACE \
                -f "${SCRIPT_DIR}/helm/jenkins-values.yaml" \
                --timeout=15m
            waited=0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=jenkins-master -n $NAMESPACE --timeout=300s || {
        log_error "Jenkins pod did not become ready"
        kubectl get pods -n $NAMESPACE | grep jenkins
        return 1
    }
    
    # Wait for Jenkins service to exist
    log_info "Waiting for Jenkins service to be created..."
    local svc_wait=0
    while [ $svc_wait -lt 60 ]; do
        if kubectl get svc -n $NAMESPACE jenkins &>/dev/null; then
            break
        fi
        sleep 2
        svc_wait=$((svc_wait + 2))
    done
    
    if ! kubectl get svc -n $NAMESPACE jenkins &>/dev/null; then
        log_error "Jenkins service was not created"
        return 1
    fi
    
    # Get Jenkins admin password
    sleep 10
    JENKINS_PASSWORD=$(kubectl get secret --namespace $NAMESPACE jenkins -o jsonpath="{.data.jenkins-admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -n "$JENKINS_PASSWORD" ]; then
        echo ""
        log_info "Jenkins admin password: $JENKINS_PASSWORD"
        echo "$JENKINS_PASSWORD" > "${SCRIPT_DIR}/.jenkins-password"
        chmod 600 "${SCRIPT_DIR}/.jenkins-password"
    fi
    
    log_info "Jenkins installed successfully"
}

configure_jenkins_jobs() {
    log_info "Configuring Jenkins jobs using Job DSL..."
    
    # Wait for Jenkins to be fully ready
    log_info "Waiting for Jenkins API to be available..."
    local max_attempts=30
    local attempt=0
    JENKINS_POD=""
    
    while [ $attempt -lt $max_attempts ]; do
        JENKINS_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=jenkins-master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$JENKINS_POD" ]; then
            # Check if pod is actually running
            POD_STATUS=$(kubectl get pod $JENKINS_POD -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$POD_STATUS" = "Running" ]; then
                break
            fi
        fi
        sleep 10
        attempt=$((attempt + 1))
    done
    
    if [ -z "$JENKINS_POD" ]; then
        log_error "Jenkins pod not found or not running"
        return 1
    fi
    
    # Wait for Jenkins to be ready
    kubectl wait --for=condition=ready pod/$JENKINS_POD -n $NAMESPACE --timeout=300s || true
    
    # Wait additional time for Jenkins to fully start
    log_info "Waiting for Jenkins to be fully initialized..."
    sleep 30
    
    # Get admin password
    JENKINS_PASSWORD=$(kubectl get secret --namespace $NAMESPACE jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode)
    JENKINS_USER="admin"
    JENKINS_URL="http://localhost:8080"
    
    # Configure Jenkins root URL for proper asset loading and redirects
    log_info "Configuring Jenkins root URL for path-based access..."
    
    # Method 1: Update config.xml directly
    kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- bash -c "
        if [ -f /var/jenkins_home/config.xml ]; then
            # Backup original config
            cp /var/jenkins_home/config.xml /var/jenkins_home/config.xml.bak
            
            # Remove existing rootUrl if present
            sed -i '/<rootUrl>/d' /var/jenkins_home/config.xml
            
            # Add rootUrl after <jenkins> tag (with proper indentation)
            sed -i 's|<jenkins>|<jenkins>\n  <rootUrl>http://127.0.0.1/jenkins/</rootUrl>|' /var/jenkins_home/config.xml
        fi
    " 2>/dev/null || true
    
    # Method 2: Also configure via Jenkins API (more reliable for redirects)
    log_info "Configuring root URL via Jenkins API..."
    local max_config_attempts=10
    local config_attempt=0
    while [ $config_attempt -lt $max_config_attempts ]; do
        # Get Jenkins crumb for CSRF protection
        CRUMB=$(kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- curl -s -u "$JENKINS_USER:$JENKINS_PASSWORD" "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null | tr -d '\r\n' || echo "")
        
        if [ -n "$CRUMB" ]; then
            # Configure root URL via API
            RESPONSE=$(kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- curl -s -w "%{http_code}" -X POST \
                -u "$JENKINS_USER:$JENKINS_PASSWORD" \
                -H "$CRUMB" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                --data-urlencode "jenkins.model.JenkinsLocationConfiguration.rootUrl=http://127.0.0.1/jenkins/" \
                --data-urlencode "json={\"jenkins.model.JenkinsLocationConfiguration.rootUrl\":\"http://127.0.0.1/jenkins/\"}" \
                "$JENKINS_URL/configurationSubmit" 2>/dev/null || echo "000")
            
            HTTP_CODE=$(echo "$RESPONSE" | tail -1)
            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
                log_info "Jenkins root URL configured successfully via API"
                break
            fi
        fi
        sleep 3
        config_attempt=$((config_attempt + 1))
    done
    
    # Reload Jenkins configuration to apply changes
    sleep 5
    kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- curl -s -X POST -u "$JENKINS_USER:$JENKINS_PASSWORD" "$JENKINS_URL/reload" >/dev/null 2>&1 || true
    sleep 15
    
    # Copy DSL script to Jenkins pod
    log_info "Copying Job DSL script to Jenkins pod..."
    kubectl cp "${SCRIPT_DIR}/jenkins/job-dsl.groovy" "$NAMESPACE/$JENKINS_POD:/var/jenkins_home/job-dsl.groovy" -c jenkins 2>/dev/null || {
        log_warn "kubectl cp failed, trying alternative method..."
        # Alternative: Use exec with cat
        cat "${SCRIPT_DIR}/jenkins/job-dsl.groovy" | kubectl exec -i -n $NAMESPACE $JENKINS_POD -c jenkins -- bash -c "cat > /var/jenkins_home/job-dsl.groovy" 2>/dev/null || true
    }
    
    # Verify DSL script was copied
    if kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- test -f /var/jenkins_home/job-dsl.groovy 2>/dev/null; then
        log_info "DSL script copied successfully"
    else
        log_error "Failed to copy DSL script"
        return 1
    fi
    
    # Create a seed job that will execute the Job DSL script
    log_info "Creating seed job to execute Job DSL..."
    
    # Create seed job XML that uses Job DSL plugin
    SEED_JOB_XML=$(cat <<'SEEDXML'
<?xml version='1.1' encoding='UTF-8'?>
<project>
  <actions/>
  <description>Seed job to create other jobs using Job DSL</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.scm.NullSCM"/>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <javaposse.jobdsl.plugin.ExecuteDslScripts plugin="job-dsl@1.77">
      <targets>job-dsl.groovy</targets>
      <usingScriptText>false</usingScriptText>
      <sandbox>false</sandbox>
      <ignoreExisting>false</ignoreExisting>
      <ignoreMissingFiles>false</ignoreMissingFiles>
      <failOnMissingPlugin>false</failOnMissingPlugin>
      <failOnSeedCollision>false</failOnSeedCollision>
      <unstableOnDeprecation>false</unstableOnDeprecation>
      <removedJobAction>DELETE</removedJobAction>
      <removedViewAction>DELETE</removedViewAction>
      <removedConfigFilesAction>IGNORE</removedConfigFilesAction>
      <lookupStrategy>JENKINS_ROOT</lookupStrategy>
    </javaposse.jobdsl.plugin.ExecuteDslScripts>
  </builders>
  <publishers/>
  <buildWrappers/>
</project>
SEEDXML
)
    
    # Create seed job using direct XML method (more reliable)
    log_info "Creating seed job directory and config..."
    
    # Create directory structure
    kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- bash -c "
        mkdir -p /var/jenkins_home/jobs/seed-job
        chown -R jenkins:jenkins /var/jenkins_home/jobs/seed-job
    " 2>/dev/null || true
    
    # Write seed job config using a temporary file
    TEMP_XML=$(mktemp)
    echo "$SEED_JOB_XML" > "$TEMP_XML"
    kubectl cp "$TEMP_XML" "$NAMESPACE/$JENKINS_POD:/var/jenkins_home/jobs/seed-job/config.xml" -c jenkins 2>/dev/null || {
        # Fallback: use exec with heredoc
        kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- bash -c "cat > /var/jenkins_home/jobs/seed-job/config.xml" <<'EOFXML'
$(echo "$SEED_JOB_XML")
EOFXML
    }
    rm -f "$TEMP_XML"
    
    # Set proper permissions
    kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- chown -R jenkins:jenkins /var/jenkins_home/jobs/seed-job 2>/dev/null || true
    
    # Reload Jenkins configuration to pick up the new job
    log_info "Reloading Jenkins configuration to register seed job..."
    kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- curl -s -X POST -u "$JENKINS_USER:$JENKINS_PASSWORD" "$JENKINS_URL/reload" >/dev/null 2>&1 || true
    sleep 15
    
    # Verify seed job exists
    if kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- test -f /var/jenkins_home/jobs/seed-job/config.xml 2>/dev/null; then
        log_info "Seed job created successfully"
    else
        log_error "Failed to create seed job"
        return 1
    fi
    
    # Build the seed job to execute the DSL script
    log_info "Building seed job to create k8s-worker-job..."
    local build_attempt=0
    while [ $build_attempt -lt 5 ]; do
        BUILD_RESULT=$(kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- curl -s -w "%{http_code}" -X POST \
            -u "$JENKINS_USER:$JENKINS_PASSWORD" \
            "$JENKINS_URL/job/seed-job/build" 2>/dev/null || echo "000")
        
        HTTP_CODE=$(echo "$BUILD_RESULT" | tail -1)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "302" ]; then
            log_info "Seed job build triggered successfully"
            break
        fi
        sleep 5
        build_attempt=$((build_attempt + 1))
    done
    
    # Wait for seed job to complete and create k8s-worker-job
    log_info "Waiting for seed job to complete and create k8s-worker-job..."
    sleep 30
    
    # Verify k8s-worker-job was created
    if kubectl exec -n $NAMESPACE $JENKINS_POD -c jenkins -- test -d /var/jenkins_home/jobs/k8s-worker-job 2>/dev/null; then
        log_info "✅ k8s-worker-job created successfully by Job DSL"
    else
        log_warn "k8s-worker-job not found yet, it may be created on the next seed job run"
    fi
    
    # Wait a bit for the job to be created
    sleep 10
    
    log_info "Jenkins job 'k8s-worker-job' should be created via Job DSL"
    log_info "The job will run every 5 minutes on Kubernetes worker pods"
}

install_grafana() {
    log_info "Installing Grafana..."
    
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update
    
    if helm list -n $NAMESPACE | grep -q grafana; then
        log_warn "Grafana already installed, upgrading..."
        helm upgrade grafana grafana/grafana \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/grafana-values.yaml" \
            --timeout=10m || {
            log_error "Grafana upgrade failed, trying fresh install..."
            helm uninstall grafana -n $NAMESPACE --ignore-not-found=true
            sleep 5
            helm install grafana grafana/grafana \
                -n $NAMESPACE \
                -f "${SCRIPT_DIR}/helm/grafana-values.yaml" \
                --timeout=10m
        }
    else
        helm install grafana grafana/grafana \
            -n $NAMESPACE \
            -f "${SCRIPT_DIR}/helm/grafana-values.yaml" \
            --timeout=10m || {
            log_error "Grafana installation failed, retrying..."
            helm uninstall grafana -n $NAMESPACE --ignore-not-found=true
            sleep 5
            helm install grafana grafana/grafana \
                -n $NAMESPACE \
                -f "${SCRIPT_DIR}/helm/grafana-values.yaml" \
                --timeout=10m
        }
    fi
    
    log_info "Waiting for Grafana to be ready..."
    local grafana_wait=0
    local max_grafana_wait=600  # 10 minutes
    local grafana_ready=false
    
    while [ $grafana_wait -lt $max_grafana_wait ]; do
        POD_STATUS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
        INIT_STATUS=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.initContainerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
        
        if [ "$POD_STATUS" = "Running" ]; then
            READY=$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [ "$READY" = "true" ]; then
                grafana_ready=true
                break
            fi
        fi
        
        # Check for init container failures
        if [ "$INIT_STATUS" = "CrashLoopBackOff" ] || [ "$INIT_STATUS" = "Error" ]; then
            log_warn "Grafana init container is failing, attempting to fix..."
            GRAFANA_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            
            if [ -n "$GRAFANA_POD" ]; then
                # Delete the pod to restart, or delete PVC if persistent issue
                if [ $grafana_wait -gt 300 ]; then
                    log_warn "Init container still failing after 5 minutes, cleaning up PVC and retrying..."
                    helm uninstall grafana -n $NAMESPACE --ignore-not-found=true
                    kubectl delete pvc -n $NAMESPACE -l app.kubernetes.io/name=grafana --ignore-not-found=true
                    sleep 5
                    helm install grafana grafana/grafana \
                        -n $NAMESPACE \
                        -f "${SCRIPT_DIR}/helm/grafana-values.yaml" \
                        --timeout=10m
                    grafana_wait=0  # Reset wait counter
                else
                    log_info "Deleting pod to restart..."
                    kubectl delete pod -n $NAMESPACE $GRAFANA_POD --ignore-not-found=true
                    sleep 10
                fi
            fi
        fi
        
        sleep 10
        grafana_wait=$((grafana_wait + 10))
        if [ $((grafana_wait % 60)) -eq 0 ]; then
            log_info "Still waiting for Grafana... (${grafana_wait}s/${max_grafana_wait}s)"
            kubectl get pods -n $NAMESPACE | grep grafana || true
        fi
    done
    
    if [ "$grafana_ready" = true ]; then
        log_info "✅ Grafana is ready"
    else
        log_error "Grafana pod did not become ready within ${max_grafana_wait}s"
        kubectl get pods -n $NAMESPACE | grep grafana
        kubectl describe pod -n $NAMESPACE -l app.kubernetes.io/name=grafana | tail -30
        return 1
    fi
    
    # Wait for Grafana service to exist
    log_info "Waiting for Grafana service to be created..."
    local svc_wait=0
    while [ $svc_wait -lt 60 ]; do
        if kubectl get svc -n $NAMESPACE grafana &>/dev/null; then
            break
        fi
        sleep 2
        svc_wait=$((svc_wait + 2))
    done
    
    if ! kubectl get svc -n $NAMESPACE grafana &>/dev/null; then
        log_error "Grafana service was not created"
        return 1
    fi
    
    # Get Grafana admin password
    sleep 5
    GRAFANA_PASSWORD=$(kubectl get secret --namespace $NAMESPACE grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -n "$GRAFANA_PASSWORD" ]; then
        echo ""
        log_info "Grafana admin password: $GRAFANA_PASSWORD"
        echo "$GRAFANA_PASSWORD" > "${SCRIPT_DIR}/.grafana-password"
        chmod 600 "${SCRIPT_DIR}/.grafana-password"
    fi
    
    log_info "Grafana installed successfully"
}

configure_grafana_dashboards() {
    log_info "Configuring Grafana dashboards with Terraform..."
    
    # Wait for Grafana to be fully ready and accessible
    log_info "Waiting for Grafana API to be accessible..."
    local grafana_api_wait=0
    local max_grafana_api_wait=180  # 3 minutes
    local grafana_ready=false
    
    GRAFANA_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    while [ $grafana_api_wait -lt $max_grafana_api_wait ]; do
        if [ -n "$GRAFANA_POD" ]; then
            # Check if Grafana API is responding
            API_RESPONSE=$(kubectl exec -n $NAMESPACE $GRAFANA_POD -- curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health 2>/dev/null || echo "000")
            if [ "$API_RESPONSE" = "200" ]; then
                log_info "✅ Grafana API is ready"
                grafana_ready=true
                break
            fi
        fi
        sleep 5
        grafana_api_wait=$((grafana_api_wait + 5))
        if [ $((grafana_api_wait % 30)) -eq 0 ]; then
            log_info "Still waiting for Grafana API... (${grafana_api_wait}s/${max_grafana_api_wait}s)"
        fi
    done
    
    if [ "$grafana_ready" != true ]; then
        log_warn "Grafana API not ready within ${max_grafana_api_wait}s, skipping Terraform configuration"
        log_warn "You can configure Grafana dashboards manually via the UI"
        return 0
    fi
    
    cd "${SCRIPT_DIR}/terraform"
    
    # Initialize Terraform
    terraform init -upgrade
    
    # Get Grafana credentials
    GRAFANA_PASSWORD=$(kubectl get secret --namespace $NAMESPACE grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode || echo "admin123")
    
    # Terraform runs from host machine, so we need port-forward to access Grafana service
    # Start port-forward in background for Terraform
    log_info "Starting port-forward for Terraform to access Grafana..."
    pkill -f "port-forward.*grafana" 2>/dev/null || true
    kubectl port-forward -n $NAMESPACE svc/grafana 3000:80 > /tmp/grafana-portforward.log 2>&1 &
    PORTFORWARD_PID=$!
    sleep 5
    
    # Verify port-forward is working
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health 2>/dev/null | grep -q "200"; then
        log_info "✅ Port-forward is working"
        GRAFANA_URL="http://localhost:3000"
    else
        log_warn "Port-forward may not be ready, waiting a bit more..."
        sleep 5
        GRAFANA_URL="http://localhost:3000"
    fi
    
    # Apply Terraform configuration with retries
    log_info "Applying Terraform configuration..."
    local terraform_attempt=0
    local max_terraform_attempts=3
    
    while [ $terraform_attempt -lt $max_terraform_attempts ]; do
        if terraform apply -auto-approve \
            -var="grafana_url=${GRAFANA_URL}" \
            -var="grafana_username=admin" \
            -var="grafana_password=${GRAFANA_PASSWORD}" \
            -var="postgres_host=postgresql.${NAMESPACE}.svc.cluster.local" \
            -var="postgres_port=5432" \
            -var="postgres_database=jenkins" \
            -var="postgres_user=postgres" \
            -var="postgres_password=postgres123" 2>&1; then
            log_info "✅ Grafana dashboards configured successfully"
            break
        else
            terraform_attempt=$((terraform_attempt + 1))
            if [ $terraform_attempt -lt $max_terraform_attempts ]; then
                log_warn "Terraform apply failed, retrying... (attempt ${terraform_attempt}/${max_terraform_attempts})"
                sleep 10
            else
                log_error "Terraform apply failed after ${max_terraform_attempts} attempts"
                log_warn "You can configure Grafana dashboards manually via the UI"
            fi
        fi
    done
    
    cd "${SCRIPT_DIR}"
    
    # Clean up port-forward
    if [ -n "$PORTFORWARD_PID" ]; then
        kill $PORTFORWARD_PID 2>/dev/null || true
        pkill -f "port-forward.*grafana" 2>/dev/null || true
        log_info "Stopped Grafana port-forward"
    fi
}

create_ingress() {
    log_info "Creating Ingress resources..."
    
    # Ensure services exist before creating ingress
    log_info "Verifying services exist..."
    local max_wait=120
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if kubectl get svc -n $NAMESPACE jenkins &>/dev/null && \
           kubectl get svc -n $NAMESPACE grafana &>/dev/null; then
            break
        fi
        log_info "Waiting for services to be created..."
        sleep 5
        waited=$((waited + 5))
    done
    
    if ! kubectl get svc -n $NAMESPACE jenkins &>/dev/null; then
        log_error "Jenkins service not found, cannot create ingress"
        return 1
    fi
    
    if ! kubectl get svc -n $NAMESPACE grafana &>/dev/null; then
        log_error "Grafana service not found, cannot create ingress"
        return 1
    fi
    
    # Create IngressRoute resources (preferred for Traefik)
    log_info "Creating IngressRoute resources for Traefik..."
    kubectl apply -f "${SCRIPT_DIR}/k8s/ingressroute.yaml" || {
        log_error "Failed to create IngressRoute resources"
        return 1
    }
    
    # Also create standard Ingress as fallback
    kubectl apply -f "${SCRIPT_DIR}/k8s/ingress.yaml" -n $NAMESPACE 2>/dev/null || true
    
    log_info "Waiting for Ingress to be ready..."
    sleep 10
    
    # Verify LoadBalancer is ready before creating routes
    log_info "Verifying LoadBalancer is ready..."
    local lb_wait=0
    local max_lb_wait=60
    while [ $lb_wait -lt $max_lb_wait ]; do
        EXTERNAL_IP=$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
            log_info "✅ LoadBalancer is ready with EXTERNAL-IP: $EXTERNAL_IP"
            break
        fi
        sleep 5
        lb_wait=$((lb_wait + 5))
        if [ $((lb_wait % 15)) -eq 0 ]; then
            log_info "Waiting for LoadBalancer EXTERNAL-IP... (${lb_wait}s/${max_lb_wait}s)"
        fi
    done
    
    # Verify ingress routes are working
    log_info "Verifying ingress routes..."
    local verify_wait=0
    while [ $verify_wait -lt 60 ]; do
        if kubectl get ingressroute -n $NAMESPACE jenkins-route &>/dev/null && \
           kubectl get ingressroute -n $NAMESPACE grafana-route &>/dev/null; then
            # Check if Traefik can see the services
            TRAEFIK_ERRORS=$(kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=10 2>/dev/null | grep -i "service not found.*jenkins\|service not found.*grafana" | wc -l)
            if [ "$TRAEFIK_ERRORS" -eq 0 ]; then
                log_info "Ingress routes verified successfully"
                break
            else
                log_warn "Traefik still seeing service errors, waiting for refresh..."
            fi
        fi
        sleep 5
        verify_wait=$((verify_wait + 5))
    done
    
    # If still errors, recreate the routes
    if [ $verify_wait -ge 60 ]; then
        log_warn "Ingress routes may have issues, recreating..."
        kubectl delete ingressroute -n $NAMESPACE jenkins-route grafana-route --ignore-not-found=true
        sleep 3
        kubectl apply -f "${SCRIPT_DIR}/k8s/ingressroute.yaml"
        sleep 5
    fi
    
    # Get Minikube IP
    MINIKUBE_IP=$(minikube ip)
    
    log_info "Ingress created successfully"
    echo ""
    log_info "========================================="
    log_info "ACCESS CREDENTIALS"
    log_info "========================================="
    echo ""
    
    # Get Jenkins credentials
    JENKINS_PASSWORD=$(kubectl get secret --namespace $NAMESPACE jenkins -o jsonpath="{.data.jenkins-admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -z "$JENKINS_PASSWORD" ] && [ -f "${SCRIPT_DIR}/.jenkins-password" ]; then
        JENKINS_PASSWORD=$(cat "${SCRIPT_DIR}/.jenkins-password")
    fi
    
    # Get Grafana credentials
    GRAFANA_PASSWORD=$(kubectl get secret --namespace $NAMESPACE grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -z "$GRAFANA_PASSWORD" ] && [ -f "${SCRIPT_DIR}/.grafana-password" ]; then
        GRAFANA_PASSWORD=$(cat "${SCRIPT_DIR}/.grafana-password")
    fi
    
    log_info "Jenkins:"
    log_info "  URL:      http://127.0.0.1/jenkins"
    log_info "  Username: admin"
    if [ -n "$JENKINS_PASSWORD" ]; then
        log_info "  Password: $JENKINS_PASSWORD"
    else
        log_warn "  Password: (not found, check .jenkins-password file)"
    fi
    echo ""
    
    log_info "Grafana:"
    log_info "  URL:      http://127.0.0.1/grafana"
    log_info "  Username: admin"
    if [ -n "$GRAFANA_PASSWORD" ]; then
        log_info "  Password: $GRAFANA_PASSWORD"
    else
        log_warn "  Password: (not found, check .grafana-password file)"
    fi
    echo ""
    
    log_info "PostgreSQL:"
    log_info "  Host:     postgresql.${NAMESPACE}.svc.cluster.local"
    log_info "  Port:     5432"
    log_info "  Database: jenkins"
    log_info "  Username: postgres"
    log_info "  Password: postgres123"
    echo ""
    
    log_info "========================================="
    log_info "IMPORTANT NOTES"
    log_info "========================================="
    log_info "1. Access requires minikube tunnel to be running"
    log_info "   Start it with: sudo minikube tunnel"
    log_info ""
    log_info "2. All access is via Ingress (no NodePort usage)"
    log_info "   Path-based routing: /jenkins and /grafana"
    log_info ""
    if [ -f "${SCRIPT_DIR}/.jenkins-password" ]; then
        log_info "3. Jenkins password saved to: .jenkins-password"
    fi
    if [ -f "${SCRIPT_DIR}/.grafana-password" ]; then
        log_info "4. Grafana password saved to: .grafana-password"
    fi
    echo ""
}

uninstall_all() {
    log_info "Uninstalling all components..."
    
    # Stop minikube tunnel
    pkill -f "minikube tunnel" 2>/dev/null || true
    sudo pkill -f "minikube tunnel" 2>/dev/null || true
    
    # Delete ingress and IngressRoute resources
    kubectl delete -f "${SCRIPT_DIR}/k8s/ingress.yaml" -n $NAMESPACE --ignore-not-found=true
    kubectl delete ingressroute -n $NAMESPACE --all --ignore-not-found=true
    kubectl delete middleware -n $NAMESPACE --all --ignore-not-found=true
    
    # Uninstall Helm releases
    helm uninstall grafana -n $NAMESPACE --ignore-not-found=true
    helm uninstall jenkins -n $NAMESPACE --ignore-not-found=true
    helm uninstall postgresql -n $NAMESPACE --ignore-not-found=true
    helm uninstall traefik -n kube-system --ignore-not-found=true
    
    # Clean up Terraform
    if [ -d "${SCRIPT_DIR}/terraform" ] && [ -f "${SCRIPT_DIR}/terraform/terraform.tfstate" ]; then
        cd "${SCRIPT_DIR}/terraform"
        terraform destroy -auto-approve -var="grafana_url=http://localhost" -var="grafana_username=admin" -var="grafana_password=admin" 2>/dev/null || true
        cd "${SCRIPT_DIR}"
    fi
    
    # Delete namespace
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    
    # Clean up password files
    rm -f "${SCRIPT_DIR}/.jenkins-password" "${SCRIPT_DIR}/.grafana-password"
    
    log_info "All components uninstalled"
}

print_status() {
    log_info "Current deployment status:"
    echo ""
    kubectl get pods -n $NAMESPACE 2>/dev/null || echo "No pods in monitoring namespace"
    echo ""
    kubectl get ingressroute -n $NAMESPACE 2>/dev/null || echo "No ingress routes in monitoring namespace"
    echo ""
    
    # Print credentials
    echo ""
    log_info "========================================="
    log_info "ACCESS CREDENTIALS"
    log_info "========================================="
    echo ""
    
    # Get Jenkins credentials
    JENKINS_PASSWORD=$(kubectl get secret --namespace $NAMESPACE jenkins -o jsonpath="{.data.jenkins-admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -z "$JENKINS_PASSWORD" ] && [ -f "${SCRIPT_DIR}/.jenkins-password" ]; then
        JENKINS_PASSWORD=$(cat "${SCRIPT_DIR}/.jenkins-password")
    fi
    
    # Get Grafana credentials
    GRAFANA_PASSWORD=$(kubectl get secret --namespace $NAMESPACE grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode || echo "")
    if [ -z "$GRAFANA_PASSWORD" ] && [ -f "${SCRIPT_DIR}/.grafana-password" ]; then
        GRAFANA_PASSWORD=$(cat "${SCRIPT_DIR}/.grafana-password")
    fi
    
    log_info "Jenkins:"
    log_info "  URL:      http://127.0.0.1/jenkins"
    log_info "  Username: admin"
    if [ -n "$JENKINS_PASSWORD" ]; then
        log_info "  Password: $JENKINS_PASSWORD"
    else
        log_warn "  Password: (not found, check .jenkins-password file)"
    fi
    echo ""
    
    log_info "Grafana:"
    log_info "  URL:      http://127.0.0.1/grafana"
    log_info "  Username: admin"
    if [ -n "$GRAFANA_PASSWORD" ]; then
        log_info "  Password: $GRAFANA_PASSWORD"
    else
        log_warn "  Password: (not found, check .grafana-password file)"
    fi
    echo ""
    
    log_info "PostgreSQL:"
    log_info "  Host:     postgresql.${NAMESPACE}.svc.cluster.local"
    log_info "  Port:     5432"
    log_info "  Database: jenkins"
    log_info "  Username: postgres"
    log_info "  Password: postgres123"
    echo ""
}

# Main script logic
case "${1:-}" in
    install)
        check_dependencies
        setup_minikube
        install_traefik
        install_postgres
        install_jenkins
        configure_jenkins_jobs
        install_grafana
        configure_grafana_dashboards
        create_ingress
        
        # Final verification: Check LoadBalancer status
        log_info "Performing final verification..."
        EXTERNAL_IP=$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
            log_info "✅ LoadBalancer is ready: $EXTERNAL_IP"
        else
            log_warn "⚠️  LoadBalancer EXTERNAL-IP not assigned yet"
            log_warn "   This may take a few more minutes. Check with: kubectl get svc -n kube-system traefik"
            log_warn "   If needed, restart tunnel: sudo minikube tunnel"
        fi
        
        print_status
        log_info "Installation completed successfully!"
        ;;
    uninstall)
        uninstall_all
        log_info "Uninstallation completed!"
        ;;
    status)
        print_status
        ;;
    *)
        echo "Usage: $0 {install|uninstall|status}"
        echo ""
        echo "  install   - Install all components"
        echo "  uninstall - Remove all components"
        echo "  status    - Show current deployment status"
        exit 1
        ;;
esac

