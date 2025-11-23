// Jenkins Job DSL Script
// Creates a job that runs every 5 minutes and launches dynamic Kubernetes worker pods
// These pods record the current date and time into the PostgreSQL database

// Create the main job
job('k8s-worker-job') {
    description('Job that runs every 5 minutes and launches dynamic Kubernetes worker pods to record timestamps in PostgreSQL')
    
    // Schedule to run every 5 minutes
    triggers {
        cron('*/5 * * * *')
    }
    
    // Configure to run on Kubernetes agents
    label('kubernetes')
    
    steps {
        shell('''#!/bin/bash
set -e

echo "========================================="
echo "Kubernetes Worker Pod - Timestamp Recorder"
echo "========================================="
echo "Pod Name: $HOSTNAME"
echo "Node: $(hostname)"
echo "Date: $(date)"
echo "========================================="

# Install PostgreSQL client if not available
if ! command -v psql &> /dev/null; then
    echo "Installing PostgreSQL client..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y postgresql-client
    elif [ -f /etc/redhat-release ]; then
        yum install -y postgresql
    elif [ -f /etc/alpine-release ]; then
        apk add --no-cache postgresql-client
    fi
fi

# Database connection details
DB_HOST="postgresql.monitoring.svc.cluster.local"
DB_PORT="5432"
DB_NAME="jenkins"
DB_USER="postgres"
DB_PASSWORD="postgres123"

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL connection..."
until PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT 1" &> /dev/null; do
    echo "Waiting for PostgreSQL..."
    sleep 2
done

# Create table if it doesn't exist
echo "Creating table if needed..."
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME <<EOF
CREATE TABLE IF NOT EXISTS job_timestamps (
    id SERIAL PRIMARY KEY,
    pod_name VARCHAR(255) NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    job_name VARCHAR(255),
    build_number INTEGER
);
EOF

# Insert current timestamp
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BUILD_NUMBER=${BUILD_NUMBER:-0}
JOB_NAME=${JOB_NAME:-k8s-worker-job}

echo "Inserting timestamp record..."
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME <<EOF
INSERT INTO job_timestamps (pod_name, timestamp, job_name, build_number)
VALUES ('$HOSTNAME', '$CURRENT_TIME', '$JOB_NAME', $BUILD_NUMBER);
EOF

# Display inserted record
echo ""
echo "Recorded timestamp:"
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "SELECT * FROM job_timestamps ORDER BY id DESC LIMIT 5;"

echo ""
echo "========================================="
echo "Job completed successfully!"
echo "========================================="
''')
    }
    
    publishers {
        // Archive artifacts if needed
    }
    
    wrappers {
        timestamper()
        colorizeOutput()
    }
}

