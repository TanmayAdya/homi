import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore, services;
import '../../app/local_private_store_test.dart' show MemorySecrets;

const national211 = 'referral-211-national';
const rebuilding = 'referral-rebuilding-together-national';
const timestamp = '2026-10-24T12:00:00.000Z';
HelpFollowUp task(
  String id, {
  String? date = '2026-10-24',
  String title = 'Ask about a ramp',
}) => HelpFollowUp(
  id: id,
  providerId: national211,
  title: title,
  responsible: 'Fictional resident',
  dueDate: date,
  createdAt: timestamp,
  findingId: 'fictional-concern',
);

class FailingHelpStore extends MemoryPrivateStore {
  bool fail = false, loseAcknowledgement = false;
  Completer<void>? entered, release;
  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key.startsWith('local-help.') && entered != null) {
      entered!.complete();
      await release!.future;
    }
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('local-help.') && fail) {
      throw StateError('Fictional disk full');
    }
    await super.writeJson(key, value);
    if (key.startsWith('local-help.') && loseAcknowledgement) {
      loseAcknowledgement = false;
      throw StateError('Fictional lost save confirmation');
    }
  }
}

void main() {
  test(
    'fixed official destinations contain no query, fragment or resident data',
    () {
      const directory = OfficialReferralDirectory();
      expect(directory.provider('unknown'), isNull);
      for (final p in directory.providers) {
        final uri = referralDestination(p);
        expect(uri.scheme, 'https');
        expect(
          uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty,
          false,
        );
        expect(p.sources, isNotEmpty);
        expect(
          p.availability,
          p.id == 'provider-habitat-sonoma-county'
              ? ReferralAvailability.closed
              : ReferralAvailability.unknown,
        );
      }
      expect(
        referralDestination(
          directory.provider(national211)!,
          phone: true,
        ).toString(),
        'tel:211',
      );
    },
  );

  test(
    'county listings and freshness never become address eligibility or live intake',
    () {
      final p = const OfficialReferralDirectory().provider(
        'referral-211-bay-area',
      )!;
      expect(
        p.coverage(null, DateTime(2026, 10, 24)),
        ReferralCoverage.unknown,
      );
      expect(
        p.coverage('Other county', DateTime(2026, 10, 24)),
        ReferralCoverage.unknown,
      );
      expect(
        p.coverage('San Mateo', DateTime(2026, 10, 24), stateCode: 'CA'),
        ReferralCoverage.listedCounty,
      );
      expect(
        p.coverage('San Mateo', DateTime(2026, 11, 23)),
        ReferralCoverage.unknown,
      );
      expect(p.needsReview(DateTime(2026, 11, 22)), false);
      expect(p.needsReview(DateTime(2026, 11, 23)), true);
      expect(
        officialReferrals.first.coverage(null, DateTime(2027)),
        ReferralCoverage.locator,
      );
      const closed = ReferralProvider(
        id: 'closed',
        name: 'Fictional closed intake',
        description: '',
        website: 'https://example.org',
        sources: [],
        reviewedOn: '2026-10-24',
        reviewAfter: '2026-11-23',
        availability: ReferralAvailability.closed,
      );
      expect(closed.availability, ReferralAvailability.closed);
    },
  );

  test(
    'date-only due dates reject rollover and remain due through the local day',
    () {
      for (final value in [
        '2026-02-30',
        '2026-13-01',
        '2026-1-1',
        '0000-01-01',
        '2026-01-01T00:00:00Z',
      ]) {
        expect(() => helpDate(value), throwsFormatException);
      }
      expect(helpDate('2028-02-29'), '2028-02-29');
      expect(task('one').overdue(DateTime(2026, 10, 24, 23, 59)), false);
      expect(task('one').overdue(DateTime(2026, 10, 25)), true);
      expect(task('one', date: null).overdue(DateTime(2027)), false);
      expect(
        () => HelpLocation(city: '', county: '', zip: 'abc'),
        throwsFormatException,
      );
    },
  );

  test('strict bounded records reject duplicates and future schemas', () {
    final r = LocalHelpRecord(caseId: 'fictional-case', tasks: [task('one')]);
    expect(
      LocalHelpRecord.fromJson(r.toJson()).tasks.single.findingId,
      'fictional-concern',
    );
    expect(
      () => LocalHelpRecord.fromJson({...r.toJson(), 'schemaVersion': '2'}),
      throwsFormatException,
    );
    expect(
      () => LocalHelpRecord(
        caseId: 'fictional-case',
        tasks: [task('one'), task('one')],
      ),
      throwsFormatException,
    );
    expect(
      () => LocalHelpRecord(
        caseId: 'fictional-case',
        tasks: List.generate(101, (i) => task('$i')),
      ),
      throwsFormatException,
    );
    expect(() => r.tasks.add(task('two')), throwsUnsupportedError);
  });

  group('device repository', () {
    late FailingHelpStore store;
    late AppServices app;
    late FakeTransport transport;
    late LocalHelpRepository repository;
    setUp(() async {
      store = FailingHelpStore();
      transport = FakeTransport(
        (_) async => throw StateError('No network allowed'),
      );
      app = services(store, transport);
      await app.coordinator.createDraft();
      repository = LocalHelpRepository(app.coordinator);
    });
    tearDown(() {
      app.dispose();
      app.session.dispose();
    });

    test(
      'restart, duplicate save and independent tasks preserve notes and due dates',
      () async {
        await repository.confirmLocation(
          HelpLocation(city: 'Fictional city', county: 'San Mateo', zip: null),
        );
        await Future.wait([
          repository.saveContact(national211, 'Ask for Spanish'),
          repository.saveContact(rebuilding, 'Ask about volunteers'),
        ]);
        await repository.saveContact(national211, 'Resident note {count}');
        await repository.saveTask(task('one'));
        await repository.saveTask(task('one'));
        await repository.saveTask(task('two', date: null));
        await repository.completeTask('one', true);
        final resumed = LocalHelpRepository(app.coordinator);
        var r = await resumed.load();
        expect(r.contacts.length, 2);
        expect(
          r.contacts.firstWhere((c) => c.providerId == national211).note,
          'Resident note {count}',
        );
        expect(r.tasks.length, 2);
        expect(r.tasks.first.completedAt, isNotNull);
        expect(r.tasks.last.completedAt, isNull);
        expect(r.tasks.last.dueDate, isNull);
        await resumed.completeTask('one', false);
        await resumed.saveTask(
          task('one', date: '2026-11-02', title: 'Call again'),
        );
        await resumed.removeContact(national211);
        r = await resumed.load();
        expect(r.tasks.firstWhere((t) => t.id == 'one').title, 'Call again');
        expect(r.tasks.firstWhere((t) => t.id == 'one').dueDate, '2026-11-02');
        expect(r.tasks.firstWhere((t) => t.id == 'one').completedAt, isNull);
        await resumed.removeTask('two');
        expect((await resumed.load()).tasks.length, 1);
        expect(transport.requests, isEmpty);
      },
    );

    test(
      'failed save keeps previous data and retry does not duplicate contact',
      () async {
        await repository.saveContact(national211, 'original');
        store.fail = true;
        await expectLater(
          repository.saveContact(national211, 'changed'),
          throwsStateError,
        );
        expect((await repository.load()).contacts.single.note, 'original');
        store.fail = false;
        expect(
          (await repository.saveContact(
            national211,
            'changed',
          )).contacts.single.note,
          'changed',
        );
      },
    );

    test(
      'corrupt or mismatched saved record is not silently overwritten',
      () async {
        store.records[repository.key] = LocalHelpRecord(
          caseId: 'different-case',
        ).toJson();
        await expectLater(
          repository.saveContact(national211, ''),
          throwsFormatException,
        );
        expect(store.records[repository.key]!['caseId'], 'different-case');
      },
    );

    test(
      'selection switch rejects stale repository and keeps plans separate',
      () async {
        await repository.saveTask(task('one'));
        final originalId = repository.caseId;
        await app.coordinator.createDraft();
        await expectLater(repository.saveTask(task('two')), throwsStateError);
        expect(
          (await LocalHelpRepository(app.coordinator).load()).tasks,
          isEmpty,
        );
        await app.coordinator.restoreLocal(originalId);
        expect(
          (await LocalHelpRepository(app.coordinator).load()).tasks.single.id,
          'one',
        );
      },
    );

    test(
      'account change during delayed read prevents save and exposure',
      () async {
        store.entered = Completer<void>();
        store.release = Completer<void>();
        final pending = repository.saveContact(national211, 'private');
        final rejected = expectLater(pending, throwsStateError);
        await store.entered!.future;
        await app.session.signOut();
        store.release!.complete();
        await rejected;
        expect(store.records.containsKey(repository.key), false);
      },
    );

    test(
      'retry after a lost save confirmation uses the same task identity',
      () async {
        store.loseAcknowledgement = true;
        final next = task('stable-retry-id');
        await expectLater(repository.saveTask(next), throwsStateError);
        expect((await repository.saveTask(next)).tasks.single.id, next.id);
      },
    );

    test('plan cleanup removes only its local help record', () async {
      await repository.saveTask(task('one'));
      store.records['local-help.other-case'] = {'retained': true};
      await app.coordinator.clearSelected();
      expect(store.records.containsKey(repository.key), false);
      expect(store.records['local-help.other-case'], {'retained': true});
    });
  });

  test(
    'real private store encrypts referral notes, restores, and clears with account data',
    () async {
      final dir = await Directory.systemTemp.createTemp('sah-help-fictional-');
      final secrets = MemorySecrets();
      final session = FakeSession();
      final store = LocalPrivateStore(
        directory: dir,
        accountId: session.userId!,
        secrets: secrets,
      );
      final app = AppServices(
        config: LiveAppConfig(
          apiOrigin: Uri.parse('https://example.org'),
          supabaseUrl: Uri.parse('https://example.supabase.co'),
          publishableKey: 'fictional',
        ),
        session: session,
        store: store,
        transport: FakeTransport((_) async => throw StateError('No network')),
      );
      addTearDown(() async {
        app.dispose();
        session.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await app.coordinator.createDraft();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.saveContact(national211, 'Fictional private contact note');
      await for (final file in dir.list()) {
        expect(
          await (file as File).readAsString(),
          isNot(contains('Fictional private contact note')),
        );
      }
      final reopened = LocalPrivateStore(
        directory: dir,
        accountId: session.userId!,
        secrets: secrets,
      );
      expect(
        LocalHelpRecord.fromJson(
          await reopened.readJson(repo.key),
        ).contacts.single.note,
        'Fictional private contact note',
      );
      await store.clear();
      expect(await dir.exists(), false);
      expect(secrets.values, isEmpty);
    },
  );
}
