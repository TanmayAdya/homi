# Help routing data

County codes in `referral_geography.dart` reference the US Census
`national_county2020.txt` file. The recorded review date is October 26, 2026.
Only codes used by the catalog are included; Virginia independent cities keep
their own names and codes.

`zip_states.dart` holds a hand-maintained ZIP-prefix suggestion table with an
American Samoa exception. It does not validate whether a ZIP exists. Military,
unallocated and ambiguous prefixes return unknown; some ranges contain unused
prefixes. Users can correct the suggested state. Neither lookup establishes a
county, service coverage or program eligibility.
