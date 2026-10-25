class ReferralState {
  const ReferralState(
    this.code,
    this.name,
    this.fips, {
    this.routingSupported = true,
  });
  final String code, name, fips;
  final bool routingSupported;
}

const usStates = <ReferralState>[
  ReferralState('AL', 'Alabama', '01'),
  ReferralState('AK', 'Alaska', '02'),
  ReferralState('AZ', 'Arizona', '04'),
  ReferralState('AR', 'Arkansas', '05'),
  ReferralState('CA', 'California', '06'),
  ReferralState('CO', 'Colorado', '08'),
  ReferralState('CT', 'Connecticut', '09'),
  ReferralState('DE', 'Delaware', '10'),
  ReferralState('DC', 'District of Columbia', '11'),
  ReferralState('FL', 'Florida', '12'),
  ReferralState('GA', 'Georgia', '13'),
  ReferralState('HI', 'Hawaii', '15'),
  ReferralState('ID', 'Idaho', '16'),
  ReferralState('IL', 'Illinois', '17'),
  ReferralState('IN', 'Indiana', '18'),
  ReferralState('IA', 'Iowa', '19'),
  ReferralState('KS', 'Kansas', '20'),
  ReferralState('KY', 'Kentucky', '21'),
  ReferralState('LA', 'Louisiana', '22'),
  ReferralState('ME', 'Maine', '23'),
  ReferralState('MD', 'Maryland', '24'),
  ReferralState('MA', 'Massachusetts', '25'),
  ReferralState('MI', 'Michigan', '26'),
  ReferralState('MN', 'Minnesota', '27'),
  ReferralState('MS', 'Mississippi', '28'),
  ReferralState('MO', 'Missouri', '29'),
  ReferralState('MT', 'Montana', '30'),
  ReferralState('NE', 'Nebraska', '31'),
  ReferralState('NV', 'Nevada', '32'),
  ReferralState('NH', 'New Hampshire', '33'),
  ReferralState('NJ', 'New Jersey', '34'),
  ReferralState('NM', 'New Mexico', '35'),
  ReferralState('NY', 'New York', '36'),
  ReferralState('NC', 'North Carolina', '37'),
  ReferralState('ND', 'North Dakota', '38'),
  ReferralState('OH', 'Ohio', '39'),
  ReferralState('OK', 'Oklahoma', '40'),
  ReferralState('OR', 'Oregon', '41'),
  ReferralState('PA', 'Pennsylvania', '42'),
  ReferralState('RI', 'Rhode Island', '44'),
  ReferralState('SC', 'South Carolina', '45'),
  ReferralState('SD', 'South Dakota', '46'),
  ReferralState('TN', 'Tennessee', '47'),
  ReferralState('TX', 'Texas', '48'),
  ReferralState('UT', 'Utah', '49'),
  ReferralState('VT', 'Vermont', '50'),
  ReferralState('VA', 'Virginia', '51'),
  ReferralState('WA', 'Washington', '53'),
  ReferralState('WV', 'West Virginia', '54'),
  ReferralState('WI', 'Wisconsin', '55'),
  ReferralState('WY', 'Wyoming', '56'),
];

const usTerritories = <ReferralState>[
  ReferralState('AS', 'American Samoa', '60', routingSupported: false),
  ReferralState('GU', 'Guam', '66', routingSupported: false),
  ReferralState(
    'MP',
    'Northern Mariana Islands',
    '69',
    routingSupported: false,
  ),
  ReferralState('PR', 'Puerto Rico', '72', routingSupported: false),
  ReferralState('VI', 'U.S. Virgin Islands', '78', routingSupported: false),
];

ReferralState? referralState(String? code) => code == null
    ? null
    : [
        ...usStates,
        ...usTerritories,
      ].where((s) => s.code == code.toUpperCase()).firstOrNull;

class ReferralServiceArea {
  const ReferralServiceArea({
    required this.stateCode,
    this.countyFips,
    this.countyName,
    this.cities = const [],
    this.zipCodes = const [],
    this.restriction,
  });
  final String stateCode;
  final String? countyFips, countyName, restriction;
  final List<String> cities, zipCodes;
}

const referralGeographySource =
    'https://www2.census.gov/geo/docs/reference/codes2020/national_county2020.txt';

const referralCountyFips = <String, Map<String, String>>{
  'PA': {'Philadelphia': '42101'},
  'AZ': {'Maricopa': '04013'},
  'CA': {
    'Alameda': '06001',
    'Contra Costa': '06013',
    'Marin': '06041',
    'Napa': '06055',
    'San Francisco': '06075',
    'San Mateo': '06081',
    'Santa Clara': '06085',
    'Solano': '06095',
    'Sonoma': '06097',
  },
  'TX': {
    'Bastrop': '48021',
    'Blanco': '48031',
    'Caldwell': '48055',
    'Hays': '48209',
    'Travis': '48453',
  },
  'VA': {
    'Botetourt': '51023',
    'Craig': '51045',
    'Floyd': '51063',
    'Franklin': '51067',
    'Roanoke': '51161',
    'Roanoke city': '51770',
    'Salem city': '51775',
  },
  'WA': {'King': '53033', 'Snohomish': '53061'},
};

const usStateCodes = <String>[
  'AL',
  'AK',
  'AZ',
  'AR',
  'CA',
  'CO',
  'CT',
  'DE',
  'DC',
  'FL',
  'GA',
  'HI',
  'ID',
  'IL',
  'IN',
  'IA',
  'KS',
  'KY',
  'LA',
  'ME',
  'MD',
  'MA',
  'MI',
  'MN',
  'MS',
  'MO',
  'MT',
  'NE',
  'NV',
  'NH',
  'NJ',
  'NM',
  'NY',
  'NC',
  'ND',
  'OH',
  'OK',
  'OR',
  'PA',
  'RI',
  'SC',
  'SD',
  'TN',
  'TX',
  'UT',
  'VT',
  'VA',
  'WA',
  'WV',
  'WI',
  'WY',
];
