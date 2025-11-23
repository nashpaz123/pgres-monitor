terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 2.0"
    }
  }
}

variable "grafana_url" {
  description = "Grafana URL"
  type        = string
  default     = "http://grafana.monitoring.svc.cluster.local:80"
}

variable "grafana_username" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "postgres_host" {
  description = "PostgreSQL host"
  type        = string
}

variable "postgres_port" {
  description = "PostgreSQL port"
  type        = string
  default     = "5432"
}

variable "postgres_database" {
  description = "PostgreSQL database name"
  type        = string
}

variable "postgres_user" {
  description = "PostgreSQL username"
  type        = string
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

provider "grafana" {
  url      = var.grafana_url
  auth     = "${var.grafana_username}:${var.grafana_password}"
  org_id   = 1
}

# PostgreSQL Data Source
resource "grafana_data_source" "postgresql" {
  type = "postgres"
  name = "PostgreSQL"
  url  = "${var.postgres_host}:${var.postgres_port}"
  
  json_data_encoded = jsonencode({
    databaseName = var.postgres_database
    sslMode      = "disable"
    postgresVersion = 1300
    timescaledb   = false
  })
  
  secure_json_data_encoded = jsonencode({
    password = var.postgres_password
  })
  
  basic_auth_enabled  = true
  basic_auth_username = var.postgres_user
}

# PostgreSQL Monitoring Dashboard
resource "grafana_dashboard" "postgresql_monitoring" {
  config_json = jsonencode({
    title       = "PostgreSQL Monitoring"
    description = "PostgreSQL database performance metrics including CPU, memory, and throughput"
    tags        = ["postgresql", "database", "monitoring"]
    timezone    = "browser"
    refresh     = "30s"
    time        = {
      from = "now-1h"
      to   = "now"
    }
    
    panels = [
        {
          id    = 1
          title = "Job Execution Rate"
          type  = "graph"
          gridPos = {
            h = 8
            w = 12
            x = 0
            y = 0
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = <<-SQL
                SELECT
                  DATE_TRUNC('minute', timestamp) as time,
                  COUNT(*) as jobs_per_minute
                FROM job_timestamps
                WHERE timestamp > NOW() - INTERVAL '1 hour'
                GROUP BY DATE_TRUNC('minute', timestamp)
                ORDER BY time
              SQL
              format = "time_series"
            }
          ]
        },
        {
          id    = 2
          title = "Recent Job Timestamps"
          type  = "table"
          gridPos = {
            h = 8
            w = 12
            x = 12
            y = 0
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = <<-SQL
                SELECT
                  id,
                  pod_name,
                  timestamp,
                  job_name,
                  build_number
                FROM job_timestamps
                ORDER BY timestamp DESC
                LIMIT 100
              SQL
              format = "table"
            }
          ]
        },
        {
          id    = 3
          title = "Total Records"
          type  = "stat"
          gridPos = {
            h = 4
            w = 6
            x = 0
            y = 8
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = "SELECT COUNT(*) as total FROM job_timestamps"
              format = "table"
            }
          ]
        },
        {
          id    = 4
          title = "Records Last Hour"
          type  = "stat"
          gridPos = {
            h = 4
            w = 6
            x = 6
            y = 8
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = "SELECT COUNT(*) as total FROM job_timestamps WHERE timestamp > NOW() - INTERVAL '1 hour'"
              format = "table"
            }
          ]
        },
        {
          id    = 5
          title = "Unique Pods"
          type  = "stat"
          gridPos = {
            h = 4
            w = 6
            x = 12
            y = 8
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = "SELECT COUNT(DISTINCT pod_name) as unique_pods FROM job_timestamps"
              format = "table"
            }
          ]
        },
        {
          id    = 6
          title = "Average Jobs Per Minute"
          type  = "stat"
          gridPos = {
            h = 4
            w = 6
            x = 18
            y = 8
          }
          targets = [
            {
              datasource = {
                type = "postgres"
                uid  = grafana_data_source.postgresql.uid
              }
              rawSql = <<-SQL
                SELECT
                  COUNT(*) / 60.0 as avg_per_minute
                FROM job_timestamps
                WHERE timestamp > NOW() - INTERVAL '1 hour'
              SQL
              format = "table"
            }
          ]
        }
      ]
  })
}

