import 'package:web_socket_channel/web_socket_channel.dart';

(WebSocketChannel, void Function()) openRealtimeSocket(Uri address) =>
    (WebSocketChannel.connect(address), () {});
