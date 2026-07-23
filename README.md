# Cloudflare WebSocket 聊天服务

这是一个基于 Cloudflare Workers、Durable Objects 和 D1 的点对点聊天服务，支持在线消息、离线消息和送达回执。

## 终端客户端

要求 Node.js 22 或更高版本，无需安装第三方依赖。

```powershell
node terminal-client.mjs alice
```

如需连接其他服务器地址：

```powershell
node terminal-client.mjs alice ws://127.0.0.1:8787
```

启动两个终端，分别使用不同用户名。进入客户端后可以使用：

```text
/msg bob 你好
/to bob
设置默认接收者后可直接输入消息
/help
/quit
```

也可以通过 npm 传递参数：

```powershell
npm run client -- alice
```

## 测试

```powershell
npm test
```

## 部署

确认 `wrangler.toml` 中的 D1 数据库属于当前 Cloudflare 账户，并确保数据库已创建以下两张表：

```sql
CREATE TABLE IF NOT EXISTS offline_msgs (
    receiver TEXT NOT NULL,
    sender TEXT NOT NULL,
    content TEXT NOT NULL,
    msg_id TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS receipt_queue (
    sender TEXT NOT NULL,
    msg_id TEXT NOT NULL,
    receiver TEXT NOT NULL
);
```

然后部署：

```powershell
npx wrangler deploy
```
