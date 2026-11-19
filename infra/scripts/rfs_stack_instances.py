#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rfs_stack_instances.py —— 资源栈集实例「创建 / 删除」兜底脚本
=====================================================================
背景
----
huaweicloud provider 1.96.x **没有** `huaweicloud_rfs_stack_set_instance` 资源，
且 `huaweicloud_rfs_stack_set_deployment`（对应 RFS DeployStackSet API）只部署
**已存在**的实例、不会创建实例。因此纯 `terraform apply` 建得出「资源栈集」，
却建不出任何实例 / 实际资源（如示例 VPC）。

本脚本用 AK/SK 直接签名调 RFS `CreateStackInstance` / `DeleteStackInstance` API
补上这缺失的一步，由 `infra/main.tf` 的 `null_resource` 在 apply / destroy 时
调用，使整条链路真正一键化、可清理。

签名
----
采用华为云 AK/SK 签名（HTTP 标准），需关注 4 处关键点：
URI 须以 `/` 结尾、`x-sdk-date` 不进签名头、密钥 = 原始 SK 直接 HMAC、
StringToSign 不含 scope 行。

凭据
----
从环境变量读取 `HW_ACCESS_KEY` / `HW_SECRET_KEY`。
由 `terraform apply` 进程环境继承给 local-exec，无需写进 .tf。

依赖
----
仅 Python 标准库（urllib），零 pip 依赖。
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request
import urllib.error
from urllib.parse import urlparse


def _sign(ak: str, sk: str, method: str, url: str, body: bytes = b"") -> dict:
    """华为云 AK/SK 请求签名（POST 带体时 content-type 也进签名头）。"""
    p = urlparse(url)
    host = p.netloc
    uri = p.path if p.path.endswith("/") else p.path + "/"
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    body_hash = hashlib.sha256(body).hexdigest()
    headers = {"host": host, "x-sdk-date": date}
    if body:
        headers["content-type"] = "application/json"
    sh = ";".join(sorted(headers))                      # host[;content-type]，x-sdk-date 不进
    ch = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    canonical = "\n".join([method.upper(), uri, p.query, ch, sh, body_hash])
    sts = "\n".join(
        ["SDK-HMAC-SHA256", date, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    sig = hmac.new(sk.encode(), sts.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        f"SDK-HMAC-SHA256 Access={ak}, SignedHeaders={sh}, Signature={sig}"
    )
    return headers


def _http(method: str, url: str, ak: str, sk: str, body: bytes = b"") -> tuple:
    headers = _sign(ak, sk, method, url, body)
    req = urllib.request.Request(url, data=body or None, method=method.upper())
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode() or "{}")
        except Exception:
            payload = {"raw": e.read().decode()}
        return e.code, payload


def _op_status(region: str, name: str, op_id: str, ak: str, sk: str) -> str:
    url = (
        f"https://rfs.{region}.myhuaweicloud.com"
        f"/v1/stack-sets/{name}/operations/{op_id}/metadata"
    )
    _, j = _http("GET", url, ak, sk)
    return (j.get("status") or "").upper()


def _wait(region: str, name: str, op_id: str, ak: str, sk: str, timeout: int = 600) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = _op_status(region, name, op_id, ak, sk)
        if st in ("OPERATION_COMPLETE", "COMPLETE", "SUCCESS", "SUCCEEDED"):
            return
        if st in ("OPERATION_FAILED", "FAILED", "STOPPED"):
            raise RuntimeError(f"operation {op_id} ended with status: {st}")
        time.sleep(5)
    raise TimeoutError(f"operation {op_id} exceeded {timeout}s timeout")


def _latest_op_id(region: str, name: str, ak: str, sk: str) -> str:
    """兜底：从操作列表取最近一次操作的 id（CreateStackInstance 响应未含 id 时用）。"""
    url = f"https://rfs.{region}.myhuaweicloud.com/v1/stack-sets/{name}/operations"
    _, j = _http("GET", url, ak, sk)
    ops = j.get("stack_set_operations") or j.get("operations") or []
    if not ops:
        raise RuntimeError(f"无法从响应或操作列表解析 operation id：{j}")
    ops.sort(key=lambda o: o.get("create_time", ""), reverse=True)
    return ops[0].get("stack_set_operation_id") or ops[0].get("operation_id")


def create(region: str, name: str, regions: list, domain_ids: list, ak: str, sk: str) -> None:
    # 幂等：栈集已有实例则跳过
    url = f"https://rfs.{region}.myhuaweicloud.com/v1/stack-sets/{name}/stack-instances"
    code, j = _http("GET", url, ak, sk)
    if code == 200:
        existing = j.get("stack_instances") or []
        if existing:
            print(f"[skip] 栈集 {name} 已有 {len(existing)} 个实例，跳过创建")
            return

    body = json.dumps(
        {"deployment_targets": {"regions": regions, "domain_ids": domain_ids}}
    ).encode()
    code, j = _http("POST", url, ak, sk, body)
    if code == 409:
        print("[skip] 实例已存在 (409)，跳过")
        return
    if code not in (200, 201, 202):
        raise RuntimeError(f"CreateStackInstance 失败 ({code}): {j}")
    op_id = j.get("stack_set_operation_id") or j.get("operation_id") or _latest_op_id(
        region, name, ak, sk
    )
    print(f"[create] operation {op_id} 已提交，等待完成…")
    _wait(region, name, op_id, ak, sk)
    print(f"[create] 栈集 {name} 实例创建完成")


def delete(region: str, name: str, regions: list, domain_ids: list, ak: str, sk: str) -> None:
    body = json.dumps(
        {"deployment_targets": {"regions": regions, "domain_ids": domain_ids}}
    ).encode()
    url = (
        f"https://rfs.{region}.myhuaweicloud.com"
        f"/v1/stack-sets/{name}/stack-instances/deletion"
    )
    code, j = _http("POST", url, ak, sk, body)
    if code == 409:
        print("[skip] 无实例可删 (409)")
        return
    if code not in (200, 201, 202):
        # 无实例时部分版本直接 4xx，视为已清理
        print(f"[skip] 删除未触发操作 ({code}): {j}")
        return
    op_id = j.get("stack_set_operation_id") or j.get("operation_id") or _latest_op_id(
        region, name, ak, sk
    )
    print(f"[delete] operation {op_id} 已提交，等待完成…")
    _wait(region, name, op_id, ak, sk)
    print(f"[delete] 栈集 {name} 实例删除完成")


def main() -> None:
    ap = argparse.ArgumentParser(description="RFS 资源栈集实例 创建/删除（签名 API 兜底）")
    ap.add_argument("--action", choices=["create", "delete"], required=True)
    ap.add_argument("--stack-set-name", required=True)
    ap.add_argument("--regions", required=True, help="逗号分隔，如 cn-north-4,cn-east-3")
    ap.add_argument("--domain-ids", required=True, help="逗号分隔的租户(domain) ID")
    ap.add_argument("--region", default=os.environ.get("HW_REGION_NAME", "cn-north-4"))
    a = ap.parse_args()

    ak = os.environ.get("HW_ACCESS_KEY")
    sk = os.environ.get("HW_SECRET_KEY")
    if not ak or not sk:
        sys.stderr.write("缺少环境变量 HW_ACCESS_KEY / HW_SECRET_KEY\n")
        sys.exit(2)

    regions = [x for x in a.regions.split(",") if x]
    domain_ids = [x for x in a.domain_ids.split(",") if x]
    if not regions:
        sys.stderr.write("--regions 不能为空\n")
        sys.exit(2)

    if a.action == "create":
        if not domain_ids:
            # SERVICE_MANAGED（按 OU 部署）本脚本不覆盖，交 deployment 资源处理；此处跳过避免误建
            print("[skip] SELF_MANAGED 未给 domain_ids，跳过实例创建（SERVICE_MANAGED 请走 OU 路径）")
            return
        create(a.region, a.stack_set_name, regions, domain_ids, ak, sk)
    else:
        if not domain_ids:
            print("[skip] 未给 domain_ids，跳过实例删除")
            return
        delete(a.region, a.stack_set_name, regions, domain_ids, ak, sk)


if __name__ == "__main__":
    main()
