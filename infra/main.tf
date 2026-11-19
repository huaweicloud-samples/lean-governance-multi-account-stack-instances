# ============================================================
#  华为云 RFS 资源栈集（StackSets）实现跨账号/跨 region 部署
#
#  功能说明：
#    - 本实践基于华为云原生 RFS 资源栈集能力实现 StackSets 部署：
#      · huaweicloud_rfs_stack_set：定义栈集模板与变量
#      · huaweicloud_rfs_stack_set_deployment：把模板部署到指定账号/region
#    - operation_preferences 字段原生支持并发部署与失败容忍；
#    - managed_operation.enable_parallel_operation 原生支持并发部署。
# ============================================================

# 自部署模式下，RFS 资源栈集 SELF_MANAGED 需要两个 agency（华为云官方要求）：
#   1) 管理委托（administration_agency）：委托给云服务 RFS(op_svc_iac)，
#      且必须含 iam:tokens:assume，否则 RFS 无法代入被管理委托的凭证
#      （新增/部署实例时报 iam:assume 403）。
#   2) 被管理委托（managed_agency）：账号型委托，委托给【管理账号】本身
#      （delegated_domain_name = 管理账号 domain name），RFS 用它在实际
#      部署的目标账号中创建资源。注意它必须是账号型，不能是 op_svc_iac 服务型，
#      否则 IAM 报 "AssumeFrom domain is not trusted"。
#
# 重要：iam:tokens:assume 是【全局/域名级】权限，只能经 domain_roles 授予
# "Agent Operator" 角色，而该授予动作需要 Security Administrator。
# 多数 terraform 执行所用的 IAM 子账号并不具备该权限（会报
# iam:permissions:grantRoleToAgencyOnDomain 被拒），因此本资源仅授予
# Tenant Administrator（project 级，子账号可授予）；iam:tokens:assume 需由
# 具备 Security Administrator 的账号在控制台或 CLI 单独授予——二选一：
#   a) 给本 agency 勾选全局角色 "Agent Operator"；或
#   b) 新建自定义策略（含 iam:tokens:assume，Resource 指向被管理委托）并授权给本 agency。
# 详见 README「SELF_MANAGED 前置权限」一节。
resource "huaweicloud_identity_agency" "rfs_admin" {
  count               = var.self_deploy ? 1 : 0
  name                = "RFS_SS_DEMO_ADMIN_AGENCY"
  description         = "RFS StackSet administration agency (self-deploy demo)"
  delegated_service_name = "op_svc_iac"
  project_role {
    project = var.admin_region
    roles   = ["Tenant Administrator"]
  }
}

resource "huaweicloud_identity_agency" "rfs_managed" {
  count                  = var.self_deploy ? 1 : 0
  name                   = var.managed_agency_name
  description            = "RFS StackSet managed agency (self-deploy demo)"
  delegated_domain_name = var.management_account_name
  project_role {
    project = var.admin_region
    roles   = ["Tenant Administrator"]
  }
}

# —— 资源栈集（StackSet）——
resource "huaweicloud_rfs_stack_set" "this" {
  stack_set_name        = var.stack_set_name
  stack_set_description = var.stack_set_description
  permission_model      = var.permission_model

  # SELF_MANAGED 且非自部署：需要 RAM 委托管理员 agency（管理账号侧，控制台预配置）；
  # SERVICE_MANAGED：按组织单元部署，OU 经 deployment_targets.organizational_unit_ids 指定；
  # 自部署模式：administration_agency_name 与 managed_agency_name 均用本模块自建的两个 agency。
  # （注意：stack_set 上的 organizational_unit_ids 为只读计算属性，不可赋值）
  administration_agency_name = var.self_deploy ? huaweicloud_identity_agency.rfs_admin[0].name : (var.permission_model == "SELF_MANAGED" ? var.administration_agency_name : null)
  # 自部署模式引用本模块自建的两个 agency，隐式依赖保证 agency 先就绪
  managed_agency_name        = var.self_deploy ? huaweicloud_identity_agency.rfs_managed[0].name : var.managed_agency_name

  # 模板二选一
  template_body = var.stack_template_uri == "" ? var.stack_template_body : null
  template_uri  = var.stack_template_uri == "" ? null : var.stack_template_uri

  vars_body = var.stack_set_vars

  # 原生并发部署开关（华为云原生提供并发部署能力）
  managed_operation {
    enable_parallel_operation = var.enable_parallel_operation
  }
}

# —— 资源栈集部署（DeployStackSet：把模板部署到已存在的实例）——
# 重要：huaweicloud_rfs_stack_set_deployment 只把模板部署到「已存在」的实例，
# 不会创建实例。实例的创建由下面的 null_resource.stack_instances 通过签名 API 补做
# （provider 1.96.x 无 stack_set_instance 资源），故用签名脚本补建实例。
resource "huaweicloud_rfs_stack_set_deployment" "this" {
  stack_set_name = huaweicloud_rfs_stack_set.this.stack_set_name

  # 模板/变量覆盖（栈集级变量已在 stack_set 定义）
  # 部署资源需自带模板（不继承栈集模板）
  template_body = var.stack_template_uri == "" ? var.stack_template_body : null
  template_uri  = var.stack_template_uri == "" ? null : var.stack_template_uri
  vars_body     = var.deployment_vars_overrides

  # 部署目标（DeploymentTargets + Regions）
  deployment_targets {
    regions               = var.target_regions
    domain_ids           = var.target_account_ids
    # domain_ids_uri / domain_id_filter_type 仅在提供 uri 时使用（SELF_MANAGED 下不能带 filter_type）
    domain_ids_uri       = var.target_account_ids_uri == "" ? null : var.target_account_ids_uri
    domain_id_filter_type = var.target_account_ids_uri == "" ? null : var.domain_id_filter_type
    organizational_unit_ids = var.permission_model == "SERVICE_MANAGED" ? var.organizational_unit_ids : null
  }

  # 并发部署策略（华为云原生字段与 OperationPreferences 语义一致）
  operation_preferences {
    region_concurrency_type     = var.region_concurrency_type
    max_concurrent_count        = var.max_concurrent_count
    max_concurrent_percentage   = var.max_concurrent_percentage
    failure_tolerance_count     = var.failure_tolerance_count
    failure_tolerance_percentage = var.failure_tolerance_percentage
    failure_tolerance_mode      = var.failure_tolerance_mode
    region_order                = length(var.region_order) > 0 ? var.region_order : null
  }

  # 先建实例再部署：依赖栈集 + 实例创建（自部署时栈集已隐式依赖自建 agency）
  depends_on = [huaweicloud_rfs_stack_set.this, null_resource.stack_instances]
}

# —— 补建 / 清理资源栈实例（一键部署的关键缺口）——
# provider 1.96.x 无 stack_set_instance 资源；DeployStackSet 只部署已存在实例。
# 此处用签名 API 直调 CreateStackInstance / DeleteStackInstance 补上，使
# `terraform apply` 真正创建实例与资源（如示例 VPC），`terraform destroy` 一并清理。
# SELF_MANAGED 且有目标账号时才启用；SERVICE_MANAGED（按 OU）不做（交 deployment 资源）。
# 凭据（HW_ACCESS_KEY / HW_SECRET_KEY）从进程环境读取，不写入 .tf 文件。
resource "null_resource" "stack_instances" {
  count = var.permission_model == "SELF_MANAGED" && length(var.target_account_ids) > 0 ? 1 : 0

  triggers = {
    stack_set_name = huaweicloud_rfs_stack_set.this.stack_set_name
    regions        = join(",", var.target_regions)
    domain_ids     = join(",", var.target_account_ids)
    admin_region   = var.admin_region
  }

  provisioner "local-exec" {
    command = "python \"${path.module}/scripts/rfs_stack_instances.py\" --action create --stack-set-name ${huaweicloud_rfs_stack_set.this.stack_set_name} --regions ${join(",", var.target_regions)} --domain-ids ${join(",", var.target_account_ids)} --region ${var.admin_region}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "python \"${path.module}/scripts/rfs_stack_instances.py\" --action delete --stack-set-name ${self.triggers.stack_set_name} --regions ${self.triggers.regions} --domain-ids ${self.triggers.domain_ids} --region ${self.triggers.admin_region}"
  }

  depends_on = [huaweicloud_rfs_stack_set.this]
}
