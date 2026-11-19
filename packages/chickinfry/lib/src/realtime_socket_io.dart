import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

(WebSocketChannel, void Function()) openRealtimeSocket(Uri address) {
  final client = _UpgradeClient();
  return (
    IOWebSocketChannel.connect(address, customClient: client),
    () => client.close(force: true),
  );
}

// WebSocket.connect delegates its upgrade GET to this client. The ticket stays
// on the validated endpoint, even if it responds with a redirect.
final class _UpgradeClient implements HttpClient {
  final _client = HttpClient();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      (await _client.openUrl(method, url))..followRedirects = false;

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
