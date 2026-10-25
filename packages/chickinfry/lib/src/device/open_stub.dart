import '../errors.dart';
import 'persist.dart';
import 'store.dart';

DeviceStore openDevice(DeviceScope scope, Persist? persist) =>
    throw const ClientException('device_storage_unavailable');

String resolveDirectory(String directory) =>
    throw const ClientException('device_storage_unavailable');
