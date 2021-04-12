# Get current region
data "aws_region" "current" {}

locals {
  CMD_CLOUDWATCH = <<EOL
    kubectl apply -f ./AWS/enable_containerinsights/cloudwatch-namespace.yaml;
    kubectl apply -f ./AWS/enable_containerinsights/cwagent-configmap.yaml;
    kubectl apply -f ./AWS/enable_containerinsights/cwagent-serviceaccount.yaml;
    kubectl apply -f ./AWS/enable_containerinsights/cwagent-daemonset.yaml;
  EOL
  CMD_CLUSTERNAME = "ClusterName=${var.cluster_name};"
  CMD_REGION = "RegionName=${data.aws_region.current.name};"
  CMD_FLUENTBIT = <<EOL
    FluentBitHttpPort='2020';
    FluentBitReadFromHead='Off';
    [[ $${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On';
    [[ -z $${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On';
    kubectl create configmap fluent-bit-cluster-info \
    --from-literal=cluster.name=$${ClusterName} \
    --from-literal=http.server=$${FluentBitHttpServer} \
    --from-literal=http.port=$${FluentBitHttpPort} \
    --from-literal=read.head=$${FluentBitReadFromHead} \
    --from-literal=read.tail=$${FluentBitReadFromTail} \
    --from-literal=logs.region=$${RegionName} -n amazon-cloudwatch --dry-run=client -o yaml | kubectl apply -f -;
    kubectl apply -f ./AWS/enable_containerinsights/fluent-bit.yaml
  EOL
}

# Enable container insights
resource "null_resource" "enable_container_insights" {

  # Run this provisioner always
  triggers = {
    always_run = timestamp()
  }
  
  # Enable container insights
  provisioner "local-exec" {
    command = join("",[local.CMD_CLOUDWATCH, local.CMD_CLUSTERNAME, local.CMD_REGION, local.CMD_FLUENTBIT])
    interpreter = ["/bin/bash", "-c"]
  }
}