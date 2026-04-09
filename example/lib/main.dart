import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_opaque/flutter_opaque.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: OpaqueDemo(),
    );
  }
}

class OpaqueDemo extends StatefulWidget {
  const OpaqueDemo({super.key});

  @override
  State<OpaqueDemo> createState() => _OpaqueDemoState();
}

class _OpaqueDemoState extends State<OpaqueDemo> {
  String _log = '';
  bool _running = false;

  void _appendLog(String line) {
    setState(() => _log += '$line\n');
  }

  Future<void> _runDemo() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log = '';
    });

    try {
      final username = utf8.encode('alice');
      final password = utf8.encode('hunter2');

      // ── Server Setup ────────────────────────────────────────────────────────
      _appendLog('Generating server setup…');
      final serverSetup = await serverSetupNew();
      _appendLog('Server setup: ${serverSetup.length} bytes');

      // ── Registration ────────────────────────────────────────────────────────
      _appendLog('\n[Registration]');

      // Step 1 – client
      final regStart = await clientRegistrationStart(password: password);
      _appendLog('Client reg start → request: ${regStart.registrationRequest.length} bytes');

      // Step 2 – server
      final regResponse = await serverRegistrationStart(
        serverSetup: serverSetup,
        registrationRequest: regStart.registrationRequest,
        credentialIdentifier: username,
      );
      _appendLog('Server reg start → response: ${regResponse.length} bytes');

      // Step 3 – client
      final regFinish = await clientRegistrationFinish(
        stateId: regStart.stateId,
        password: password,
        registrationResponse: regResponse,
      );
      _appendLog('Client reg finish → upload: ${regFinish.registrationUpload.length} bytes');
      _appendLog('  export_key: ${regFinish.exportKey.length} bytes');

      // Step 4 – server
      final passwordFile = await serverRegistrationFinish(
        registrationUpload: regFinish.registrationUpload,
      );
      _appendLog('Server reg finish → password file: ${passwordFile.length} bytes');

      // ── Login ───────────────────────────────────────────────────────────────
      _appendLog('\n[Login]');

      // Step 1 – client
      final loginStart = await clientLoginStart(password: password);
      _appendLog('Client login start → request: ${loginStart.credentialRequest.length} bytes');

      // Step 2 – server
      final srvLoginStart = await serverLoginStart(
        serverSetup: serverSetup,
        passwordFile: passwordFile,
        credentialRequest: loginStart.credentialRequest,
        credentialIdentifier: username,
      );
      _appendLog('Server login start → response: ${srvLoginStart.credentialResponse.length} bytes');

      // Step 3 – client
      final loginFinish = await clientLoginFinish(
        stateId: loginStart.stateId,
        password: password,
        credentialResponse: srvLoginStart.credentialResponse,
      );
      _appendLog('Client login finish → finalization: ${loginFinish.credentialFinalization.length} bytes');

      // Step 4 – server
      final serverSessionKey = await serverLoginFinish(
        stateId: srvLoginStart.stateId,
        credentialFinalization: loginFinish.credentialFinalization,
      );

      // ── Verify session keys match ────────────────────────────────────────────
      final keysMatch = _listsEqual(loginFinish.sessionKey, serverSessionKey);
      _appendLog('\nSession keys match: $keysMatch  ✓');
      _appendLog('Session key: ${loginFinish.sessionKey.length} bytes');
    } catch (e) {
      _appendLog('\nERROR: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  bool _listsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OPAQUE Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _running ? null : _runDemo,
              child: Text(_running ? 'Running…' : 'Run registration + login'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _log.isEmpty ? 'Press the button to run the OPAQUE demo.' : _log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
