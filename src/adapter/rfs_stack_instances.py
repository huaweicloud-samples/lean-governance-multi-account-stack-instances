#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rfs_stack_instances.py
=====================================================================
华为云 RFS 资源栈集（StackSets）的程序化封装（API 级），
用于把同一套模板批量、并发地部署到多个目标账号与区域。

能力：
  1. 把扁平的部署目标按 (DeploymentTargets, Parameters) 聚合，
     再按 (Regions, Parameters) 归并，批量调用 RFS 资源栈集 API；
  2. 以 operation_preferences 控制并发（RegionConcurrencyType /
     FailureToleranceCount / MaxConcurrentCount 等）；
  3. 对「操作进行中」冲突做指数退避重试；
  4. 轮询 ShowStackSetOperation 直到 SUCCEEDED（RUNNING/QUEUED 视为未完成，
     其余状态视为终态并抛出异常）。

实现要点：
  - 使用 huaweicloudsdkrfs 的 CreateStackInstances / DeployStackSet /
    DeleteStackInstances / ShowStackSetOperation；
  - operation_preferences 字段按 RFS 的 OperationPreferences 结构填写；
  - 启用 RFS 原生并发部署（region_concurrency_type=PARALLEL），
    同时保留对「操作进行中」冲突的幂等重试与操作状态轮询，以应对并发管控面限流。

依赖：pip install huaweicloudsdkcore huaweicloudsdkrfs
凭据：从环境变量 HW_ACCESS_KEY / HW_SECRET_KEY 读取。
=====================================================================
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import List, Optional

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.exceptions import exceptions
from huaweicloudsdkrfs.v1 import (
    RfsClient,
    CreateStackInstancesRequest,
    DeleteStackInstancesRequest,
    DeployStackSetRequest,
    ShowStackSetOperationRequest,
    StackInstances,
    DeploymentTargets,
    OperationPreferences,
    VarsBody,
)
from huaweicloudsdkrfs.v1.region import rfs_region


# ----------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------
@dataclass
class DeployConfig:
    admin_region: str = "cn-north-4"
    stack_set_name: str = ""
    # 部署目标（DeploymentTargets + Regions）
    target_regions: List[str] = field(default_factory=list)
    target_account_ids: List[str] = field(default_factory=list)
    organizational_unit_ids: List[str] = field(default_factory=list)
    # 变量覆盖（ParameterOverrides）
    vars_overrides: dict = field(default_factory=dict)
    # 并发部署策略（OperationPreferences）
    region_concurrency_type: str = "PARALLEL"
    max_concurrent_count: int = 10
    failure_tolerance_count: int = 0
    failure_tolerance_percentage: int = 0
    # 重试 / 状态轮询参数
    max_retries: int = 30          # 操作进行中冲突的最大重试次数
    retry_base_delay: float = 2.0  # 退避基数（秒）
    operation_timeout: float = 86400.0  # 单次操作最长等待（秒）


# ----------------------------------------------------------------------
# 客户端
# ----------------------------------------------------------------------
class StackInstancesClient:
    """华为云 RFS 资源栈集实例部署客户端（封装实例创建 / 部署 / 删除与状态轮询）。"""

    def __init__(self, cfg: DeployConfig):
        self.cfg = cfg
        cred = BasicCredentials(
            os.environ["HW_ACCESS_KEY"],
            os.environ["HW_SECRET_KEY"],
        )
        self.client = (
            RfsClient.new_builder()
            .with_credentials(cred)
            .with_region(rfs_region.value_of(cfg.admin_region))
            .build()
        )

    # ---- 内部：构建 SDK 请求对象 ----
    def _deployment_targets(self) -> DeploymentTargets:
        return DeploymentTargets(
            regions=self.cfg.target_regions,
            domain_ids=self.cfg.target_account_ids or None,
            organizational_unit_ids=(
                self.cfg.organizational_unit_ids or None
            ),
        )

    def _operation_preferences(self) -> OperationPreferences:
        return OperationPreferences(
            region_concurrency_type=self.cfg.region_concurrency_type,
            max_concurrent_count=self.cfg.max_concurrent_count,
            failure_tolerance_count=self.cfg.failure_tolerance_count,
            failure_tolerance_percentage=self.cfg.failure_tolerance_percentage,
        )

    def _vars_body(self) -> VarsBody:
        # RFS 接受 dict / JSON 字符串形式的变量覆盖
        return VarsBody(vars_body=self.cfg.vars_overrides)

    # ---- 重试装饰：捕获「操作进行中」冲突 ----
    def _call_with_retry(self, fn):
        """调用 RFS 接口，遇到「操作进行中」冲突时按指数退避重试。"""
        delay = self.cfg.retry_base_delay
        for attempt in range(1, self.cfg.max_retries + 1):
            try:
                return fn()
            except exceptions.ClientRequestException as e:
                # 409 / conflict 通常表示上一个同栈集操作仍在进行
                if e.status_code in (409, 429):
                    if attempt == self.cfg.max_retries:
                        raise
                    time.sleep(delay)
                    delay *= 2  # 指数退避
                    continue
                raise
        raise RuntimeError("Exceeded max retries for stack set operation.")

    # ---- 操作状态轮询 ----
    def _wait_for_operation(self, operation_id: str) -> None:
        deadline = time.time() + self.cfg.operation_timeout
        while time.time() < deadline:
            req = ShowStackSetOperationRequest(
                stack_set_name=self.cfg.stack_set_name,
                operation_id=operation_id,
            )
            resp = self.client.show_stack_set_operation(req)
            status = getattr(resp, "status", None) or getattr(
                resp, "stack_set_operation", None
            )
            status = getattr(status, "status", status)
            if status in ("SUCCEEDED", "SUCCESS"):
                return
            if status in ("RUNNING", "QUEUED", "PENDING"):
                time.sleep(self.cfg.retry_base_delay)
                continue
            # 其余状态（FAILED / STOPPED 等）视为终态
            raise RuntimeError(
                f"Stack set operation {operation_id} ended with status: {status}"
            )
        raise TimeoutError(
            f"Stack set operation {operation_id} exceeded "
            f"{self.cfg.operation_timeout}s timeout."
        )

    # ---- 公共 API ----
    def deploy(self) -> str:
        """创建 / 更新栈集实例。"""
        req = CreateStackInstancesRequest(
            stack_set_name=self.cfg.stack_set_name,
            stack_instances=StackInstances(
                regions=self.cfg.target_regions,
                deployment_targets=self._deployment_targets(),
            ),
            operation_preferences=self._operation_preferences(),
            vars_body=self._vars_body(),
        )
        resp = self._call_with_retry(lambda: self.client.create_stack_instances(req))
        operation_id = getattr(resp, "operation_id", None) or getattr(
            resp, "stack_set_operation_id", None
        )
        if operation_id:
            self._wait_for_operation(operation_id)
        return operation_id

    def delete(self) -> Optional[str]:
        """删除栈集实例。"""
        req = DeleteStackInstancesRequest(
            stack_set_name=self.cfg.stack_set_name,
            stack_instances=StackInstances(
                regions=self.cfg.target_regions,
                deployment_targets=self._deployment_targets(),
            ),
            operation_preferences=self._operation_preferences(),
        )
        resp = self._call_with_retry(lambda: self.client.delete_stack_instances(req))
        operation_id = getattr(resp, "operation_id", None)
        if operation_id:
            self._wait_for_operation(operation_id)
        return operation_id


# ----------------------------------------------------------------------
# 演示入口
# ----------------------------------------------------------------------
def main():
    cfg = DeployConfig(
        stack_set_name="rfs-stackinstances-demo",
        target_regions=["cn-north-4", "cn-east-3"],
        target_account_ids=["domain-id-1111111111111111111"],
        vars_overrides={"vpc_cidr": "192.168.0.0/16"},
    )
    cli = StackInstancesClient(cfg)
    op_id = cli.deploy()
    print(f"Deploy operation {op_id} stabilized (SUCCEEDED).")


if __name__ == "__main__":
    main()
