import '../../shared/models/export_contract_values.dart';
import 'local_help_record.dart' show helpDate, helpText;
import 'referral_directory.dart';

/// Validate versioned offline provider records
class ReferralCatalog implements ReferralDirectory {
  ReferralCatalog({
    required this.version,
    required List<ReferralProvider> providers,
  }) : providers = List.unmodifiable(providers) {
    helpText(version, max: 100);
    if (providers.isEmpty || providers.length > 1000) {
      throw const FormatException('Invalid catalog size.');
    }
    ExportContractValues.unique(providers.map((p) => p.id));
    final organizations = providers.where((p) => p.isLocalProvider);
    ExportContractValues.unique(
      organizations.map((p) => p.canonicalOrganizationId),
    );
    ExportContractValues.unique(organizations.map((p) => p.website));
    final linked = providers.map((p) => p.programId).nonNulls;
    ExportContractValues.unique(linked);
    linked.forEach(ExportContractValues.id);
    for (final p in providers) {
      ExportContractValues.id(p.id);
      ExportContractValues.id(p.canonicalOrganizationId);
      helpText(p.name, max: 200);
      helpText(p.description, max: 1000);
      if (p.areaNote != null) helpText(p.areaNote, max: 2000);
      helpDate(p.reviewedOn);
      helpDate(p.reviewAfter);
      if (p.reviewAfter.compareTo(p.reviewedOn) <= 0 ||
          p.sources.isEmpty ||
          p.roles.isEmpty) {
        throw const FormatException('Missing catalog provenance.');
      }
      referralDestination(p);
      if (p.phone != null) referralDestination(p, phone: true);
      for (final source in p.sources) {
        final uri = Uri.tryParse(source);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Invalid catalog source.');
        }
      }
      if (!p.isLocator && p.stateCodes.isEmpty) {
        throw const FormatException('Missing explicit catalog state.');
      }
      ExportContractValues.unique(p.stateCodes);
      for (final state in p.stateCodes) {
        if (referralState(state) == null || state != state.toUpperCase()) {
          throw const FormatException('Unknown catalog state.');
        }
      }
      for (final area in p.listedAreas) {
        if (!p.stateCodes.contains(area.stateCode) ||
            area.countyFips != null &&
                (!RegExp(r'^[0-9]{5}$').hasMatch(area.countyFips!) ||
                    !area.countyFips!.startsWith(
                      referralState(area.stateCode)!.fips,
                    ))) {
          throw const FormatException('Contradictory catalog geography.');
        }
        final known = referralCountyFips[area.stateCode]?[area.countyName];
        if (known != null && area.countyFips != known) {
          throw const FormatException('Contradictory county name/FIPS.');
        }
      }
    }
  }
  factory ReferralCatalog.bundled() => ReferralCatalog(
    version: localProviderCatalogVersion,
    providers: const OfficialReferralDirectory().providers,
  );
  final String version;
  @override
  final List<ReferralProvider> providers;
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
  int get organizationCount => providers
      .where((p) => p.isLocalProvider)
      .map((p) => p.canonicalOrganizationId)
      .toSet()
      .length;

  List<Map<String, Object?>> reviewQueue(DateTime now) =>
      [
        for (final p in providers)
          {
            'id': p.id,
            'ownerRole': p.providerKind == ReferralProviderKind.programReferral
                ? 'Program policy maintainer'
                : 'Directory maintainer',
            'reviewedOn': p.reviewedOn,
            'nextReviewOn': p.reviewAfter,
            'needsReview': p.needsReview(now),
            'intake': p.availability.name,
            'sources': p.sources,
          },
      ]..sort(
        (a, b) => (a['nextReviewOn'] as String).compareTo(
          b['nextReviewOn'] as String,
        ),
      );

  Map<String, Object?> coverageReport(DateTime now) => {
    'catalogVersion': version,
    'metric':
        'Homi published deduplicated organization records, not network reach',
    'organizationCount': organizationCount,
    'nationalLocatorCount': providers.where((p) => p.isLocator).length,
    'geographySource': referralGeographySource,
    'reviewedOn': '2026-10-26',
    'states': [
      for (final state in usStates)
        {
          'stateCode': state.code,
          'name': state.name,
          'referralRouting': true,
          'organizationCount': providers
              .where(
                (p) => p.isLocalProvider && p.stateCodes.contains(state.code),
              )
              .map((p) => p.canonicalOrganizationId)
              .toSet()
              .length,
          'countyFipsCandidates':
              providers
                  .where((p) => p.isLocalProvider)
                  .expand((p) => p.listedAreas)
                  .where((a) => a.stateCode == state.code)
                  .map((a) => a.countyFips)
                  .whereType<String>()
                  .toSet()
                  .toList()
                ..sort(),
          'verifiedNationwideEligibility': false,
          'officialForms': state.code == 'CA'
              ? 'Existing program-specific regional mappings only'
              : 'None reviewed in this release',
          'staleIds': providers
              .where(
                (p) => p.stateCodes.contains(state.code) && p.needsReview(now),
              )
              .map((p) => p.id)
              .toList(),
        },
    ],
    'territories': [
      for (final t in usTerritories)
        {
          'stateCode': t.code,
          'status':
              'Separate routing review pending; national networks may provide services',
        },
    ],
    'tribalRoutes':
        'Separate review pending; county routing does not establish Tribal coverage',
  };

  void requireCompatibleUpdate(ReferralCatalog previous) {
    for (final p in previous.providers) {
      if (provider(p.id) == null) {
        throw FormatException(
          'Retain retired record ${p.id} for saved contacts.',
        );
      }
    }
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'catalogVersion': version,
    'providers': [
      for (final p in providers)
        {
          'id': p.id,
          'name': p.name,
          'description': p.description,
          'website': p.website,
          'phone': p.phone,
          'sources': p.sources,
          'reviewedOn': p.reviewedOn,
          'reviewAfter': p.reviewAfter,
          'counties': p.counties,
          'cities': p.cities,
          'areaNote': p.areaNote,
          'stateCodes': p.stateCodes,
          'organizationId': p.organizationId,
          'parentNetworkId': p.parentNetworkId,
          'kind': p.providerKind.name,
          'isLocator': p.isLocator,
          'availability': p.availability.name,
          'services': p.services.map((s) => s.name).toList(),
          'roles': p.roles.map((r) => r.name).toList(),
          'serviceAreas': [
            for (final a in p.listedAreas)
              {
                'stateCode': a.stateCode,
                'countyFips': a.countyFips,
                'countyName': a.countyName,
                'cities': a.cities,
                'zipCodes': a.zipCodes,
                'restriction': a.restriction,
              },
          ],
        },
    ],
  };
  factory ReferralCatalog.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'catalogVersion',
      'providers',
    });
    if (v['schemaVersion'] != '1') {
      throw const FormatException('Unsupported catalog.');
    }
    List<String> strings(Object? value) =>
        ExportContractValues.list(value, (s) => helpText(s, max: 2000), 100);
    T enumeration<T extends Enum>(Object? value, List<T> values) =>
        values.where((e) => e.name == value).firstOrNull ??
        (throw const FormatException('Unknown catalog value.'));
    return ReferralCatalog(
      version: helpText(v['catalogVersion'], max: 100),
      providers: ExportContractValues.list(v['providers'], (raw) {
        final p = ExportContractValues.object(raw, {
          'id',
          'name',
          'description',
          'website',
          'phone',
          'sources',
          'reviewedOn',
          'reviewAfter',
          'counties',
          'cities',
          'areaNote',
          'stateCodes',
          'organizationId',
          'parentNetworkId',
          'kind',
          'isLocator',
          'availability',
          'services',
          'roles',
          'serviceAreas',
        });
        final locator = p['isLocator'];
        if (locator is! bool) throw const FormatException('Invalid locator.');
        final kind = enumeration(p['kind'], ReferralProviderKind.values);
        if (locator != (kind == ReferralProviderKind.nationalLocator)) {
          throw const FormatException('Conflicting locator kind.');
        }
        return ReferralProvider(
          id: helpText(p['id'], max: 200),
          name: helpText(p['name'], max: 200),
          description: helpText(p['description'], max: 1000),
          website: helpText(p['website'], max: 2000),
          phone: p['phone'] as String?,
          sources: strings(p['sources']),
          reviewedOn: helpDate(p['reviewedOn']),
          reviewAfter: helpDate(p['reviewAfter']),
          counties: strings(p['counties']),
          cities: strings(p['cities']),
          areaNote: p['areaNote'] as String?,
          stateCodes: strings(p['stateCodes']),
          organizationId: p['organizationId'] as String?,
          parentNetworkId: p['parentNetworkId'] as String?,
          kind: kind,
          isLocator: locator,
          availability: enumeration(
            p['availability'],
            ReferralAvailability.values,
          ),
          services: ExportContractValues.list(
            p['services'],
            (s) => enumeration(s, ReferralService.values),
            10,
          ),
          roles: ExportContractValues.list(
            p['roles'],
            (r) => enumeration(r, ReferralRole.values),
            10,
          ),
          serviceAreas: ExportContractValues.list(p['serviceAreas'], (raw) {
            final a = ExportContractValues.object(raw, {
              'stateCode',
              'countyFips',
              'countyName',
              'cities',
              'zipCodes',
              'restriction',
            });
            return ReferralServiceArea(
              stateCode: helpText(a['stateCode'], max: 2),
              countyFips: a['countyFips'] as String?,
              countyName: a['countyName'] as String?,
              cities: strings(a['cities']),
              zipCodes: strings(a['zipCodes']),
              restriction: a['restriction'] as String?,
            );
          }, 100),
        );
      }, 1000),
    );
  }
}
