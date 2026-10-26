import 'dart:convert';
import 'dart:io';
import 'package:safe_at_home/features/local_help/referral_catalog.dart';

void main(List<String> args) {
  try {
    if (args.isNotEmpty && !{'--export', '--validate'}.contains(args.first) ||
        args.firstOrNull == '--export' && args.length != 1 ||
        args.firstOrNull == '--validate' &&
            args.length != 2 &&
            args.length != 4 ||
        args.length == 4 && args[2] != '--previous') {
      throw const FormatException(
        'Usage: check_referral_catalog.dart [--export | --validate snapshot.json [--previous previous.json]]',
      );
    }
    final catalog = args.firstOrNull == '--validate'
        ? ReferralCatalog.fromJson(jsonDecode(File(args[1]).readAsStringSync()))
        : ReferralCatalog.bundled();
    if (args.length == 4) {
      catalog.requireCompatibleUpdate(
        ReferralCatalog.fromJson(jsonDecode(File(args[3]).readAsStringSync())),
      );
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(
        args.firstOrNull == '--export'
            ? catalog.toJson()
            : {
                ...catalog.coverageReport(DateTime.now()),
                'reviewQueue': catalog.reviewQueue(DateTime.now()),
              },
      ),
    );
  } catch (error) {
    stderr.writeln('Catalog validation failed: $error');
    exitCode = 1;
  }
}
