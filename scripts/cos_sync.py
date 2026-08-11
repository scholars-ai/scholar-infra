#!/usr/bin/env python3
"""COS 离机副本：上传备份、列举、下载、清理过期远端副本（ADR-004）。

为什么不用 coscli：它在下载前会做一次桶级 HEAD 探测，需要 `cos:HeadBucket` 权限。
我们的子账号只授了对象级权限（更小的权限面），官方 SDK 的 GetObject/ListObjects
在该权限集下工作正常，故直接用 SDK，同时少一个二进制依赖。

凭证从 secrets/backup.env 读取，绝不接受命令行传参（避免进入进程列表）。

用法：
    cos_sync.py put <本地文件> [<远端key>]
    cos_sync.py list [<前缀>]
    cos_sync.py get <远端key> <本地文件>
    cos_sync.py prune <前缀> <保留份数>
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from qcloud_cos import CosConfig, CosS3Client

SECRETS = Path(__file__).resolve().parent.parent / "secrets" / "backup.env"


def _env() -> dict[str, str]:
    """从 secrets/backup.env 读凭证；缺失即报错而不是静默跳过上传。"""
    if not SECRETS.exists():
        sys.exit(f"missing {SECRETS}")
    cfg: dict[str, str] = {}
    for line in SECRETS.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()
    for key in ("COS_SECRET_ID", "COS_SECRET_KEY", "COS_REGION", "COS_BUCKET"):
        if not cfg.get(key):
            sys.exit(f"{key} not set in {SECRETS}")
    return cfg


def _list(client: CosS3Client, bucket: str, key_prefix: str) -> list[dict[str, str]]:
    """列举并在客户端按前缀过滤。

    不用服务端的 Prefix 参数：实测本子账号的策略下带 Prefix 的 GetBucket 返回
    AccessDenied，而不带 Prefix 正常。对象数量很少，客户端过滤无性能影响。
    """
    resp = client.list_objects(Bucket=bucket, MaxKeys=1000)
    return [o for o in resp.get("Contents", []) if str(o["Key"]).startswith(key_prefix)]


def _client(cfg: dict[str, str]) -> CosS3Client:
    return CosS3Client(
        CosConfig(
            Region=cfg["COS_REGION"],
            SecretId=cfg["COS_SECRET_ID"],
            SecretKey=cfg["COS_SECRET_KEY"],
            Scheme="https",
        )
    )


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    cfg = _env()
    client = _client(cfg)
    bucket = cfg["COS_BUCKET"]
    prefix = cfg.get("COS_PREFIX", "db/")

    if cmd == "put":
        local = Path(sys.argv[2])
        key = sys.argv[3] if len(sys.argv) > 3 else f"{prefix}{local.name}"
        local_size = local.stat().st_size
        # 用 put_object（单请求 PUT）而不是 upload_file：后者对大文件会自动改走
        # 分片上传，需要 ListMultipartUploads/InitiateMultipartUpload 等额外权限，
        # 而我们的子账号只授了对象级权限。单请求 PUT 上限 5GB，远超备份体积。
        if local_size > 5 * 1024**3:
            sys.exit(
                f"{local.name} is {local_size}B (> 5GB single-PUT limit); "
                "需要为子账号补授分片上传权限并改用 upload_file"
            )
        with local.open("rb") as fp:
            client.put_object(Bucket=bucket, Key=key, Body=fp)
        # 回读校验大小，确认对象真的落地（只写不验的备份等于没备份）
        head = client.head_object(Bucket=bucket, Key=key)
        remote_size = int(head["Content-Length"])
        if remote_size != local_size:
            sys.exit(f"size mismatch: local={local_size} remote={remote_size}")
        print(f"uploaded {key} ({remote_size}B, verified)")

    elif cmd == "list":
        for obj in _list(client, bucket, sys.argv[2] if len(sys.argv) > 2 else prefix):
            print(f"{obj['LastModified']}  {int(obj['Size']):>10}B  {obj['Key']}")

    elif cmd == "get":
        key, dest = sys.argv[2], sys.argv[3]
        resp = client.get_object(Bucket=bucket, Key=key)
        resp["Body"].get_stream_to_file(dest)
        print(f"downloaded {key} -> {dest} ({Path(dest).stat().st_size}B)")

    elif cmd == "prune":
        p, keep = sys.argv[2], int(sys.argv[3])
        objs = sorted(
            _list(client, bucket, p), key=lambda o: str(o["LastModified"]), reverse=True
        )
        for obj in objs[keep:]:
            client.delete_object(Bucket=bucket, Key=obj["Key"])
            print(f"pruned remote {obj['Key']}")

    else:
        sys.exit(f"unknown command: {cmd}\n{__doc__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
