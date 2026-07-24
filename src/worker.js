// src/worker.js - 基于 Durable Objects 的共享聊天服务

export class ChatRoom {
    constructor(state, env) {
        this.state = state;
        this.env = env;
        this.onlineUsers = new Map();
        this.groups = new Map();
        this.databaseReady = null;
    }

    sendJSON(ws, data) {
        if (ws && ws.readyState === 1) {
            ws.send(JSON.stringify(data));
        }
    }

    async ensureDatabaseSchema() {
        if (!this.databaseReady) {
            const statements = [
                `CREATE TABLE IF NOT EXISTS offline_msgs (
                    receiver TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    content TEXT NOT NULL,
                    msg_id TEXT PRIMARY KEY
                )`,
                `CREATE TABLE IF NOT EXISTS receipt_queue (
                    sender TEXT NOT NULL,
                    msg_id TEXT NOT NULL,
                    receiver TEXT NOT NULL
                )`,
                'CREATE INDEX IF NOT EXISTS idx_offline_msgs_receiver ON offline_msgs(receiver)',
                'CREATE INDEX IF NOT EXISTS idx_receipt_queue_sender ON receipt_queue(sender)'
            ];

            this.databaseReady = (async () => {
                for (const sql of statements) {
                    await this.env.DB.prepare(sql).bind().run();
                }
            })();
        }

        try {
            await this.databaseReady;
        } catch (error) {
            this.databaseReady = null;
            throw error;
        }
    }

    async restoreOfflineState(username, ws) {
        await this.ensureDatabaseSchema();

        const { results } = await this.env.DB.prepare(
            'SELECT sender, content, msg_id FROM offline_msgs WHERE receiver = ?'
        ).bind(username).all();

        for (const row of results) {
            this.sendJSON(ws, {
                type: 'message',
                from: row.sender,
                content: row.content,
                msgId: row.msg_id,
                isOffline: true
            });

            const senderWs = this.onlineUsers.get(row.sender);
            if (senderWs) {
                this.sendJSON(senderWs, {
                    type: 'receipt',
                    status: 'DELIVERED',
                    msgId: row.msg_id,
                    target: username
                });
            } else {
                await this.env.DB.prepare(
                    'INSERT INTO receipt_queue (sender, msg_id, receiver) VALUES (?, ?, ?)'
                ).bind(row.sender, row.msg_id, username).run();
            }
        }

        await this.env.DB.prepare(
            'DELETE FROM offline_msgs WHERE receiver = ?'
        ).bind(username).run();

        const { results: receiptRows } = await this.env.DB.prepare(
            'SELECT receiver, msg_id FROM receipt_queue WHERE sender = ?'
        ).bind(username).all();

        for (const receipt of receiptRows) {
            this.sendJSON(ws, {
                type: 'receipt',
                status: 'DELIVERED',
                msgId: receipt.msg_id,
                target: receipt.receiver
            });
        }

        await this.env.DB.prepare(
            'DELETE FROM receipt_queue WHERE sender = ?'
        ).bind(username).run();
    }

    getOrCreateGroup(groupName) {
        let members = this.groups.get(groupName);
        if (!members) {
            members = new Set();
            this.groups.set(groupName, members);
        }
        return members;
    }

    broadcastGroup(groupName, packet, exceptWs = null) {
        const members = this.groups.get(groupName);
        if (!members) return;

        for (const memberWs of members) {
            if (memberWs !== exceptWs) {
                this.sendJSON(memberWs, packet);
            }
        }
    }

    removeGroupMember(groupName, ws) {
        const members = this.groups.get(groupName);
        if (!members) return 0;

        members.delete(ws);
        if (members.size === 0) {
            this.groups.delete(groupName);
            return 0;
        }
        return members.size;
    }

    async fetch(request) {
        const upgradeHeader = request.headers.get('Upgrade');
        if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
            return new Response('仅支持 WebSocket', { status: 400 });
        }

        const [client, server] = Object.values(new WebSocketPair());
        server.accept();

        let currentUser = null;
        const joinedGroups = new Set();

        const sendError = (code, message) => {
            this.sendJSON(server, { type: 'error', code, message });
        };

        const leaveGroup = (groupName, username, notifyCurrentSocket) => {
            if (!joinedGroups.has(groupName)) return;

            joinedGroups.delete(groupName);
            const memberCount = this.removeGroupMember(groupName, server);
            if (notifyCurrentSocket) {
                this.sendJSON(server, {
                    type: 'group_left',
                    group: groupName,
                    memberCount
                });
            }
            this.broadcastGroup(groupName, {
                type: 'group_presence',
                action: 'left',
                group: groupName,
                username,
                memberCount
            });
        };

        const leaveAllGroups = (username) => {
            for (const groupName of [...joinedGroups]) {
                leaveGroup(groupName, username, false);
            }
        };

        server.addEventListener('message', async (event) => {
            let packet;
            try {
                packet = JSON.parse(event.data);
            } catch {
                sendError('INVALID_JSON', '消息必须是有效的 JSON');
                return;
            }

            const { type, username, target, content, group } = packet;
            console.log('收到消息:', type);

            try {
                if (type === 'ping') {
                    this.sendJSON(server, { type: 'pong' });
                    return;
                }

                if (type === 'register') {
                    const normalizedUsername =
                        typeof username === 'string' ? username.trim() : '';
                    if (!normalizedUsername) {
                        sendError('INVALID_USERNAME', '用户名不能为空');
                        return;
                    }

                    if (currentUser && currentUser !== normalizedUsername) {
                        leaveAllGroups(currentUser);
                        if (this.onlineUsers.get(currentUser) === server) {
                            this.onlineUsers.delete(currentUser);
                        }
                    }

                    const oldWs = this.onlineUsers.get(normalizedUsername);
                    if (oldWs && oldWs !== server) {
                        oldWs.close(1000, '该用户名已在其他客户端登录');
                    }

                    currentUser = normalizedUsername;
                    this.onlineUsers.set(normalizedUsername, server);
                    this.sendJSON(server, {
                        type: 'registered',
                        username: normalizedUsername
                    });
                    console.log(`[上线] ${normalizedUsername}`);

                    try {
                        await this.restoreOfflineState(normalizedUsername, server);
                    } catch (error) {
                        console.error('恢复离线消息失败:', error);
                        this.sendJSON(server, {
                            type: 'warning',
                            code: 'OFFLINE_STORAGE_UNAVAILABLE',
                            message: '已正常上线，但离线消息暂时不可用'
                        });
                    }
                    return;
                }

                if (!currentUser) {
                    sendError('NOT_REGISTERED', '请先注册用户名');
                    return;
                }

                if (type === 'join_group') {
                    const normalizedGroup =
                        typeof group === 'string' ? group.trim() : '';
                    if (!normalizedGroup) {
                        sendError('INVALID_GROUP', '群聊名称不能为空');
                        return;
                    }

                    const alreadyJoined = joinedGroups.has(normalizedGroup);
                    const members = this.getOrCreateGroup(normalizedGroup);
                    members.add(server);
                    joinedGroups.add(normalizedGroup);
                    this.sendJSON(server, {
                        type: 'group_joined',
                        group: normalizedGroup,
                        memberCount: members.size
                    });
                    if (!alreadyJoined) {
                        this.broadcastGroup(normalizedGroup, {
                            type: 'group_presence',
                            action: 'joined',
                            group: normalizedGroup,
                            username: currentUser,
                            memberCount: members.size
                        }, server);
                    }
                    return;
                }

                if (type === 'leave_group') {
                    const normalizedGroup =
                        typeof group === 'string' ? group.trim() : '';
                    if (!normalizedGroup || !joinedGroups.has(normalizedGroup)) {
                        sendError('NOT_IN_GROUP', '尚未加入该群聊');
                        return;
                    }
                    leaveGroup(normalizedGroup, currentUser, true);
                    return;
                }

                if (type === 'group_message') {
                    const normalizedGroup =
                        typeof group === 'string' ? group.trim() : '';
                    const normalizedContent =
                        typeof content === 'string' ? content.trim() : '';
                    if (!normalizedGroup || !normalizedContent) {
                        sendError('INVALID_GROUP_MESSAGE', '群聊名称和消息内容不能为空');
                        return;
                    }
                    if (!joinedGroups.has(normalizedGroup)) {
                        sendError('NOT_IN_GROUP', '请先加入该群聊');
                        return;
                    }

                    const msgId = crypto.randomUUID();
                    this.broadcastGroup(normalizedGroup, {
                        type: 'group_message',
                        group: normalizedGroup,
                        from: currentUser,
                        content: normalizedContent,
                        msgId
                    });
                    return;
                }

                if (type === 'message') {
                    const normalizedTarget =
                        typeof target === 'string' ? target.trim() : '';
                    const normalizedContent =
                        typeof content === 'string' ? content.trim() : '';
                    if (!normalizedTarget || !normalizedContent) {
                        sendError('INVALID_MESSAGE', '目标用户和消息内容不能为空');
                        return;
                    }

                    const msgId = crypto.randomUUID();
                    const targetWs = this.onlineUsers.get(normalizedTarget);

                    if (targetWs) {
                        this.sendJSON(targetWs, {
                            type: 'message',
                            from: currentUser,
                            content: normalizedContent,
                            msgId,
                            isOffline: false
                        });
                        this.sendJSON(server, {
                            type: 'receipt',
                            status: 'DELIVERED',
                            msgId,
                            target: normalizedTarget
                        });
                    } else {
                        try {
                            await this.ensureDatabaseSchema();
                            await this.env.DB.prepare(
                                'INSERT INTO offline_msgs (receiver, sender, content, msg_id) VALUES (?, ?, ?, ?)'
                            ).bind(
                                normalizedTarget,
                                currentUser,
                                normalizedContent,
                                msgId
                            ).run();
                            this.sendJSON(server, {
                                type: 'receipt',
                                status: 'STORED',
                                msgId,
                                target: normalizedTarget
                            });
                        } catch (error) {
                            console.error('保存离线消息失败:', error);
                            sendError(
                                'OFFLINE_STORAGE_ERROR',
                                '目标用户不在线，且离线消息保存失败'
                            );
                        }
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
            if (currentUser) {
                leaveAllGroups(currentUser);
                if (this.onlineUsers.get(currentUser) === server) {
                    this.onlineUsers.delete(currentUser);
                }
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
