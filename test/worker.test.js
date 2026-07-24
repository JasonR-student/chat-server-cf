import assert from 'node:assert/strict';
import test from 'node:test';

class FakeSocket {
    constructor() {
        this.readyState = 1;
        this.sent = [];
        this.listeners = new Map();
    }

    accept() {}

    send(data) {
        this.sent.push(JSON.parse(data));
    }

    close() {
        this.readyState = 3;
    }

    addEventListener(type, listener) {
        this.listeners.set(type, listener);
    }

    async emit(type, data) {
        await this.listeners.get(type)?.({ data });
    }
}

class FakeDatabase {
    prepare(sql) {
        return {
            bind: (...values) => ({
                all: async () => ({ results: [] }),
                run: async () => ({ success: true, sql, values })
            })
        };
    }
}

class FailingDatabase {
    prepare() {
        return {
            bind: () => ({
                all: async () => {
                    throw new Error('database unavailable');
                },
                run: async () => {
                    throw new Error('database unavailable');
                }
            })
        };
    }
}

const pairs = [];

globalThis.WebSocketPair = class {
    constructor() {
        const pair = { 0: new FakeSocket(), 1: new FakeSocket() };
        pairs.push(pair);
        return pair;
    }
};

globalThis.Response = class {
    constructor(body, init = {}) {
        this.body = body;
        Object.assign(this, init);
    }
};

const { ChatRoom } = await import('../src/worker.js');

function request() {
    return { headers: { get: () => 'websocket' } };
}

function lastServer() {
    return pairs.at(-1)[1];
}

test('WebSocket 请求能够完成升级', async () => {
    const room = new ChatRoom({}, { DB: new FakeDatabase() });
    const response = await room.fetch(request());

    assert.equal(response.status, 101);
    assert.ok(response.webSocket);
});

test('注册后可以向在线用户发送消息并收到回执', async () => {
    const room = new ChatRoom({}, { DB: new FakeDatabase() });

    await room.fetch(request());
    const alice = lastServer();
    await alice.emit('message', JSON.stringify({ type: 'register', username: 'alice' }));

    await room.fetch(request());
    const bob = lastServer();
    await bob.emit('message', JSON.stringify({ type: 'register', username: 'bob' }));

    await alice.emit('message', JSON.stringify({
        type: 'message',
        target: 'bob',
        content: '你好'
    }));

    assert.equal(alice.sent[0].type, 'registered');
    assert.equal(bob.sent[0].type, 'registered');
    assert.equal(alice.sent.some((packet) => packet.code === 'SERVER_ERROR'), false);
    assert.equal(bob.sent.some((packet) => packet.code === 'SERVER_ERROR'), false);
    assert.deepEqual(
        { type: bob.sent[1].type, from: bob.sent[1].from, content: bob.sent[1].content },
        { type: 'message', from: 'alice', content: '你好' }
    );
    assert.equal(alice.sent.at(-1).status, 'DELIVERED');
});

test('旧的同名连接关闭时不会删除新连接', async () => {
    const room = new ChatRoom({}, { DB: new FakeDatabase() });

    await room.fetch(request());
    const oldSocket = lastServer();
    await oldSocket.emit('message', JSON.stringify({ type: 'register', username: 'alice' }));

    await room.fetch(request());
    const newSocket = lastServer();
    await newSocket.emit('message', JSON.stringify({ type: 'register', username: 'alice' }));
    await oldSocket.emit('close');

    assert.equal(room.onlineUsers.get('alice'), newSocket);
});

test('心跳请求返回 pong', async () => {
    const room = new ChatRoom({}, { DB: new FakeDatabase() });

    await room.fetch(request());
    const socket = lastServer();
    await socket.emit('message', JSON.stringify({ type: 'ping' }));

    assert.deepEqual(socket.sent, [{ type: 'pong' }]);
});

test('离线数据库失败不阻断首次注册', async () => {
    const room = new ChatRoom({}, { DB: new FailingDatabase() });

    await room.fetch(request());
    const socket = lastServer();
    await socket.emit('message', JSON.stringify({ type: 'register', username: 'alice' }));

    assert.equal(socket.sent[0].type, 'registered');
    assert.equal(socket.sent[1].type, 'warning');
    assert.equal(socket.sent[1].code, 'OFFLINE_STORAGE_UNAVAILABLE');
    assert.equal(socket.sent.some((packet) => packet.code === 'SERVER_ERROR'), false);
    assert.equal(room.onlineUsers.get('alice'), socket);
});

test('同一群聊中的成员可以广播消息', async () => {
    const room = new ChatRoom({}, { DB: new FakeDatabase() });

    await room.fetch(request());
    const alice = lastServer();
    await alice.emit('message', JSON.stringify({ type: 'register', username: 'alice' }));

    await room.fetch(request());
    const bob = lastServer();
    await bob.emit('message', JSON.stringify({ type: 'register', username: 'bob' }));

    await room.fetch(request());
    const carol = lastServer();
    await carol.emit('message', JSON.stringify({ type: 'register', username: 'carol' }));

    await alice.emit('message', JSON.stringify({ type: 'join_group', group: '研发群' }));
    await bob.emit('message', JSON.stringify({ type: 'join_group', group: '研发群' }));

    assert.equal(alice.sent.find((packet) => packet.type === 'group_joined').memberCount, 1);
    assert.equal(bob.sent.find((packet) => packet.type === 'group_joined').memberCount, 2);

    alice.sent.length = 0;
    bob.sent.length = 0;
    carol.sent.length = 0;

    await alice.emit('message', JSON.stringify({
        type: 'group_message',
        group: '研发群',
        content: '大家好'
    }));

    assert.deepEqual(
        {
            type: alice.sent[0].type,
            group: alice.sent[0].group,
            from: alice.sent[0].from,
            content: alice.sent[0].content
        },
        {
            type: 'group_message',
            group: '研发群',
            from: 'alice',
            content: '大家好'
        }
    );
    assert.equal(bob.sent[0].type, 'group_message');
    assert.equal(carol.sent.length, 0);
});
