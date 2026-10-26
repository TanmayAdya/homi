import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';

LiveAppConfig config({bool email = false, bool signup = false}) =>
    LiveAppConfig(
      apiOrigin: Uri.parse('https://fictional-api.invalid'),
      supabaseUrl: Uri.parse('https://fictional.supabase.co'),
      publishableKey: 'fictional-publishable',
      emailDeliveryEnabled: email,
      publicSignupEnabled: signup,
    );

void main() {
  test('public signup defaults off and requires the account email gate', () {
    expect(config().publicSignupEnabled, false);
    expect(() => config(signup: true), throwsFormatException);
    expect(config(email: true, signup: true).publicSignupEnabled, true);
    expect(config(email: true).publicSignupEnabled, false);
  });
}
