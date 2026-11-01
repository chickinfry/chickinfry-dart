import '../errors.dart';
import 'persist.dart';
import 'store.dart';

DeviceStore openDevice(DeviceScope scope, Persist? persist) =>
    throw const ClientError('failed_precondition');

String resolveDirectory(String directory) =>
    throw const ClientError('failed_precondition');
