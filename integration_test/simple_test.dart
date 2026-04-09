import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_opaque/main.dart';
import 'package:flutter_opaque/src/rust/api/opaque.dart';
import 'package:flutter_opaque/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Can call rust function', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.textContaining('Result: `Hello, Tom!`'), findsOneWidget);
  });

  // Helper: run the full registration flow and return the password file.
  Future<({Uint8List serverSetup, Uint8List passwordFile})> register({
    required List<int> password,
    required List<int> credentialIdentifier,
  }) async {
    final serverSetup = await serverSetupNew();

    // Step 1 – client
    final regStart = await clientRegistrationStart(password: password);

    // Step 2 – server
    final regResponse = await serverRegistrationStart(
      serverSetup: serverSetup,
      registrationRequest: regStart.registrationRequest,
      credentialIdentifier: credentialIdentifier,
    );

    // Step 3 – client
    final regFinish = await clientRegistrationFinish(
      stateId: regStart.stateId,
      password: password,
      registrationResponse: regResponse,
    );

    // Step 4 – server
    final passwordFile = await serverRegistrationFinish(
      registrationUpload: regFinish.registrationUpload,
    );

    return (serverSetup: serverSetup, passwordFile: passwordFile);
  }

  group('OPAQUE Registration', () {
    test('正常な登録フロー', () async {
      final password = 'hunter2'.codeUnits;
      final credId = 'alice'.codeUnits;

      final result = await register(
        password: password,
        credentialIdentifier: credId,
      );

      expect(result.serverSetup, isNotEmpty);
      expect(result.passwordFile, isNotEmpty);
    });
  });

  group('OPAQUE Login', () {
    test('正常なログインフロー（セッションキーが一致する）', () async {
      final password = 'hunter2'.codeUnits;
      final credId = 'alice'.codeUnits;

      final reg = await register(
        password: password,
        credentialIdentifier: credId,
      );

      // Step 1 – client
      final loginStart = await clientLoginStart(password: password);

      // Step 2 – server
      final serverLogin = await serverLoginStart(
        serverSetup: reg.serverSetup,
        passwordFile: reg.passwordFile,
        credentialRequest: loginStart.credentialRequest,
        credentialIdentifier: credId,
      );

      // Step 3 – client
      final clientLogin = await clientLoginFinish(
        stateId: loginStart.stateId,
        password: password,
        credentialResponse: serverLogin.credentialResponse,
      );

      // Step 4 – server
      final serverSessionKey = await serverLoginFinish(
        stateId: serverLogin.stateId,
        credentialFinalization: clientLogin.credentialFinalization,
      );

      // Client and server must agree on the session key.
      expect(clientLogin.sessionKey, equals(serverSessionKey));
    });

    test('誤ったパスワードで clientLoginFinish が例外を返す', () async {
      final password = 'hunter2'.codeUnits;
      final wrongPassword = 'wrong!'.codeUnits;
      final credId = 'alice'.codeUnits;

      final reg = await register(
        password: password,
        credentialIdentifier: credId,
      );

      final loginStart = await clientLoginStart(password: wrongPassword);

      final serverLogin = await serverLoginStart(
        serverSetup: reg.serverSetup,
        passwordFile: reg.passwordFile,
        credentialRequest: loginStart.credentialRequest,
        credentialIdentifier: credId,
      );

      // The client detects the wrong password and must throw.
      await expectLater(
        () => clientLoginFinish(
          stateId: loginStart.stateId,
          password: wrongPassword,
          credentialResponse: serverLogin.credentialResponse,
        ),
        throwsA(anything),
      );
    });
  });

  group('OPAQUE stateId validation', () {
    test('無効な stateId を渡したときにエラーになる', () async {
      final invalidStateId = 999999999;
      final password = 'pass'.codeUnits;

      final reg = await register(
        password: password,
        credentialIdentifier: 'bob'.codeUnits,
      );

      final loginStart = await clientLoginStart(password: password);

      final serverLogin = await serverLoginStart(
        serverSetup: reg.serverSetup,
        passwordFile: reg.passwordFile,
        credentialRequest: loginStart.credentialRequest,
        credentialIdentifier: 'bob'.codeUnits,
      );

      // Use an invalid stateId — should throw.
      await expectLater(
        () => clientLoginFinish(
          stateId: invalidStateId,
          password: password,
          credentialResponse: serverLogin.credentialResponse,
        ),
        throwsA(anything),
      );
    });

    test('同じ stateId を二度使用したときにエラーになる', () async {
      final password = 'pass'.codeUnits;
      final credId = 'carol'.codeUnits;

      final reg = await register(
        password: password,
        credentialIdentifier: credId,
      );

      final loginStart = await clientLoginStart(password: password);

      final serverLogin = await serverLoginStart(
        serverSetup: reg.serverSetup,
        passwordFile: reg.passwordFile,
        credentialRequest: loginStart.credentialRequest,
        credentialIdentifier: credId,
      );

      // First call — should succeed.
      await clientLoginFinish(
        stateId: loginStart.stateId,
        password: password,
        credentialResponse: serverLogin.credentialResponse,
      );

      // Second call with the same stateId — must throw (state was consumed).
      await expectLater(
        () => clientLoginFinish(
          stateId: loginStart.stateId,
          password: password,
          credentialResponse: serverLogin.credentialResponse,
        ),
        throwsA(anything),
      );
    });
  });

  group('OPAQUE concurrency', () {
    test('並行した登録・ログインが互いに干渉しない', () async {
      // Prepare two independent users in parallel.
      final (reg1, reg2) = await (
        register(
          password: 'pass1'.codeUnits,
          credentialIdentifier: 'user1'.codeUnits,
        ),
        register(
          password: 'pass2'.codeUnits,
          credentialIdentifier: 'user2'.codeUnits,
        ),
      ).wait;

      // Start both logins concurrently.
      final (loginStart1, loginStart2) = await (
        clientLoginStart(password: 'pass1'.codeUnits),
        clientLoginStart(password: 'pass2'.codeUnits),
      ).wait;

      final (serverLogin1, serverLogin2) = await (
        serverLoginStart(
          serverSetup: reg1.serverSetup,
          passwordFile: reg1.passwordFile,
          credentialRequest: loginStart1.credentialRequest,
          credentialIdentifier: 'user1'.codeUnits,
        ),
        serverLoginStart(
          serverSetup: reg2.serverSetup,
          passwordFile: reg2.passwordFile,
          credentialRequest: loginStart2.credentialRequest,
          credentialIdentifier: 'user2'.codeUnits,
        ),
      ).wait;

      final (clientLogin1, clientLogin2) = await (
        clientLoginFinish(
          stateId: loginStart1.stateId,
          password: 'pass1'.codeUnits,
          credentialResponse: serverLogin1.credentialResponse,
        ),
        clientLoginFinish(
          stateId: loginStart2.stateId,
          password: 'pass2'.codeUnits,
          credentialResponse: serverLogin2.credentialResponse,
        ),
      ).wait;

      final (serverKey1, serverKey2) = await (
        serverLoginFinish(
          stateId: serverLogin1.stateId,
          credentialFinalization: clientLogin1.credentialFinalization,
        ),
        serverLoginFinish(
          stateId: serverLogin2.stateId,
          credentialFinalization: clientLogin2.credentialFinalization,
        ),
      ).wait;

      // Each user's session keys must agree independently.
      expect(clientLogin1.sessionKey, equals(serverKey1));
      expect(clientLogin2.sessionKey, equals(serverKey2));

      // The two users' session keys must differ from each other.
      expect(clientLogin1.sessionKey, isNot(equals(clientLogin2.sessionKey)));
    });
  });
}
