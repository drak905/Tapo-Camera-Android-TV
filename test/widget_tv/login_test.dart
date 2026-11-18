// ui.login.mfa_back (existing behaviour)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tapo_tv/screens/login_screen.dart';
import 'package:tapo_tv/state/app_state.dart';
import 'package:tapo_tv/ui/tv.dart';

import 'support.dart';

void main() {
  testWidgets('the login screen shows when signed out, focus starts on Email', (tester) async {
    await pumpApp(tester, stage: AuthStage.signedOut);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
    final focused = FocusManager.instance.primaryFocus!;
    expect(focused.context, isNotNull);
    expect(find.descendant(of: find.ancestor(of: find.text('Email'), matching: find.byType(TvTextField)).first, matching: find.text('Email')), findsOneWidget);
  });

  testWidgets('select on the email field opens the text entry dialog', (tester) async {
    await pumpApp(tester, stage: AuthStage.signedOut);
    await ok(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(tvButton('Done'), findsOneWidget);
    expect(tvButton('Cancel'), findsOneWidget);
  });

  testWidgets('the entered email appears in the field', (tester) async {
    await pumpApp(tester, stage: AuthStage.signedOut);
    await ok(tester);
    await tester.enterText(find.byType(TextField), 'user@example.com');
    await tester.tap(tvButton('Done'));
    await settle(tester);
    expect(find.text('user@example.com'), findsOneWidget);
  });

  testWidgets('Back in the text entry dialog closes it without changing the field', (tester) async {
    await pumpApp(tester, stage: AuthStage.signedOut);
    await ok(tester);
    await back(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('the password field is obscured in the entry dialog', (tester) async {
    await pumpApp(tester, stage: AuthStage.signedOut);
    await focusOn(tester, find.byWidgetPredicate((w) => w is TvTextField && w.label == 'Password'));
    await ok(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(tvButton('Show'), findsOneWidget);
  });

  testWidgets('MFA: Back cancels back to the login stage', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = await pumpApp(tester, stage: AuthStage.signedOut);
    app.pendingMfa = PendingMfa(baseUrl: 'https://example.invalid', username: 'user@example.com', password: 'x', processId: 'p', types: [1, 2]);
    app.stage = AuthStage.mfa;
    app.notifyListeners();
    await settle(tester, const Duration(milliseconds: 600));
    expect(find.byType(MfaScreen), findsOneWidget);
    expect(find.text("Verify it's you"), findsOneWidget);
    await back(tester);
    await settle(tester, const Duration(milliseconds: 600));
    expect(app.stage, AuthStage.signedOut);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(MfaScreen), findsNothing);
    expect(LogicalKeyboardKey.select, isNotNull);
  });
}