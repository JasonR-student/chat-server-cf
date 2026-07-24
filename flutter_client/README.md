# Flutter 聊天客户端

该前端连接 `wss://server.jasonrhan.cn`，实现：

- 用户名注册和在线状态；
- 指定目标用户发送消息；
- 接收实时及离线消息；
- 显示送达、离线保存和错误回执；
- 私聊与在线群聊切换；
- 30 秒心跳和断线自动重连；
- 响应式桌面与移动端布局。

## 一键运行包

Release ZIP 解压后，双击 `启动客户端.cmd`。启动器使用 Windows 自带
PowerShell 提供本地静态服务，会在 `8080-9000` 范围内自动选择可用端口并
打开默认浏览器，不依赖 Python、Node.js 或已安装的 Flutter SDK。

群聊使用方式：多位用户输入同一个群聊名称，点击“加入群聊”，加入后即可
向所有当前在线群成员广播消息。

## 运行

需要 Flutter 3.24 或更高版本。

```powershell
cd flutter_client
flutter pub get
flutter run -d chrome
```

生产构建：

```powershell
flutter build web --release
```

输出目录为 `build/web`。

## 测试

```powershell
flutter analyze
flutter test
```

当前工程包含 Flutter Web 平台文件。`lib` 内的通信和界面代码使用跨平台 API；安装 Flutter SDK 后，可执行以下命令补充其他平台壳：

```powershell
flutter create --platforms=android,windows .
```
