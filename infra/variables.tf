# ============================================================
#  变量定义 —— 资源栈集（StackSets）部署所需参数
# ============================================================

# —— 管理面 / 区域 ——
variable "admin_region" {
  description = "StackSets 管理面区域（控制面固定区域，与成员部署区域解耦）。"
  type        = string
  default     = "cn-north-4"
}

# 自部署演示模式：true 时把 StackSet 部署到「当前账号」本身（自动发现 domain id
# 并通过 huaweicloud_identity_agency 自建 RFS 代入 agency），无需提供 target_account_ids
# 与预先配置的 RAM 委托管理员。用于单机/单机演示，不对真实多账号场景生效。
variable "self_deploy" {
  description = "true 时自部署到当前账号（自动发现 domain id + 自建 managed agency）。"
  type        = bool
  default     = false
}

# —— StackSet（资源栈集）本体 ——
variable "stack_set_name" {
  description = "资源栈集名称。"
  type        = string
}

variable "stack_set_description" {
  description = "资源栈集描述。"
  type        = string
  default     = "资源栈集（RFS StackSet）部署示例"
}

# 权限模型：SELF_MANAGED（自管理，需 RAM 委托管理员+成员账号委托）
#           SERVICE_MANAGED（服务管理，按组织单元部署）
variable "permission_model" {
  description = "权限模型：SELF_MANAGED 或 SERVICE_MANAGED。"
  type        = string
  default     = "SELF_MANAGED"

  validation {
    condition     = contains(["SELF_MANAGED", "SERVICE_MANAGED"], var.permission_model)
    error_message = "permission_model 只能是 SELF_MANAGED 或 SERVICE_MANAGED。"
  }
}

# RAM 委托管理员 agency（管理账号侧）
variable "administration_agency_name" {
  description = "管理账号侧的 RAM 委托管理员 agency 名称（SELF_MANAGED 模式下必填）。"
  type        = string
  default     = ""
}

# 成员账号中由 RFS 代入的 agency（成员账号侧）
variable "managed_agency_name" {
  description = "成员账号中 RFS 代入执行部署的 agency 名称。"
  type        = string
  default     = "RFS_ADMIN_TRUSTED"
}

# 自部署模式下被管理委托所委托的【管理账号】domain name
# （SELF_MANAGED 单账号演示时，管理账号=目标账号=当前账号）。
# 由 _get_domain_name.py 通过 IAM token 接口发现：本演示账号为 GT-dgcmy。
variable "management_account_name" {
  description = "自部署模式下，被管理委托(delegated_domain_name)所委托的管理账号 domain name。"
  type        = string
  default     = "GT-dgcmy"
}

# 服务管理模式下，按组织单元（OU）部署
variable "organizational_unit_ids" {
  description = "SERVICE_MANAGED 模式下部署目标组织单元 ID 列表。"
  type        = list(string)
  default     = []
}

# —— 栈模板与参数 ——
# 二选一：直接传模板内容，或传 OBS/SWR 上的模板 URI。
variable "stack_template_body" {
  description = "资源栈模板正文（Terraform HCL，须含 required_providers 且不能写 provider 块）。可留空改用 stack_template_uri。"
  type        = string
  default     = ""
}

variable "stack_template_uri" {
  description = "资源栈模板 URI（OBS 等），与 stack_template_body 二选一。"
  type        = string
  default     = ""
}

# 栈集级参数
# RFS vars_body 必须是 HCL 的 .tfvars 格式（如 vpc_cidr = "192.168.0.0/16"），
# 不是 YAML/JSON。空字符串表示使用模板里的变量默认值。（HCL tfvars 格式）。
variable "stack_set_vars" {
  description = "资源栈集级变量（HCL tfvars 格式，如 vpc_cidr = \"192.168.0.0/16\"），不是 YAML/JSON。"
  type        = string
  default     = ""
}

# —— 部署目标（DeploymentTargets + Regions）——
variable "target_regions" {
  description = "成员部署区域列表。"
  type        = list(string)
}

variable "target_account_ids" {
  description = "目标成员账号 ID 列表（SELF_MANAGED）。"
  type        = list(string)
  default     = []
}

variable "target_account_ids_uri" {
  description = "目标账号 ID 列表的 URI（大批量时替代 target_account_ids）。"
  type        = string
  default     = ""
}

variable "domain_id_filter_type" {
  description = "账号过滤类型：NONE / INTERSECTION / DIFFERENCE。"
  type        = string
  default     = "NONE"
}

# 每次部署的变量覆盖
# 同 stack_set_vars：HCL tfvars 格式，不是 YAML/JSON。
variable "deployment_vars_overrides" {
  description = "本次部署的变量覆盖（HCL tfvars 格式）。"
  type        = string
  default     = ""
}

# —— 并发部署策略 ——
# 原生并发部署开关：开启后 RFS 按 region_concurrency_type 并发部署。
variable "enable_parallel_operation" {
  description = "开启 RFS 原生并发部署（managed_operation.enable_parallel_operation）。"
  type        = bool
  default     = true
}

variable "region_concurrency_type" {
  description = "区域并发类型：SEQUENTIAL 或 PARALLEL，RegionConcurrencyType。"
  type        = string
  default     = "PARALLEL"

  validation {
    condition     = contains(["SEQUENTIAL", "PARALLEL"], var.region_concurrency_type)
    error_message = "region_concurrency_type 只能是 SEQUENTIAL 或 PARALLEL。"
  }
}

variable "max_concurrent_count" {
  description = "最大并发数（按数量），MaxConcurrentCount。RFS 上限为 5。"
  type        = number
  default     = 5

  validation {
    condition     = var.max_concurrent_count >= 1 && var.max_concurrent_count <= 5
    error_message = "max_concurrent_count 取值 1~5。"
  }
}

variable "max_concurrent_percentage" {
  description = "最大并发百分比，MaxConcurrentPercentage。"
  type        = number
  default     = 0
}

variable "failure_tolerance_count" {
  description = "失败容忍数量，FailureToleranceCount。"
  type        = number
  default     = 0
}

variable "failure_tolerance_percentage" {
  description = "失败容忍百分比，FailureTolerancePercentage。"
  type        = number
  default     = 0
}

variable "failure_tolerance_mode" {
  description = "失败容忍模式：STRICT_FAILURE_TOLERANCE（严格，遇错即停）/ SOFT_FAILURE_TOLERANCE（宽松，按 failure_tolerance 继续）。"
  type        = string
  default     = "SOFT_FAILURE_TOLERANCE"

  validation {
    condition     = contains(["STRICT_FAILURE_TOLERANCE", "SOFT_FAILURE_TOLERANCE"], var.failure_tolerance_mode)
    error_message = "failure_tolerance_mode 只能是 STRICT_FAILURE_TOLERANCE 或 SOFT_FAILURE_TOLERANCE。"
  }
}

variable "region_order" {
  description = "SEQUENTIAL 模式下的区域执行顺序，RegionOrder。"
  type        = list(string)
  default     = []
}
