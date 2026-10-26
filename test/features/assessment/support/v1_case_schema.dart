import 'dart:convert';
import 'dart:io';

import '../../../support/contract_schema.dart';

Map<String, dynamic> readCaseSchema() =>
    jsonDecode(File('contracts/v1/case.schema.json').readAsStringSync())
        as Map<String, dynamic>;

bool acceptsCaseDef(Object? value, String def) {
  final Map<String, dynamic> root = readCaseSchema();
  final Object? rule = (root[r'$defs'] as Map<String, dynamic>)[def];
  return acceptsContract(value, rule, {'case.schema.json': root}, root);
}

bool acceptsCase(Object? value) {
  final Map<String, dynamic> root = readCaseSchema();
  return acceptsContract(value, root, {'case.schema.json': root}, root);
}
