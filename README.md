# Cloudflare WebSocket 聊天服务

这是一个基于 Cloudflare Workers、Durable Objects 和 D1 的点对点聊天服务，支持在线消息、离线消息和送达回执。

## Flutter 前端

响应式 Flutter Web 客户端位于 [`flutter_client`](flutter_client)，支持用户名注册、私聊、在线群聊、接收消息、回执、心跳、断线重连和自动选端口的一键启动包。

```powershell
cd flutter_client
flutter pub get
flutter run -d chrome
```

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

确认 `wrangler.toml` 中的 D1 数据库属于当前 Cloudflare 账户。服务端会在首次使用离线消息时自动创建表，也可在部署前主动执行迁移：

```powershell
npx wrangler d1 migrations apply chat_db --remote
```

然后部署：

```powershell
npx wrangler deploy
```
