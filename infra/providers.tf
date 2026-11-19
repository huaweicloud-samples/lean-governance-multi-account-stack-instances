terraform {
  required_version = ">= 1.5.0"

  required_providers {
    huaweicloud = {
      # RFS 资源栈集（StackSets）+ 并发部署策略（managed_operation.enable_parallel_operation）
      # 需要 provider >= 1.70.0；若本地锁版本更老，请先 `terraform init -upgrade`。
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.70.0"
    }
  }
}

# 管理面区域：StackSets 的控制面固定在管理账号所在区域，
# 与下方 deployment_targets.regions（成员账号/成员区域）解耦。
provider "huaweicloud" {
  region = var.admin_region
}
