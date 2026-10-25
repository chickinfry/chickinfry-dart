import 'package:http/http.dart' as http;

Future<String> loadInputStructure() =>
    http.read(Uri.base.resolve('fixtures/input-structure.json'));
