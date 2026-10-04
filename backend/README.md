# B0 开发传输骨架

这是仅监听 `127.0.0.1` 的本机开发服务，使用 Python 标准库，不连接行情、AI 或购买提供方，也不保存请求内容或密钥。有效的报价与交易草稿请求分别返回 `PROVIDER_NOT_CONFIGURED` 和 `AI_NOT_CONFIGURED`。

启动：

```powershell
python backend/dev_server.py --port 8765
```

实际 HTTP 回环测试：

```powershell
python -m unittest backend.test_dev_server -v
```

契约见 `contracts/openapi/dev_backend_v1.openapi.json`。交易草稿接口只允许当前一句输入与临时候选别名；服务不会生成草稿或修改账本。客户端本地草稿解析和人工确认仍为独立流程。

此服务不得暴露到外网或用于生产。生产后端尚缺 HTTPS、鉴权与设备授权、持久幂等存储、PostgreSQL 迁移与恢复、合法行情许可和适配器、AI 提供方及隐私核查、购买验证、限流与运维。当前接口对幂等键仅做格式校验，因为无状态操作只返回未配置错误。
