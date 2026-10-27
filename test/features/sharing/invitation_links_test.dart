import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/invitation_links.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import 'package:safe_at_home/l10n/catalogs/invitations.dart';
import '../../support/contract_schema.dart';

void main() {
  final origin = Uri.parse('https://fictional.example'), code = 'a' * 43;
  test(
    'codes and exact app/HTTPS links parse; auth callbacks, foreign origins and injected parameters fail closed',
    () {
      for (final value in [
        code,
        invitationLink(origin, code).toString(),
        'safeathome://invite#code=$code',
      ]) {
        expect(readInvitationCode(value, origin), code);
      }
      for (final value in [
        'https://evil.example/invite#code=$code',
        'https://fictional.example@evil.example/invite#code=$code',
        'https://fictional.example/invite?next=evil#code=$code',
        'safeathome://auth/callback?code=$code',
        'safeathome://invite#code=$code&next=evil',
        'safeathome://invite#access_token=$code',
        'safeathome://invite:123#code=$code',
        'https://fictional.example/not-invite#code=$code',
        'javascript:$code',
      ]) {
        expect(readInvitationCode(value, origin), isNull, reason: value);
      }
      expect(
        acceptsAuthCallback(
          Uri.parse('safeathome://invite#code=$code'),
          Uri.parse('safeathome://auth/callback'),
        ),
        false,
      );
    },
  );
  testWidgets(
    'pending link survives sign-in without acceptance/storage, expires in memory and cannot be reused after disposal',
    (tester) async {
      final box = InvitationLinkInbox();
      box.receive(Uri.parse('safeathome://invite#code=$code'), origin);
      expect(box.value, code);
      expect(box.take(), code);
      expect(box.take(), isNull);
      box.receive(Uri.parse('safeathome://invite#code=$code'), origin);
      await tester.pump(const Duration(minutes: 10));
      expect(box.value, isNull);
      box.dispose();
      box.receive(Uri.parse('safeathome://invite#code=$code'), origin);
      expect(box.value, isNull);
    },
  );
  test(
    'exact mailbox normalization preserves aliases; all new controls have five translations',
    () {
      expect(
        normalizeInvitationEmail(' Helper+tag@Fictional.Example '),
        'helper+tag@fictional.example',
      );
      for (final value in ['x@y', 'x..y@example.test', 'x@-example.test']) {
        expect(normalizeInvitationEmail(value), isNull);
      }
      for (final values in invitationTranslations.values) {
        expect(values.keys.toSet(), {'es', 'zh-Hans', 'zh-Hant', 'vi', 'fil'});
      }
    },
  );
  test(
    'additive email invitation fixture matches strict request/response schema and existing typed membership',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/permission-sharing.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final fixture =
          jsonDecode(
                File(
                  'contracts/v3/fixtures/email-invitation.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final side in ['request', 'response']) {
        expect(
          acceptsContract(
            fixture[side],
            schema[r'$defs']['create-email-invitation-$side'],
            {},
            schema,
          ),
          true,
        );
      }
      expect(
        SharingResponse.fromJson(
          fixture['response'],
          'create-email-invitation',
        ).invitationCode,
        isNotEmpty,
      );
      final ownerResponse = {
        'schemaVersion': '3',
        'availableProgramIds': <String>[],
        'shares': [
          {
            ...fixture['response']['membership'] as Map,
            'projection': null,
            'notes': [],
            'audit': [],
            'invitedEmail': 'helper@fictional.example',
          },
        ],
      };
      expect(
        acceptsContract(
          ownerResponse,
          schema[r'$defs']['list-email-sharing-response'],
          {},
          schema,
        ),
        true,
      );
      expect(
        SharingResponse.fromJson(
          ownerResponse,
          'list-email-sharing',
        ).shares.single.invitedEmail,
        'helper@fictional.example',
      );
      expect(
        acceptsContract(
          ownerResponse,
          schema[r'$defs']['list-sharing-response'],
          {},
          schema,
        ),
        false,
        reason: 'Older clients retain their exact response shape.',
      );
    },
  );
}
