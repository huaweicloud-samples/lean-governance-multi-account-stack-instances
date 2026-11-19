# ============================================================
#  RFS 资源栈集模板（Terraform HCL，非 HOT）
#  —— 演示负载：创建一个免费 VPC。请替换为真实业务模板。
#
#  注意（RFS 栈集强约束）：
#   1) 必须是 Terraform HCL，且必须声明 required_providers；
#   2) 不能写 provider 块 —— provider 由 RFS 在部署时自动注入，
#      手写 provider { cloud = "{cloud_name}" } 占位符会报
#      "Invalid provider configuration" 失败。
# ============================================================

terraform {
  required_providers {
    huaweicloud = {
      source  = "huawei.com/provider/huaweicloud"
      version = "1.41.0"
    }
  }
}

variable "vpc_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "vpc_name" {
  type    = string
  default = "rfs-stackset-demo"
}

resource "huaweicloud_vpc" "demo" {
  name = var.vpc_name
  cidr = var.vpc_cidr
}

output "vpc_id" {
  value = huaweicloud_vpc.demo.id
}
