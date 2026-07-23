// src/worker.js - 基于 Durable Objects 的共享聊天服务

export class ChatRoom {
    constructor(state, env) {
        this.state = state;
        this.env = env;
        this.onlineUsers = new Map();
    }

    async fetch(request) {
        const upgradeHeader = request.headers.get('Upgrade');
        if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
            return new Response('仅支持 WebSocket', { status: 400 });
        }

        const [client, server] = Object.values(new WebSocketPair());
        server.accept();

        let currentUser = null;

        const sendJSON = (ws, data) => {
            if (ws && ws.readyState === 1) {
                ws.send(JSON.stringify(data));
            }
        };

        const sendError = (code, message) => {
            sendJSON(server, { type: 'error', code, message });
        };

        server.addEventListener('message', async (event) => {
            let packet;
            try {
                packet = JSON.parse(event.data);
            } catch {
                sendError('INVALID_JSON', '消息必须是有效的 JSON');
                return;
            }

            console.log('收到消息:', packet.type);

            try {
                const { type, username, target, content } = packet;

                if (type === 'ping') {
                    sendJSON(server, { type: 'pong' });
                    return;
                }

                if (type === 'register') {
                    const normalizedUsername = typeof username === 'string' ? username.trim() : '';
                    if (!normalizedUsername) {
                        sendError('INVALID_USERNAME', '用户名不能为空');
                        return;
                    }

                    if (
                        currentUser &&
                        currentUser !== normalizedUsername &&
                        this.onlineUsers.get(currentUser) === server
                    ) {
                        this.onlineUsers.delete(currentUser);
                    }

                    const oldWs = this.onlineUsers.get(normalizedUsername);
                    if (oldWs && oldWs !== server) {
                        oldWs.close(1000, '该用户名已在其他客户端登录');
                    }

                    currentUser = normalizedUsername;
                    this.onlineUsers.set(normalizedUsername, server);
                    sendJSON(server, { type: 'registered', username: normalizedUsername });
                    console.log(`[上线] ${normalizedUsername}`);

                    const { results } = await this.env.DB.prepare(
                        'SELECT sender, content, msg_id FROM offline_msgs WHERE receiver = ?'
                    ).bind(normalizedUsername).all();

                    for (const row of results) {
                        sendJSON(server, {
                            type: 'message',
                            from: row.sender,
                            content: row.content,
                            msgId: row.msg_id,
                            isOffline: true
                        });

                        const senderWs = this.onlineUsers.get(row.sender);
                        if (senderWs) {
                            sendJSON(senderWs, {
                                type: 'receipt',
                                status: 'DELIVERED',
                                msgId: row.msg_id,
                                target: normalizedUsername
                            });
                        } else {
                            await this.env.DB.prepare(
                                'INSERT INTO receipt_queue (sender, msg_id, receiver) VALUES (?, ?, ?)'
                            ).bind(row.sender, row.msg_id, normalizedUsername).run();
                        }
                    }

                    await this.env.DB.prepare(
                        'DELETE FROM offline_msgs WHERE receiver = ?'
                    ).bind(normalizedUsername).run();

                    const { results: receiptRows } = await this.env.DB.prepare(
                        'SELECT receiver, msg_id FROM receipt_queue WHERE sender = ?'
                    ).bind(normalizedUsername).all();

                    for (const receipt of receiptRows) {
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'DELIVERED',
                            msgId: receipt.msg_id,
                            target: receipt.receiver
                        });
                    }

                    await this.env.DB.prepare(
                        'DELETE FROM receipt_queue WHERE sender = ?'
                    ).bind(normalizedUsername).run();
                    return;
                }

                if (type === 'message') {
                    if (!currentUser) {
                        sendError('NOT_REGISTERED', '请先注册用户名');
                        return;
                    }

                    const normalizedTarget = typeof target === 'string' ? target.trim() : '';
                    const normalizedContent = typeof content === 'string' ? content.trim() : '';
                    if (!normalizedTarget || !normalizedContent) {
                        sendError('INVALID_MESSAGE', '目标用户和消息内容不能为空');
                        return;
                    }

                    const msgId = `${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
                    const targetWs = this.onlineUsers.get(normalizedTarget);

                    if (targetWs) {
                        sendJSON(targetWs, {
                            type: 'message',
                            from: currentUser,
                            content: normalizedContent,
                            msgId,
                            isOffline: false
                        });
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'DELIVERED',
                            msgId,
                            target: normalizedTarget
                        });
                    } else {
                        await this.env.DB.prepare(
                            'INSERT INTO offline_msgs (receiver, sender, content, msg_id) VALUES (?, ?, ?, ?)'
                        ).bind(normalizedTarget, currentUser, normalizedContent, msgId).run();
                        sendJSON(server, {
                            type: 'receipt',
                            status: 'STORED',
                            msgId,
                            target: normalizedTarget
                        });
                    }
                    return;
                }

                sendError('UNKNOWN_TYPE', '不支持的消息类型');
            } catch (error) {
                console.error('处理消息失败:', error);
                sendError('SERVER_ERROR', '服务器处理消息失败');
            }
        });

        server.addEventListener('close', () => {
            if (currentUser && this.onlineUsers.get(currentUser) === server) {
                this.onlineUsers.delete(currentUser);
                console.log(`[下线] ${currentUser}`);
            }
        });

        return new Response(null, { status: 101, webSocket: client });
    }
}

export default {
    async fetch(request, env) {
        const id = env.CHAT_ROOM.idFromName('global-room');
        return env.CHAT_ROOM.get(id).fetch(request);
    }
};
