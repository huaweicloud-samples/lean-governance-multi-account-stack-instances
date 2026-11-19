# 部署指导书：华为云 RFS 资源栈集（StackSets）跨账号 / 跨区域批量部署

> 本文档按「前置条件 → 快速开始 → 分步部署 → 使用方法与验证 → 清理资源」五段式组织，便于复现与排障。

## 1. 前置条件

- 华为云账号（默认区域 `cn-north-4`），具备 RFS 与目标账号/区域的部署权限。
- 本地安装 `terraform >= 1.5`，`huaweicloud` provider `>= 1.96.0`。
- 凭据：在华为云「我的凭证」页面获取 Access Key 与 Secret Access Key，并填入 `terraform.tfvars` 或环境变量。**不要**将凭据写入任何代码或配置文件。

- `SERVICE_MANAGED` 模式需在控制台预先完成组织单元授权；`SELF_MANAGED` 自部署模式下，**管理委托需含 `iam:tokens:assume`**——该权限为全局级，需具备 **Security Administrator** 的账号在控制台授予：
  - 方案 a：给自建的管理委托勾选全局角色 **Agent Operator**。
  - 方案 b：新建自定义策略（含 `iam:tokens:assume`，Resource 指向被管理委托）并授权给管理委托。

## 2. 快速开始

```bash
cd <本仓库根目录>/infra
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars：stack_set_name / 目标账号 / 区域 / 模板
terraform init -upgrade
terraform plan
terraform apply
```

要点：
- 模板必须是 Terraform HCL：声明 `required_providers { huaweicloud = { source = "huawei.com/provider/huaweicloud" } }`，且**不能写 `provider` 块**。
- `stack_set_vars` / `deployment_vars_overrides`（`vars_body`）必须是 HCL 的 `.tfvars` 格式（如 `vpc_cidr = "192.168.0.0/16"`），不是 YAML / JSON。

## 3. 分步部署

1. **复制变量示例**：`cp terraform.tfvars.example terraform.tfvars`，填入 `stack_set_name` / 目标账号 / 区域 / 模板。
2. **初始化**：`terraform init -upgrade`（下载 huaweicloud provider）。
3. **预览**：`terraform plan`，核对栈集与部署资源清单。
4. **执行**：`terraform apply`，创建资源栈集与部署实例；自部署模式会自动创建两个 IAM 委托。
5. **验证**：参见第 4 节「使用方法与验证」端到端验证步骤。

## 4. 使用方法与验证

> **强烈建议**：部署完成后请按本节步骤自行验证，确认业务功能可用，方可视为交付完成。

- 控制台 RFS → 资源栈集：确认 `stack_set_name` 已创建且状态为「正常」。
- 控制台 RFS → 资源栈实例：确认目标账号/区域下出现实例且状态为 `CURRENT`。
- `terraform output stack_set_id` / `stack_set_name` / `stack_set_status` 取回部署信息。
- 在目标账号/区域控制台核对模板实际创建的资源（如示例 VPC / 子网 / 安全组）已落地。

## 5. 清理资源

```bash
cd <本仓库根目录>/infra
terraform destroy
```

> `self_deploy = true` 时会自动销毁自建的两个 IAM 委托；`SERVICE_MANAGED` 模式下还需在控制台清理组织单元关联。

## 6. FAQ

- **`permission_model` 如何选？** 单账号演示选 `SELF_MANAGED`；跨账号组织化管理选 `SERVICE_MANAGED`，并在控制台预先完成组织单元授权。
- **`stack_set_vars` 报错？** RFS 要求 `.tfvars` HCL 格式（如 `vpc_cidr = "192.168.0.0/16"`），不是 YAML/JSON。
- **资源栈集与资源栈实例的关系？** 栈集是模板定义；实例是把模板落到具体账号/区域下的资源栈。
- **`max_concurrent_count` 报错？** RFS 上限为 5；超出会触发参数校验失败。
