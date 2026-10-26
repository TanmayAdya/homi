class ProfileSuggestion {
  const ProfileSuggestion({
    required this.value,
    required this.label,
    this.detail,
    this.county,
    this.aliases = const [],
  });

  final String value;
  final String label;
  final String? detail;

  final String? county;
  final List<String> aliases;
}

List<ProfileSuggestion> profileSuggestions(String field, String query) {
  if (query.length > 256) return const [];
  final catalog = switch (field) {
    'city' => _cities,
    'county' => _counties,
    'healthPlan' => _healthPlans,
    _ => const <ProfileSuggestion>[],
  };
  final search = _normalize(query);
  if (search.isEmpty) {
    if (query.trim().isNotEmpty) return const [];
    return List<ProfileSuggestion>.unmodifiable(catalog.take(6));
  }
  final matches = <({ProfileSuggestion suggestion, int rank, int position})>[];
  for (var i = 0; i < catalog.length; i++) {
    final suggestion = catalog[i];
    var bestRank = 3;
    for (final candidate in [
      suggestion.value,
      suggestion.label,
      ...suggestion.aliases,
    ]) {
      final normalized = _normalize(candidate);
      final rank = normalized == search
          ? 0
          : normalized.startsWith(search)
          ? 1
          : normalized.contains(search)
          ? 2
          : 3;
      if (rank < bestRank) bestRank = rank;
    }
    if (bestRank < 3) {
      matches.add((suggestion: suggestion, rank: bestRank, position: i));
    }
  }
  matches.sort((a, b) {
    final rankOrder = a.rank.compareTo(b.rank);
    return rankOrder == 0 ? a.position.compareTo(b.position) : rankOrder;
  });
  return List<ProfileSuggestion>.unmodifiable(
    matches.take(6).map((match) => match.suggestion),
  );
}

String? canonicalProfileCounty(String value) {
  if (value.length > 256) return null;
  final normalized = _normalize(value);
  if (normalized.isEmpty) return null;
  for (final county in _counties) {
    if ([
      county.value,
      county.label,
      ...county.aliases,
    ].any((name) => _normalize(name) == normalized)) {
      return county.value;
    }
  }
  return null;
}

String _normalize(String value) {
  var result = value.toLowerCase();
  const folds = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'e': 'èéêëēĕėęě',
    'i': 'ìíîïĩīĭįı',
    'n': 'ñńņň',
    'o': 'òóôõöøōŏő',
    's': 'śŝşš',
    'u': 'ùúûüũūŭůűų',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  for (final entry in folds.entries) {
    result = result.replaceAll(RegExp('[${entry.value}]'), entry.key);
  }
  return result
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}

const _counties = [
  ProfileSuggestion(
    value: 'Santa Clara',
    label: 'Santa Clara County',
    detail: 'California',
    aliases: ['County of Santa Clara'],
  ),
  ProfileSuggestion(
    value: 'San Mateo',
    label: 'San Mateo County',
    detail: 'California',
    aliases: ['County of San Mateo'],
  ),
];

const _healthPlans = [
  ProfileSuggestion(
    value: 'Santa Clara Family Health Plan',
    label: 'Santa Clara Family Health Plan',
    detail: 'SCFHP',
    aliases: ['SCFHP'],
  ),
  ProfileSuggestion(
    value: 'Health Plan of San Mateo',
    label: 'Health Plan of San Mateo',
    detail: 'HPSM',
    aliases: ['HPSM'],
  ),
  ProfileSuggestion(
    value: 'Alameda Alliance for Health',
    label: 'Alameda Alliance for Health',
  ),
  ProfileSuggestion(value: 'Anthem Blue Cross', label: 'Anthem Blue Cross'),
  ProfileSuggestion(
    value: 'Contra Costa Health Plan',
    label: 'Contra Costa Health Plan',
  ),
  ProfileSuggestion(value: 'Kaiser Permanente', label: 'Kaiser Permanente'),
  ProfileSuggestion(
    value: 'Partnership Health Plan of California',
    label: 'Partnership Health Plan of California',
  ),
  ProfileSuggestion(
    value: 'San Francisco Health Plan',
    label: 'San Francisco Health Plan',
  ),
];

const _cities = [
  ProfileSuggestion(
    value: 'Atherton',
    label: 'Atherton',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Belmont',
    label: 'Belmont',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Brisbane',
    label: 'Brisbane',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Burlingame',
    label: 'Burlingame',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Campbell',
    label: 'Campbell',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Colma',
    label: 'Colma',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Cupertino',
    label: 'Cupertino',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Daly City',
    label: 'Daly City',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'East Palo Alto',
    label: 'East Palo Alto',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Foster City',
    label: 'Foster City',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Gilroy',
    label: 'Gilroy',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Half Moon Bay',
    label: 'Half Moon Bay',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Hillsborough',
    label: 'Hillsborough',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Los Altos',
    label: 'Los Altos',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Los Altos Hills',
    label: 'Los Altos Hills',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Los Gatos',
    label: 'Los Gatos',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Menlo Park',
    label: 'Menlo Park',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Millbrae',
    label: 'Millbrae',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Milpitas',
    label: 'Milpitas',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Monte Sereno',
    label: 'Monte Sereno',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Morgan Hill',
    label: 'Morgan Hill',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Mountain View',
    label: 'Mountain View',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Pacifica',
    label: 'Pacifica',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Palo Alto',
    label: 'Palo Alto',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Portola Valley',
    label: 'Portola Valley',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Redwood City',
    label: 'Redwood City',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'San Bruno',
    label: 'San Bruno',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'San Carlos',
    label: 'San Carlos',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'San José',
    label: 'San José',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
    aliases: ['San Jose'],
  ),
  ProfileSuggestion(
    value: 'San Mateo',
    label: 'San Mateo',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Santa Clara',
    label: 'Santa Clara',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Saratoga',
    label: 'Saratoga',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'South San Francisco',
    label: 'South San Francisco',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
  ProfileSuggestion(
    value: 'Sunnyvale',
    label: 'Sunnyvale',
    detail: 'Santa Clara County',
    county: 'Santa Clara',
  ),
  ProfileSuggestion(
    value: 'Woodside',
    label: 'Woodside',
    detail: 'San Mateo County',
    county: 'San Mateo',
  ),
];
