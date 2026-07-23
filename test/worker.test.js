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
