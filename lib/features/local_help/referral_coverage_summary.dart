import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'referral_directory.dart';

class ReferralCoverageSummary extends StatelessWidget {
  const ReferralCoverageSummary({
    super.key,
    required this.directory,
    this.stateCode,
    required this.now,
  });
  final ReferralDirectory directory;
  final String? stateCode;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final organizations = directory.providers.where((p) => p.isLocalProvider);
    final ids = organizations.map((p) => p.canonicalOrganizationId).toSet();
    final states = organizations.expand((p) => p.stateCodes).toSet();
    final local = organizations.where((p) => p.stateCodes.contains(stateCode));
    final fresh = local.where((p) => !p.needsReview(now));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DefaultTextStyle.merge(
        style: Theme.of(context).textTheme.bodySmall,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            Text(context.tr('Official referral routes: all 50 states and DC.')),
            Text(
              context.tr(
                'Homi catalog: {count} organizations in {states} states.',
                {'count': '${ids.length}', 'states': '${states.length}'},
              ),
            ),
            if (stateCode != null)
              Text(
                context.tr(
                  'Reviewed organizations in this state: {count}; current records: {fresh}.',
                  {
                    'count':
                        '${local.map((p) => p.canonicalOrganizationId).toSet().length}',
                    'fresh':
                        '${fresh.map((p) => p.canonicalOrganizationId).toSet().length}',
                  },
                ),
              ),
            Text(
              context.tr(
                'Eligibility checks: no nationwide eligibility decision.',
              ),
            ),
            Text(
              context.tr(
                'Official form drafts: SCFHP (Santa Clara County) and HPSM (San Mateo County) members only, subject to plan review. Rebuilding Together Peninsula gets a preparation worksheet made by this app, not its official form. Federal routes provide preparation information only.',
              ),
            ),
            Text(
              context.tr(
                'Territory and Tribal service routes need separate review. Use the official locators to ask about your location.',
              ),
            ),
            Text(
              context.tr(
                'Listings do not establish address coverage, available funding or a partnership.',
              ),
            ),
            Text(
              context.tr('Catalog version: {version}', {
                'version': localProviderCatalogVersion,
              }),
            ),
          ],
        ),
      ),
    );
  }
}
