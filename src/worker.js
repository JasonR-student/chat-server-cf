// src/worker.js - 云原生聊天转发服务（Node.js 风格）

// 全局内存缓存（在线用户 WebSocket 连接）
// 注意：实际生产中多机房可用 Durable Objects，这里先做单机测试
const onlineUsers = new Map(); // { username: WebSocket }

export default {
    async fetch(request, env, ctx) {
        // 1. 只处理 WebSocket 升级请求
        const upgradeHeader = request.headers.get('Upgrade');
        if (upgradeHeader !== 'websocket') {
            return new Response('此路径仅接受 WebSocket 连接', { status: 400 });
        }

        // 2. 创建 WebSocket 对
        const [client, server] = Object.values(new WebSocketPair());
        server.accept();

        // ============== 核心业务逻辑 ==============
        let currentUser = null; // 当前连接的用户名

        // 辅助：生成唯一消息 ID
        function generateMsgId() {
            return Date.now() + '_' + Math.random().toString(36).substring(2, 6);
        }

        // 辅助：向客户端发送 JSON
        function sendJSON(ws, data) {
            if (ws && ws.readyState === 1) {
                ws.send(JSON.stringify(data));
            }
        }

        // ===== 接收客户端消息 =====
        server.addEventListener('message', async (event) => {
            try {
                const packet = JSON.parse(event.data);
                const { type, username, target, content } = packet;

                // --- 1. 注册/上线 ---
                if (type === 'register') {
                    currentUser = username;
                    // 踢掉旧的同名连接
                    if (onlineUsers.has(username)) {
                        const old = onlineUsers.get(username);
                        if (old !== server) old.close();
                    }
                    onlineUsers.set(username, server);
                    console.log(`[上线] ${username}`);

                    // 从 D1 数据库拉取离线消息
                    const { results } = await env.DB.prepare(
                        `SELECT sender, content, msg_id FROM offline_msgs WHERE receiver = ?`
                    ).bind(username).all();

                    for (const row of results) {
                        // 推送离线消息给当前上线的用户
                        sendJSON(server, {
                            type: 'message',
                            from: row.sender,
                            content: row.content,
                            msgId: row.msg_id,
                            isOffline: true
                        });

                        // 检查发送方是否在线，产生“已送达”回执
                        const senderWs = onlineUsers.get(row.sender);
                        if (senderWs) {
                            sendJSON(senderWs, {
                                type: 'receipt',
                                status: 'DELIVERED',
                                msgId: row.msg_id,
                                target: username
                            });
                        } else {
                            // 发送方不在线，将回执存入 D1
                            await env.DB.prepare(
                                `INSERT INTO receipt_queue (sender, msg_id, receiver) VALUES (?, ?, ?)`
                            ).bind(row.sender, row.msg_id, username).run();
                        }
                    }

                    // 删除已推送的离线消息
                    await env.DB.prepare(
                        `DELETE FROM offline_msgs WHERE receiver = ?`
                    ).bind(username).run();

                    // 推送历史未读回执（当发送方之前离线，现在上线时）
                    const receiptRows = await env.DB.prepare(
                        `SELECT receiver, msg_id FROM receipt_queue WHERE sender = ?`
                    ).bind(username).all();

                    for (const r of receiptRows) {
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'PENDING',
                            msg: `您发给 ${r.receiver} 的消息已成功送达 (ID:${r.msg_id})`
                        });
                    }
                    // 清空回执队列
                    await env.DB.prepare(
                        `DELETE FROM receipt_queue WHERE sender = ?`
                    ).bind(username).run();
                }

                // --- 2. 发送消息（A -> B） ---
                if (type === 'message') {
                    const sender = currentUser;
                    if (!sender) return;
                    const msgId = generateMsgId();

                    const targetWs = onlineUsers.get(target);
                    if (targetWs) {
                        // B 在线：直接转发
                        sendJSON(targetWs, {
                            type: 'message',
                            from: sender,
                            content: content,
                            msgId: msgId,
                            isOffline: false
                        });
                        // 给 A 回执：已送达
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'DELIVERED',
                            msgId: msgId,
                            target: target
                        });
                    } else {
                        // B 离线：存入 D1 离线消息表
                        await env.DB.prepare(
                            `INSERT INTO offline_msgs (receiver, sender, content, msg_id) VALUES (?, ?, ?, ?)`
                        ).bind(target, sender, content, msgId).run();

                        // 给 A 回执：已暂存
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'STORED',
                            msgId: msgId,
                            target: target
                        });
                    }
                }
            } catch (e) {
                console.error('解析错误:', e);
            }
        });

        // ===== 连接断开 =====
        server.addEventListener('close', () => {
            if (currentUser) {
                onlineUsers.delete(currentUser);
                console.log(`[下线] ${currentUser}`);
            }
        });

        return new Response(null, { status: 101, webSocket: client });
    }
};