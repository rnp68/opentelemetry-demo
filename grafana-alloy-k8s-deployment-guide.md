# Deploying Grafana Alloy in Kubernetes Clusters

## What is Grafana Alloy?

Grafana Alloy is an OpenTelemetry Collector distribution with Prometheus pipelines that serves as a comprehensive telemetry collection agent. It can collect, process, and forward metrics, logs, traces, and profiling data to Grafana Cloud or other observability backends.

## Deployment Methods

### 1. Helm Chart Installation (Recommended)

The preferred method to deploy Alloy in Kubernetes is using the official Grafana Helm chart.

#### Prerequisites
- Helm installed on your system
- Kubernetes cluster access
- kubectl configured for your cluster

#### Basic Installation Steps

```bash
# Add the Grafana Helm repository
helm repo add grafana https://grafana.github.io/helm-charts

# Update repository
helm repo update

# Create namespace
kubectl create namespace alloy

# Install Alloy
helm install alloy grafana/alloy --namespace alloy
```

#### Verify Installation

```bash
# Check pod status
kubectl get pods --namespace alloy

# View Alloy logs
kubectl logs -f deployment/alloy --namespace alloy
```

### 2. Kubernetes Monitoring Helm Chart

For comprehensive Kubernetes monitoring, use the `k8s-monitoring` Helm chart which deploys specialized Alloy instances:

```bash
# Install complete monitoring stack
helm install k8s-monitoring grafana/k8s-monitoring -n monitoring --create-namespace
```

This deploys multiple Alloy instances optimized for different roles:
- `alloy-metrics`: Collects Prometheus metrics
- `alloy-logs`: Collects Kubernetes logs
- `alloy-profiles`: Collects continuous profiling data
- `alloy-receiver`: Receives OpenTelemetry data

## Configuration Methods

### Method 1: Inline Configuration in values.yaml

```yaml
alloy:
  configMap:
    content: |-
      logging {
        level = "info"
        format = "logfmt"
      }
      
      prometheus.scrape "kubernetes_pods" {
        targets = discovery.kubernetes.pods.targets
        forward_to = [prometheus.remote_write.grafana_cloud.receiver]
      }
      
      discovery.kubernetes "pods" {
        role = "pod"
      }
      
      prometheus.remote_write "grafana_cloud" {
        endpoint {
          url = "https://prometheus-prod-XX-XX.grafana.net/api/prom/push"
          basic_auth {
            username = "YOUR_PROMETHEUS_USERNAME"
            password = "YOUR_GRAFANA_API_TOKEN"
          }
        }
      }
```

### Method 2: External ConfigMap

```bash
# Create configuration file
cat > config.alloy << 'EOF'
logging {
  level = "info"
  format = "logfmt"
}

// Your Alloy configuration here
EOF

# Create ConfigMap
kubectl create configmap alloy-config --from-file=config.alloy=./config.alloy -n alloy

# Update values.yaml to use external ConfigMap
helm upgrade alloy grafana/alloy -n alloy --set alloy.configMap.create=false --set alloy.configMap.name=alloy-config --set alloy.configMap.key=config.alloy
```

## Security Considerations

### RBAC (Role-Based Access Control)

Alloy requires specific permissions to discover and scrape Kubernetes resources:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: alloy
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
```

### Security Context (Non-Root User)

For production deployments, especially on OpenShift:

```yaml
securityContext:
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  runAsUser: 473
  runAsGroup: 473
  fsGroup: 1000
```

### Security Context Constraints (OpenShift)

```yaml
kind: SecurityContextConstraints
apiVersion: security.openshift.io/v1
metadata:
  name: scc-alloy
runAsUser:
  type: MustRunAs
  uid: 473
fsGroup:
  type: MustRunAs
  uid: 1000
volumes: 
- configMap
- downwardAPI
- emptyDir
- persistentVolumeClaim
- secret
```

## Production Deployment Patterns

### DaemonSet for Node-Level Monitoring

For comprehensive node monitoring (logs, metrics from all pods):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy-logs
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: alloy-logs
  template:
    metadata:
      labels:
        app: alloy-logs
    spec:
      containers:
      - name: alloy-logs
        image: grafana/alloy:latest
        ports:
        - containerPort: 12345
        securityContext:
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          runAsUser: 473
          runAsGroup: 473
        volumeMounts:
        - name: varlog
          mountPath: /var/log
          readOnly: true
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
```

### Deployment for Centralized Receiving

For receiving OpenTelemetry data or centralized processing:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alloy-receiver
  namespace: monitoring
spec:
  replicas: 3
  selector:
    matchLabels:
      app: alloy-receiver
  template:
    metadata:
      labels:
        app: alloy-receiver
    spec:
      containers:
      - name: alloy-receiver
        image: grafana/alloy:latest
        ports:
        - containerPort: 4317  # OTLP gRPC
        - containerPort: 4318  # OTLP HTTP
        - containerPort: 12345 # Alloy UI
```

## Key Configuration Components

### Log Collection

```yaml
# Kubernetes pod logs
loki.source.kubernetes "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [loki.write.grafana_cloud.receiver]
}

# Kubernetes events
loki.source.kubernetes_events "cluster_events" {
  forward_to = [loki.write.grafana_cloud.receiver]
}

# Journal logs (requires DaemonSet with /var/log mount)
loki.source.journal "system" {
  max_age       = "12h"
  relabel_rules = loki.relabel.journal.rules
  forward_to    = [loki.write.grafana_cloud.receiver]
}
```

### Metrics Collection

```yaml
# Kubernetes API server metrics
prometheus.scrape "apiserver" {
  targets = discovery.kubernetes.apiserver.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

# Node exporter metrics (if deployed)
prometheus.scrape "node_exporter" {
  targets = discovery.kubernetes.node_exporter.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}

# Custom application metrics
prometheus.scrape "kubernetes_pods" {
  targets = discovery.kubernetes.pods.targets
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]
}
```

### Traces Collection

```yaml
# OTLP receiver
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    traces = [otelcol.exporter.otlp.grafana_cloud.input]
  }
}

# Export to Grafana Cloud
otelcol.exporter.otlp "grafana_cloud" {
  client {
    endpoint = "https://tempo-XX-XX.grafana.net:443"
    auth     = otelcol.auth.basic.grafana_cloud.handler
  }
}
```

## Best Practices

### Resource Management

```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### High Availability

For production deployments:

1. **Enable Clustering**: Use multiple replicas with clustering enabled
2. **Load Balancing**: Use Kubernetes services with session affinity
3. **Persistent Storage**: For WAL (Write-Ahead Log) when needed

```yaml
alloy:
  clustering:
    enabled: true
  extraVolumes:
  - name: alloy-wal
    persistentVolumeClaim:
      claimName: alloy-wal-pvc
  extraVolumeMounts:
  - name: alloy-wal
    mountPath: /tmp/alloy
```

### Monitoring Alloy Itself

Monitor Alloy's health and performance:

```bash
# Access Alloy UI (when port-forwarded)
kubectl port-forward deployment/alloy 12345:12345 -n alloy

# View at http://localhost:12345
```

### Configuration Management

1. **Version Control**: Store configurations in Git
2. **Environment-Specific**: Use different values files per environment
3. **Validation**: Use `alloy fmt` and `alloy validate` commands
4. **Testing**: Test configurations in development clusters first

## Troubleshooting

### Common Issues

1. **RBAC Permissions**: Ensure Alloy has proper cluster permissions
2. **Network Policies**: Check if network policies block Alloy's communication
3. **Resource Limits**: Monitor memory and CPU usage, adjust limits accordingly
4. **Configuration Errors**: Use Alloy UI to check component status

### Debugging Commands

```bash
# Check pod status
kubectl get pods -n alloy

# View logs
kubectl logs -f deployment/alloy -n alloy

# Check configuration
kubectl describe configmap alloy-config -n alloy

# Access Alloy UI for debugging
kubectl port-forward deployment/alloy 12345:12345 -n alloy
```

### Performance Tuning

1. **Memory Settings**: Increase limits for high-volume environments
2. **Clustering**: Enable for high availability and load distribution
3. **Batching**: Configure appropriate batch sizes for remote write
4. **Filtering**: Use relabeling to reduce data volume

## Integration with Grafana Cloud

To connect Alloy to Grafana Cloud:

1. **Get Credentials**: From Grafana Cloud portal
2. **Configure Remote Write**: For metrics
3. **Configure Loki Push**: For logs  
4. **Configure OTLP Export**: For traces

```yaml
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "https://prometheus-prod-XX-XX.grafana.net/api/prom/push"
    basic_auth {
      username = "YOUR_PROMETHEUS_USERNAME"
      password = "YOUR_GRAFANA_API_TOKEN"
    }
  }
}

loki.write "grafana_cloud" {
  endpoint {
    url = "https://logs-prod-XX.grafana.net/loki/api/v1/push"
    basic_auth {
      username = "YOUR_LOKI_USERNAME"
      password = "YOUR_GRAFANA_API_TOKEN"
    }
  }
}
```

## Conclusion

Grafana Alloy provides a powerful and flexible solution for collecting observability data from Kubernetes clusters. By following these deployment patterns and best practices, you can create a robust monitoring solution that scales with your infrastructure needs.

Key takeaways:
- Use Helm charts for easy deployment and management
- Configure RBAC properly for security
- Use specialized Alloy instances for different data types
- Monitor Alloy itself for operational insights
- Follow security best practices, especially for production deployments