# ============================================================
#  输出 —— 便于外部模块或脚本引用部署结果
# ============================================================

output "stack_set_id" {
  description = "资源栈集 ID。"
  value       = huaweicloud_rfs_stack_set.this.stack_set_id
}

output "stack_set_name" {
  description = "资源栈集名称。"
  value       = huaweicloud_rfs_stack_set.this.stack_set_name
}

output "stack_set_status" {
  description = "资源栈集状态。"
  value       = huaweicloud_rfs_stack_set.this.status
}

output "deployment_id" {
  description = "本次部署（资源栈集实例）ID。"
  value       = huaweicloud_rfs_stack_set_deployment.this.id
}

output "deployment_region" {
  description = "部署所属管理区域。"
  value       = huaweicloud_rfs_stack_set_deployment.this.region
}
