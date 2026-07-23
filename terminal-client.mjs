import readline from 'node:readline';

const DEFAULT_SERVER = 'wss://server.jasonrhan.cn';
const username = process.argv[2]?.trim();
const serverUrl = process.argv[3]?.trim() || DEFAULT_SERVER;

if (!username) {
    console.error('用法: node terminal-client.mjs <用户名> [WebSocket地址]');
    console.error('示例: node terminal-client.mjs alice');
    process.exit(1);
}

let socket;
let heartbeat;
let reconnectTimer;
let activeTarget = '';
let isClosing = false;

const terminal = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: '> '
});

function printHelp() {
    console.log('命令:');
    console.log('  /msg <用户> <内容>  发送一条消息');
    console.log('  /to <用户>         设置默认接收者');
    console.log('  /help              显示帮助');
    console.log('  /quit              退出客户端');
    console.log('设置默认接收者后，直接输入文字即可发送。');
}

function send(data) {
    if (!socket || socket.readyState !== WebSocket.OPEN) {
        console.log('尚未连接服务器，请稍后重试。');
        return false;
    }
    socket.send(JSON.stringify(data));
    return true;
}

function sendMessage(target, content) {
    if (send({ type: 'message', target, content })) {
        console.log(`你 -> ${target}: ${content}`);
    }
}

function handleServerMessage(rawData) {
    let data;
    try {
        data = JSON.parse(String(rawData));
    } catch {
        console.log('收到无法解析的服务器消息。');
        return;
    }

    if (data.type === 'registered') {
        console.log(`已注册为 ${data.username}`);
    } else if (data.type === 'message') {
        const offlineMark = data.isOffline ? ' [离线消息]' : '';
        console.log(`\n${data.from} -> 你${offlineMark}: ${data.content}`);
    } else if (data.type === 'receipt') {
        const status = data.status === 'DELIVERED' ? '已送达' : '已离线保存';
        console.log(`\n回执: 发给 ${data.target} 的消息${status}`);
    } else if (data.type === 'error') {
        console.log(`\n服务器错误 [${data.code}]: ${data.message}`);
    }

    terminal.prompt(true);
}

function connect() {
    console.log(`正在连接 ${serverUrl} ...`);
    socket = new WebSocket(serverUrl);

    socket.addEventListener('open', () => {
        console.log('已连接服务器。');
        send({ type: 'register', username });
        clearInterval(heartbeat);
        heartbeat = setInterval(() => send({ type: 'ping' }), 30000);
        terminal.prompt();
    });

    socket.addEventListener('message', (event) => {
        handleServerMessage(event.data);
    });

    socket.addEventListener('error', () => {
        console.log('\n连接发生错误。');
    });

    socket.addEventListener('close', (event) => {
        clearInterval(heartbeat);
        if (isClosing) return;
        console.log(`\n连接已断开（代码 ${event.code}），3 秒后重连。`);
        clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(connect, 3000);
    });
}

terminal.on('line', (input) => {
    const line = input.trim();
    if (!line) {
        terminal.prompt();
        return;
    }

    if (line === '/quit') {
        isClosing = true;
        clearTimeout(reconnectTimer);
        clearInterval(heartbeat);
        socket?.close(1000, '客户端退出');
        terminal.close();
        return;
    }

    if (line === '/help') {
        printHelp();
    } else if (line.startsWith('/to ')) {
        activeTarget = line.slice(4).trim();
        console.log(activeTarget ? `默认接收者已设为 ${activeTarget}` : '接收者不能为空。');
    } else if (line.startsWith('/msg ')) {
        const match = line.match(/^\/msg\s+(\S+)\s+(.+)$/);
        if (match) {
            sendMessage(match[1], match[2]);
        } else {
            console.log('格式: /msg <用户> <内容>');
        }
    } else if (line.startsWith('/')) {
        console.log('未知命令，输入 /help 查看帮助。');
    } else if (activeTarget) {
        sendMessage(activeTarget, line);
    } else {
        console.log('请先使用 /to <用户>，或使用 /msg <用户> <内容>。');
    }

    terminal.prompt();
});

terminal.on('close', () => {
    process.exit(0);
});

console.log(`终端聊天客户端，当前用户: ${username}`);
printHelp();
connect();
