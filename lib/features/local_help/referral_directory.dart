import 'referral_geography.dart';

export 'referral_geography.dart';

enum ReferralProviderKind {
  organization,
  nationalLocator,
  referralContact,
  programReferral,
}

enum ReferralRole {
  repairProvider('Performs repairs'),
  modificationFunder('Funds modifications'),
  coordinator('Coordinates assistance'),
  referralService('Provides referrals');

  const ReferralRole(this.label);
  final String label;
}

enum ReferralAvailability { unknown, closed }

enum ReferralCoverage { locator, listedCounty, unknown }

enum ReferralService {
  homeRepair('Home repairs'),
  accessibility('Accessibility modifications'),
  coordination('Service coordination');

  const ReferralService(this.label);
  final String label;
}

class ReferralProvider {
  const ReferralProvider({
    required this.id,
    required this.name,
    required this.description,
    required this.website,
    required this.sources,
    required this.reviewedOn,
    required this.reviewAfter,
    this.phone,
    this.counties = const [],
    this.isLocator = false,
    this.availability = ReferralAvailability.unknown,
    this.services = const [],
    this.cities = const [],
    this.areaNote,
    this.stateCodes = const [],
    this.serviceAreas = const [],
    this.parentNetworkId,
    this.organizationId,
    this.kind,
    this.programId,
    List<ReferralRole>? roles,
  }) : _roles = roles;
  final String id, name, description, website, reviewedOn, reviewAfter;
  final List<String> sources, counties;
  final String? phone;
  final bool isLocator;
  final ReferralAvailability availability;
  final List<ReferralService> services;
  final List<String> cities;
  final String? areaNote;
  final List<String> stateCodes;
  final List<ReferralServiceArea> serviceAreas;
  final String? parentNetworkId, organizationId;
  final ReferralProviderKind? kind;

  final String? programId;
  final List<ReferralRole>? _roles;
  List<ReferralRole> get roles =>
      _roles ??
      switch (providerKind) {
        ReferralProviderKind.organization => const [
          ReferralRole.repairProvider,
        ],
        ReferralProviderKind.programReferral => const [
          ReferralRole.modificationFunder,
        ],
        _ => const [ReferralRole.referralService],
      };
  ReferralProviderKind get providerKind =>
      kind ??
      (isLocator
          ? ReferralProviderKind.nationalLocator
          : services.isNotEmpty
          ? ReferralProviderKind.organization
          : ReferralProviderKind.referralContact);
  String get canonicalOrganizationId => organizationId ?? id;
  bool get isLocalProvider => providerKind == ReferralProviderKind.organization;

  Iterable<ReferralServiceArea> get listedAreas => serviceAreas.isNotEmpty
      ? serviceAreas
      : [
          if (stateCodes.length == 1)
            for (final county in counties)
              ReferralServiceArea(
                stateCode: stateCodes.single,
                countyName: county,
                countyFips: referralCountyFips[stateCodes.single]?[county],
                cities: cities,
                restriction: areaNote,
              ),
        ];

  bool needsReview(DateTime now) => !DateTime(
    now.year,
    now.month,
    now.day,
  ).isBefore(DateTime.parse(reviewAfter));
  bool listsCounty(String? county, {String? stateCode, String? countyFips}) {
    if (stateCode == null || !stateCodes.contains(stateCode.toUpperCase())) {
      return false;
    }
    return listedAreas.any(
      (area) =>
          area.stateCode == stateCode.toUpperCase() &&
          (countyFips != null
              ? area.countyFips == countyFips
              : county != null &&
                    area.countyName != null &&
                    normalizeReferralCounty(area.countyName!) ==
                        normalizeReferralCounty(county)),
    );
  }

  ReferralCoverage coverage(
    String? county,
    DateTime now, {
    String? stateCode,
    String? countyFips,
    String? city,
    String? zip,
  }) {
    if (isLocator) return ReferralCoverage.locator;
    if (availability == ReferralAvailability.closed ||
        needsReview(now) ||
        !listsCounty(county, stateCode: stateCode, countyFips: countyFips)) {
      return ReferralCoverage.unknown;
    }
    final wholeCounty = listedAreas.any(
      (a) =>
          a.stateCode == stateCode?.toUpperCase() &&
          (countyFips != null
              ? a.countyFips == countyFips
              : a.countyName != null &&
                    normalizeReferralCounty(a.countyName!) ==
                        normalizeReferralCounty(county ?? '')) &&
          a.cities.isEmpty &&
          a.zipCodes.isEmpty &&
          a.restriction == null,
    );
    return wholeCounty
        ? ReferralCoverage.listedCounty
        : ReferralCoverage.unknown;
  }
}

String normalizeReferralCounty(String county) =>
    county.trim().toLowerCase().replaceFirst(RegExp(r'\s+county$'), '');

abstract interface class ReferralDirectory {
  List<ReferralProvider> get providers;
  ReferralProvider? provider(String id);
}

class OfficialReferralDirectory implements ReferralDirectory {
  const OfficialReferralDirectory();
  @override
  List<ReferralProvider> get providers => const [
    ...officialReferrals,
    ...localProviderCatalog,
    ...federalProgramReferrals,
  ];
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

const referralCounties = [
  'Marin',
  'Napa',
  'San Francisco',
  'San Mateo',
  'Santa Clara',
  'Solano',
];
const officialReferrals = [
  ReferralProvider(
    id: 'referral-211-national',
    name: '211',
    description: 'Ask about local home repair and community services.',
    website: 'https://211.org/about-us/your-local-211',
    phone: '211',
    isLocator: true,
    sources: ['https://211.org/about-us/your-local-211'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'referral-rebuilding-together-national',
    name: 'Rebuilding Together',
    description: 'Find a Rebuilding Together affiliate',
    website: 'https://rebuildingtogether.org/find-your-local-affiliate',
    isLocator: true,
    sources: ['https://rebuildingtogether.org/find-your-local-affiliate'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'referral-211-bay-area',
    stateCodes: ['CA'],
    name: '211 Bay Area',
    description: 'Ask about local home repair and community services.',
    website: 'https://211bayarea.org/contact/',
    phone: '8002736222',
    counties: referralCounties,
    sources: [
      'https://211bayarea.org/about-211-bay-area/',
      'https://211bayarea.org/contact/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'referral-eldercare-national',
    name: 'Eldercare Locator',
    description:
        'Official aging-service referral, including Area Agencies on Aging. Ask about local support and home accessibility resources.',
    website: 'https://eldercare.acl.gov/home',
    phone: '18006771116',
    isLocator: true,
    sources: ['https://acl.gov/help', 'https://eldercare.acl.gov/home'],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
  ReferralProvider(
    id: 'referral-habitat-national',
    name: 'Habitat for Humanity affiliate locator',
    description:
        'Find a local Habitat affiliate. Ask whether it offers repairs, accessibility work or financing in your area; services differ.',
    website:
        'https://www.habitat.org/volunteer/near-you/find-your-local-habitat',
    isLocator: true,
    sources: [
      'https://www.habitat.org/volunteer/near-you/find-your-local-habitat',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
    parentNetworkId: 'habitat-for-humanity',
  ),
  ReferralProvider(
    id: 'referral-cil-national',
    name: 'Centers for Independent Living directory',
    description:
        'Official ACL state and territory list of Centers for Independent Living. Ask about accessibility advice, local services and referrals; centers are not necessarily repair providers.',
    website:
        'https://acl.gov/programs/centers-independent-living/list-cils-and-spils',
    isLocator: true,
    sources: [
      'https://acl.gov/programs/centers-independent-living/list-cils-and-spils',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
];

const localProviderCatalogVersion = 'us-pilot-2026-10-26-v2';
const localProviderCatalog = [
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-rebuilding-together-silicon-valley',
    name: 'Rebuilding Together Silicon Valley',
    description:
        'Home repairs and safety modifications in selected Santa Clara County communities.',
    website: 'https://rebuildingtogethersv.org/apply/',
    phone: '4085789519',
    counties: ['Santa Clara'],
    cities: [
      'Alviso',
      'Campbell',
      'Cupertino',
      'Gilroy',
      'Los Gatos',
      'Milpitas',
      'Morgan Hill',
      'San Jose',
      'San Martin',
      'Santa Clara',
      'Saratoga',
      'Sunnyvale',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Only selected cities are listed. Funding and project selection are limited.',
    sources: [
      'https://rebuildingtogethersv.org/apply/',
      'https://rebuildingtogethersv.org/programs/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-rebuilding-together-san-francisco',
    name: 'Rebuilding Together San Francisco',
    description:
        'Home repair and renovation programs for San Francisco homeowners and renters.',
    website: 'https://rebuildingtogethersf.org/apply/',
    phone: '4159051611',
    counties: ['San Francisco'],
    services: [ReferralService.homeRepair],
    sources: [
      'https://rebuildingtogethersf.org/',
      'https://rebuildingtogethersf.org/apply/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-habitat-greater-san-francisco',
    name: 'Habitat for Humanity Greater San Francisco',
    description:
        'Home repairs and accessibility improvements with financing options.',
    website: 'https://habitatgsf.org/home-repair-work/',
    phone: '4156251000',
    counties: ['Marin', 'San Francisco', 'San Mateo'],
    cities: ['Menlo Park', 'Redwood City', 'Foster City'],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Programs vary by city and property type. Marin is fully subscribed at review; ask about future opportunities. Repairs may involve a loan.',
    sources: ['https://habitatgsf.org/home-repair-work/'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-cid-san-mateo',
    roles: [ReferralRole.coordinator, ReferralRole.referralService],
    name: 'Center for Independence of Individuals with Disabilities (CID)',
    description:
        'Assistive technology advice and home modification resource coordination.',
    website: 'https://www.cidsanmateo.org/services/assistive-technology.php',
    phone: '6506451780',
    counties: ['San Mateo'],
    services: [ReferralService.coordination],
    areaNote:
        'Resource coordination does not mean this organization performs repairs.',
    sources: [
      'https://www.cidsanmateo.org/services/',
      'https://www.cidsanmateo.org/services/assistive-technology.php',
      'https://www.cidsanmateo.org/about/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-habitat-east-bay-silicon-valley',
    name: 'Habitat for Humanity East Bay/Silicon Valley',
    description:
        'Home repairs and accessibility improvements in selected East Bay and Santa Clara County communities.',
    website: 'https://www.habitatebsv.org/services/home-repair',
    phone: '5108033388',
    counties: ['Alameda', 'Contra Costa', 'Santa Clara'],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Only selected cities are served. Ask about your address, funding and any loan terms.',
    sources: [
      'https://www.habitatebsv.org/services/home-repair',
      'https://www.habitatebsv.org/blog/home-repair-program',
      'https://www.achhd.org/programs/housing-rehab/index.htm',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-rebuilding-together-petaluma',
    name: 'Rebuilding Together Petaluma',
    description:
        'Home repairs and safety modifications in selected Sonoma County communities.',
    website: 'https://rtpetaluma.org/apply/',
    phone: '7077653944',
    counties: ['Sonoma'],
    cities: [
      'Petaluma',
      'Bodega Bay',
      'Boyes Hot Springs',
      'Cazadero',
      'Cloverdale',
      'El Verano',
      'Forestville',
      'Freestone',
      'Glen Ellen',
      'Guerneville',
      'Healdsburg',
      'Monte Rio',
      'Occidental',
      'Rio Nido',
      'Sebastopol',
      'Sonoma',
      'Valley Ford',
      'Windsor',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Selected Sonoma County communities only; confirm address coverage, funding and project selection.',
    sources: [
      'https://rtpetaluma.org/apply/',
      'https://rtpetaluma.org/programs/',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-rebuilding-together-solano-county',
    name: 'Rebuilding Together Solano County',
    description:
        'Home rehabilitation and safety repairs for selected Solano County homeowners.',
    website: 'https://rebuildingtogethersolanocounty.org/services/',
    phone: '7075809360',
    counties: ['Solano'],
    services: [ReferralService.homeRepair],
    areaNote:
        'The published veteran application deadline was April 30, 2026. Ask about current programs and address coverage.',
    sources: [
      'https://rebuildingtogethersolanocounty.org/services/',
      'https://rebuildingtogethersolanocounty.org/contacts/',
      'https://rebuildingtogethersolanocounty.org/faqs/',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-marin-center-independent-living',
    name: 'Marin Center for Independent Living',
    description:
        'Home accessibility modifications and assistive technology support in Marin County.',
    website: 'https://www.marincil.org/services/',
    phone: '4154596245',
    counties: ['Marin'],
    services: [ReferralService.accessibility, ReferralService.coordination],
    areaNote:
        'Ask for the home modifications team to discuss ramps, grab bars and available support.',
    sources: ['https://www.marincil.org/services/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-napa-housing-rehabilitation',
    roles: [ReferralRole.modificationFunder, ReferralRole.coordinator],
    name: 'City of Napa Housing Rehabilitation',
    description:
        'Home repair and accessibility program assistance in Napa County cities.',
    website: 'https://www.cityofnapa.org/204/Housing-Rehabilitation',
    phone: '7072579642',
    counties: ['Napa'],
    cities: [
      'Napa',
      'American Canyon',
      'Calistoga',
      'St. Helena',
      'Yountville',
    ],
    services: [
      ReferralService.homeRepair,
      ReferralService.accessibility,
      ReferralService.coordination,
    ],
    areaNote:
        'City programs differ. Ask the Housing Division about loans, grants and construction management; this is not a contractor booking.',
    sources: ['https://www.cityofnapa.org/204/Housing-Rehabilitation'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-cil-residential-access',
    roles: [ReferralRole.coordinator, ReferralRole.referralService],
    name: 'Center for Independent Living — Residential Access',
    description:
        'Home accessibility modifications in Berkeley and consultations in nearby Alameda County cities.',
    website: 'https://thecil.org/residential-access/',
    phone: '5108414776',
    counties: ['Alameda'],
    cities: [
      'Berkeley',
      'Oakland',
      'Alameda',
      'Emeryville',
      'Piedmont',
      'Albany',
    ],
    services: [ReferralService.accessibility, ReferralService.coordination],
    areaNote:
        'Funded modifications are limited to Berkeley. The other listed cities receive consultations with more limited support.',
    sources: ['https://thecil.org/residential-access/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-alameda-county-healthy-homes',
    roles: [ReferralRole.modificationFunder, ReferralRole.coordinator],
    name: 'Alameda County Healthy Homes — Minor Home Repair',
    description:
        'Minor home repairs and safety modifications in selected Alameda County communities.',
    website: 'https://www.achhd.org/programs/housing-rehab/index.htm',
    phone: '5105678280',
    counties: ['Alameda'],
    cities: [
      'Albany',
      'Dublin',
      'Emeryville',
      'Oakland',
      'Newark',
      'Union City',
      'Ashland',
      'Cherryland',
      'Castro Valley',
      'Hayward Acres',
      'Hillcrest Knolls',
      'Fairview',
      'San Lorenzo',
      'Sunol',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Selected communities only. Oakland has a waiting list; Union City is awaiting funding. Confirm current restrictions directly.',
    sources: ['https://www.achhd.org/programs/housing-rehab/index.htm'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    stateCodes: ['CA'],
    id: 'provider-habitat-sonoma-county',
    name: 'Habitat for Humanity of Sonoma County',
    description:
        'Sonoma County home repair program contact; repair requests are not being accepted at review.',
    website: 'https://habitatsoco.org/contact/',
    phone: '7075787707',
    counties: ['Sonoma'],
    services: [ReferralService.homeRepair],
    availability: ReferralAvailability.closed,
    areaNote:
        'Home repair intake is closed at review. Ask about future openings or use another listed organization.',
    sources: ['https://habitatsoco.org/contact/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'rt-seattle-wa',
    organizationId: 'rt-seattle-wa',
    parentNetworkId: 'rebuilding-together',
    stateCodes: ['WA'],
    name: 'Rebuilding Together Seattle',
    description:
        'Free home repairs and accessibility modifications in a limited Seattle-area service corridor.',
    website: 'https://www.rtseattle.org/homeowner',
    phone: '12066821231',
    counties: ['King', 'Snohomish'],
    cities: ['Everett', 'Seattle', 'SeaTac', 'Renton'],
    serviceAreas: [
      ReferralServiceArea(
        stateCode: 'WA',
        countyFips: '53033',
        countyName: 'King',
        restriction: 'Everett–SeaTac I-5 corridor and parts of Renton only.',
      ),
      ReferralServiceArea(
        stateCode: 'WA',
        countyFips: '53061',
        countyName: 'Snohomish',
        restriction: 'Everett–SeaTac I-5 corridor only.',
      ),
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Limited corridor, not all King or Snohomish County. Owner-occupied primary homes; income and project review required. Waits may be a year. Ask about capacity; no emergency service.',
    sources: ['https://www.rtseattle.org/homeowner'],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
  ReferralProvider(
    id: 'renovation-alliance-va',
    organizationId: 'renovation-alliance-va',
    stateCodes: ['VA'],
    name: 'Renovation Alliance',
    description:
        'Free critical home repairs and accessibility modifications in the Roanoke region, including rural communities.',
    website: 'https://www.renovateall.org/apply',
    phone: '15404000959',
    counties: [
      'Botetourt',
      'Craig',
      'Floyd',
      'Franklin',
      'Roanoke',
      'Roanoke city',
      'Salem city',
    ],
    serviceAreas: [
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51023',
        countyName: 'Botetourt',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51045',
        countyName: 'Craig',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51063',
        countyName: 'Floyd',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51067',
        countyName: 'Franklin',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51161',
        countyName: 'Roanoke',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51770',
        countyName: 'Roanoke city',
      ),
      ReferralServiceArea(
        stateCode: 'VA',
        countyFips: '51775',
        countyName: 'Salem city',
      ),
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Named counties plus the independent cities of Roanoke and Salem. Owner occupancy and income documentation required. Ask about current capacity; no numerical income limit is inferred.',
    sources: ['https://www.renovateall.org/apply'],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
  ReferralProvider(
    id: 'austin-habitat-tx',
    organizationId: 'austin-habitat-tx',
    parentNetworkId: 'habitat-for-humanity',
    stateCodes: ['TX'],
    name: 'Austin Habitat for Humanity',
    description:
        'Home repairs and accessibility modifications in selected central Texas counties and cities.',
    website: 'https://austinhabitat.org/programs/home-repair/',
    phone: '15124728788',
    counties: ['Bastrop', 'Blanco', 'Caldwell', 'Hays', 'Travis'],
    cities: ['Austin', 'Kyle'],
    serviceAreas: [
      ReferralServiceArea(
        stateCode: 'TX',
        countyFips: '48021',
        countyName: 'Bastrop',
      ),
      ReferralServiceArea(
        stateCode: 'TX',
        countyFips: '48031',
        countyName: 'Blanco',
      ),
      ReferralServiceArea(
        stateCode: 'TX',
        countyFips: '48055',
        countyName: 'Caldwell',
      ),
      ReferralServiceArea(
        stateCode: 'TX',
        countyFips: '48209',
        countyName: 'Hays',
      ),
      ReferralServiceArea(
        stateCode: 'TX',
        countyFips: '48453',
        countyName: 'Travis',
      ),
      ReferralServiceArea(
        stateCode: 'TX',
        cities: ['Austin', 'Kyle'],
        restriction:
            'Austin corporate city limits and Kyle; confirm exact address.',
      ),
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Interest form joins a waitlist, not an application. Owner-occupied single-family homes; manufactured homes need permanent foundation and resident-owned land. Confirm costs and financing; free repairs are not established.',
    sources: ['https://austinhabitat.org/programs/home-repair/'],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
  ReferralProvider(
    id: 'pca-philadelphia-pa',
    organizationId: 'pca-philadelphia-pa',
    stateCodes: ['PA'],
    parentNetworkId: 'area-agencies-on-aging',
    name: 'Philadelphia Corporation for Aging',
    description:
        'Home repair and accessibility assistance through Philadelphia County’s Area Agency on Aging.',
    website:
        'https://pcacares.org/services/help-in-the-home/home-repairs-modifications/',
    phone: '2157659040',
    counties: ['Philadelphia'],
    serviceAreas: [
      ReferralServiceArea(
        stateCode: 'PA',
        countyName: 'Philadelphia',
        countyFips: '42101',
      ),
    ],
    services: [
      ReferralService.homeRepair,
      ReferralService.accessibility,
      ReferralService.coordination,
    ],
    roles: [ReferralRole.repairProvider, ReferralRole.coordinator],
    areaNote:
        'SHARP serves eligible homeowners age 60 and older; income and home-condition rules apply. Some services may require cost-sharing. Confirm current capacity and costs.',
    sources: [
      'https://pcacares.org/services/help-in-the-home/home-repairs-modifications/',
      'https://pcacares.org/about/leadership-governance/',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
  ReferralProvider(
    id: 'ability360-az',
    organizationId: 'ability360-az',
    stateCodes: ['AZ'],
    parentNetworkId: 'centers-for-independent-living',
    name: 'Ability360',
    description:
        'Home accessibility modification coordination for eligible Maricopa County residents.',
    website: 'https://ability360.org/life-skills/home-modifications/',
    phone: '6022960536',
    counties: ['Maricopa'],
    serviceAreas: [
      ReferralServiceArea(
        stateCode: 'AZ',
        countyName: 'Maricopa',
        countyFips: '04013',
      ),
    ],
    services: [ReferralService.accessibility, ReferralService.coordination],
    roles: [ReferralRole.coordinator, ReferralRole.modificationFunder],
    areaNote:
        'For qualifying residents with disabilities and/or seniors in Maricopa County. Funding and qualification rules apply; confirm current service area, project availability and any resident contribution. Older cost-sharing information differs from the current page.',
    sources: [
      'https://ability360.org/life-skills/home-modifications/',
      'https://sci.ability360.org/about/',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2027-01-24',
  ),
];

Uri referralDestination(ReferralProvider provider, {bool phone = false}) {
  if (phone) {
    final number = provider.phone;
    if (number == null || !RegExp(r'^\+?[0-9]{3,15}$').hasMatch(number)) {
      throw const FormatException('Invalid referral phone.');
    }
    return Uri(scheme: 'tel', path: number);
  }
  final uri = Uri.parse(provider.website);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Invalid referral destination.');
  }
  return uri;
}

const federalProgramReferrals = [
  ReferralProvider(
    id: 'referral-usda-section-504',
    kind: ReferralProviderKind.programReferral,
    programId: 'usda-section-504',
    name: 'USDA Section 504 Home Repair',
    stateCodes: usStateCodes,
    description:
        'Rural repair loans (1%, must be repaid) for owners who live in the home; grants only for owners 62+. USDA confirms address, income, ownership and funding.',
    website:
        'https://www.rd.usda.gov/programs-services/single-family-housing-programs/single-family-housing-repair-loans-grants',
    areaNote:
        'Preparation only. Current USDA overview and regulation conflict on loan income policy. Ask the local Rural Development office to resolve this. Age 62 applies to grants, not all loans. No official application is generated.',
    sources: [
      'https://www.rd.usda.gov/programs-services/single-family-housing-programs/single-family-housing-repair-loans-grants',
      'https://www.ecfr.gov/current/title-7/subtitle-B/chapter-XXXV/part-3550/subpart-C/section-3550.103',
      'https://www.rd.usda.gov/media/file/download/rd-sfh-attachment12e.pdf',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2026-11-25',
  ),
  ReferralProvider(
    id: 'referral-va-hisa',
    kind: ReferralProviderKind.programReferral,
    programId: 'va-hisa',
    name: 'VA Home Improvements and Structural Alterations (HISA)',
    stateCodes: usStateCodes,
    description:
        'Official VA home-change route. A VA physician must write or approve the prescription; VA confirms eligibility and remaining benefit.',
    website: 'https://prosthetics.va.gov/psas/hisa2.asp',
    areaNote:
        'Preparation only. Ask local VA Prosthetics about a prescription, itemized estimate, before-work photo, form and actual property permission. Official form page and PDF revision dates differ; no mapped form is generated. This is not approval or submission.',
    sources: [
      'https://prosthetics.va.gov/psas/hisa2.asp',
      'https://www.va.gov/forms/10-0103/',
      'https://www.va.gov/VHAPUbLICAtIons/ViewPublication.asp?pub_ID=5739',
    ],
    reviewedOn: '2026-10-26',
    reviewAfter: '2026-11-25',
  ),
];
