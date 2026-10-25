import 'dart:io';

Future<String> loadInputStructure() =>
    File('test/fixtures/input-structure.json').readAsString();
