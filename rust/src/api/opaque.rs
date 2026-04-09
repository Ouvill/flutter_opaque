// OPAQUE password-authenticated key exchange protocol bindings.
//
// This module exposes the client-side and server-side operations of the OPAQUE
// protocol. In production, only the client functions are used on the Flutter side;
// the server functions are included for testing and demonstration.
//
// Protocol flow:
//   Registration:
//     1. client_registration_start(password) -> (state_id, registration_request)
//     2. server_registration_start(server_setup, registration_request, credential_identifier) -> registration_response
//     3. client_registration_finish(state_id, password, registration_response) -> registration_upload + export_key
//     4. server_registration_finish(registration_upload) -> password_file
//
//   Login:
//     1. client_login_start(password) -> (state_id, credential_request)
//     2. server_login_start(server_setup, password_file, credential_request, credential_identifier) -> (state_id, credential_response)
//     3. client_login_finish(state_id, password, credential_response) -> (credential_finalization, session_key, export_key)
//     4. server_login_finish(state_id, credential_finalization) -> session_key

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::sync::atomic::{AtomicI64, Ordering};

use opaque_ke::argon2::Argon2;
use opaque_ke::ciphersuite::CipherSuite;
use rand::rngs::OsRng;
use opaque_ke::{
    ClientLogin, ClientLoginFinishParameters, ClientRegistration,
    ClientRegistrationFinishParameters, CredentialFinalization, CredentialRequest,
    CredentialResponse, RegistrationRequest, RegistrationResponse, RegistrationUpload,
    ServerLogin, ServerLoginParameters, ServerRegistration, ServerSetup,
};

// ---------------------------------------------------------------------------
// Cipher Suite
// ---------------------------------------------------------------------------

struct DefaultCS;

impl CipherSuite for DefaultCS {
    type OprfCs = opaque_ke::Ristretto255;
    type KeyExchange = opaque_ke::TripleDh<opaque_ke::Ristretto255, sha2::Sha512>;
    type Ksf = Argon2<'static>;
}

// ---------------------------------------------------------------------------
// In-memory state registries (states must stay in Rust memory between steps)
// ---------------------------------------------------------------------------

static CLIENT_REG_STORE: LazyLock<Mutex<HashMap<i64, ClientRegistration<DefaultCS>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static CLIENT_LOG_STORE: LazyLock<Mutex<HashMap<i64, ClientLogin<DefaultCS>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static SERVER_LOG_STORE: LazyLock<Mutex<HashMap<i64, ServerLogin<DefaultCS>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

static STATE_ID: AtomicI64 = AtomicI64::new(1);

fn next_id() -> i64 {
    STATE_ID.fetch_add(1, Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// DTOs (returned across the FFI boundary to Dart)
// ---------------------------------------------------------------------------

pub struct ClientRegistrationStartResult {
    /// Opaque handle; pass this back to `client_registration_finish`.
    pub state_id: i64,
    /// Serialized RegistrationRequest — send this to the server.
    pub registration_request: Vec<u8>,
}

pub struct ClientRegistrationFinishResult {
    /// Serialized RegistrationUpload — send this to the server.
    pub registration_upload: Vec<u8>,
    /// Export key derived from the password (can be used for local encryption).
    pub export_key: Vec<u8>,
}

pub struct ClientLoginStartResult {
    /// Opaque handle; pass this back to `client_login_finish`.
    pub state_id: i64,
    /// Serialized CredentialRequest — send this to the server.
    pub credential_request: Vec<u8>,
}

pub struct ServerLoginStartResult {
    /// Opaque handle; pass this back to `server_login_finish`.
    pub state_id: i64,
    /// Serialized CredentialResponse — send this to the client.
    pub credential_response: Vec<u8>,
}

pub struct ClientLoginFinishResult {
    /// Serialized CredentialFinalization — send this to the server.
    pub credential_finalization: Vec<u8>,
    /// Session key agreed upon with the server.
    pub session_key: Vec<u8>,
    /// Export key derived from the password (can be used for local encryption).
    pub export_key: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Server Setup
// ---------------------------------------------------------------------------

/// Generate a new ServerSetup (server's static key pair + OPRF seed).
/// Store the returned bytes securely on the server — they must persist across
/// registrations and logins.
pub fn server_setup_new() -> Result<Vec<u8>, String> {
    let mut rng = OsRng;
    let setup = ServerSetup::<DefaultCS>::new(&mut rng);
    Ok(setup.serialize().to_vec())
}

// ---------------------------------------------------------------------------
// Registration — client side
// ---------------------------------------------------------------------------

/// Step 1 (client): Start registration.
/// Returns a state handle and the registration request to send to the server.
pub fn client_registration_start(
    password: Vec<u8>,
) -> Result<ClientRegistrationStartResult, String> {
    let mut rng = OsRng;
    let result = ClientRegistration::<DefaultCS>::start(&mut rng, &password)
        .map_err(|e| e.to_string())?;
    let state_id = next_id();
    CLIENT_REG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .insert(state_id, result.state);
    Ok(ClientRegistrationStartResult {
        state_id,
        registration_request: result.message.serialize().to_vec(),
    })
}

/// Step 3 (client): Finish registration.
/// `state_id` must match the one returned from `client_registration_start`.
/// `registration_response` is the bytes received from the server (step 2).
/// Consumes the stored state — do not call twice for the same `state_id`.
pub fn client_registration_finish(
    state_id: i64,
    password: Vec<u8>,
    registration_response: Vec<u8>,
) -> Result<ClientRegistrationFinishResult, String> {
    let state = CLIENT_REG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .remove(&state_id)
        .ok_or_else(|| format!("No client registration state for id={state_id}"))?;

    let response = RegistrationResponse::<DefaultCS>::deserialize(&registration_response)
        .map_err(|e| e.to_string())?;

    let mut rng = OsRng;
    let result = state
        .finish(
            &mut rng,
            &password,
            response,
            ClientRegistrationFinishParameters::default(),
        )
        .map_err(|e| e.to_string())?;

    Ok(ClientRegistrationFinishResult {
        registration_upload: result.message.serialize().to_vec(),
        export_key: result.export_key.to_vec(),
    })
}

// ---------------------------------------------------------------------------
// Registration — server side
// ---------------------------------------------------------------------------

/// Step 2 (server): Process the client's registration request.
/// Returns the registration response bytes to send back to the client.
pub fn server_registration_start(
    server_setup: Vec<u8>,
    registration_request: Vec<u8>,
    credential_identifier: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let setup = ServerSetup::<DefaultCS>::deserialize(&server_setup)
        .map_err(|e| e.to_string())?;
    let request = RegistrationRequest::<DefaultCS>::deserialize(&registration_request)
        .map_err(|e| e.to_string())?;
    let result = ServerRegistration::<DefaultCS>::start(&setup, request, &credential_identifier)
        .map_err(|e| e.to_string())?;
    Ok(result.message.serialize().to_vec())
}

/// Step 4 (server): Finalise registration.
/// Returns the serialised password file — store this securely, keyed by the
/// credential identifier (username, user-id, etc.).
pub fn server_registration_finish(registration_upload: Vec<u8>) -> Result<Vec<u8>, String> {
    let upload = RegistrationUpload::<DefaultCS>::deserialize(&registration_upload)
        .map_err(|e| e.to_string())?;
    let password_file = ServerRegistration::finish(upload);
    Ok(password_file.serialize().to_vec())
}

// ---------------------------------------------------------------------------
// Login — client side
// ---------------------------------------------------------------------------

/// Step 1 (client): Start login.
/// Returns a state handle and the credential request to send to the server.
pub fn client_login_start(password: Vec<u8>) -> Result<ClientLoginStartResult, String> {
    let mut rng = OsRng;
    let result = ClientLogin::<DefaultCS>::start(&mut rng, &password)
        .map_err(|e| e.to_string())?;
    let state_id = next_id();
    CLIENT_LOG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .insert(state_id, result.state);
    Ok(ClientLoginStartResult {
        state_id,
        credential_request: result.message.serialize().to_vec(),
    })
}

/// Step 3 (client): Finish login.
/// Returns the credential finalization to send to the server plus the session
/// key and export key on success.  Returns an error if the password is wrong
/// (the client detects this before the server).
pub fn client_login_finish(
    state_id: i64,
    password: Vec<u8>,
    credential_response: Vec<u8>,
) -> Result<ClientLoginFinishResult, String> {
    let state = CLIENT_LOG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .remove(&state_id)
        .ok_or_else(|| format!("No client login state for id={state_id}"))?;

    let response = CredentialResponse::<DefaultCS>::deserialize(&credential_response)
        .map_err(|e| e.to_string())?;

    let mut rng = OsRng;
    let result = state
        .finish(
            &mut rng,
            &password,
            response,
            ClientLoginFinishParameters::default(),
        )
        .map_err(|e| e.to_string())?;

    Ok(ClientLoginFinishResult {
        credential_finalization: result.message.serialize().to_vec(),
        session_key: result.session_key.to_vec(),
        export_key: result.export_key.to_vec(),
    })
}

// ---------------------------------------------------------------------------
// Login — server side
// ---------------------------------------------------------------------------

/// Step 2 (server): Process the client's credential request.
/// `password_file` is what was stored by `server_registration_finish`.
/// Returns a state handle and the credential response to send to the client.
pub fn server_login_start(
    server_setup: Vec<u8>,
    password_file: Vec<u8>,
    credential_request: Vec<u8>,
    credential_identifier: Vec<u8>,
) -> Result<ServerLoginStartResult, String> {
    let setup = ServerSetup::<DefaultCS>::deserialize(&server_setup)
        .map_err(|e| e.to_string())?;
    let file = ServerRegistration::<DefaultCS>::deserialize(&password_file)
        .map_err(|e| e.to_string())?;
    let request = CredentialRequest::<DefaultCS>::deserialize(&credential_request)
        .map_err(|e| e.to_string())?;

    let mut rng = OsRng;
    let result = ServerLogin::start(
        &mut rng,
        &setup,
        Some(file),
        request,
        &credential_identifier,
        ServerLoginParameters::default(),
    )
    .map_err(|e| e.to_string())?;

    let state_id = next_id();
    SERVER_LOG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .insert(state_id, result.state);

    Ok(ServerLoginStartResult {
        state_id,
        credential_response: result.message.serialize().to_vec(),
    })
}

/// Step 4 (server): Finalise login.
/// Returns the session key on success; the caller should compare this with the
/// client's session key out-of-band (or use it to verify an authenticated
/// message from the client).
pub fn server_login_finish(
    state_id: i64,
    credential_finalization: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let state = SERVER_LOG_STORE
        .lock()
        .map_err(|_| "state store unavailable".to_string())?
        .remove(&state_id)
        .ok_or_else(|| format!("No server login state for id={state_id}"))?;

    let finalization = CredentialFinalization::<DefaultCS>::deserialize(&credential_finalization)
        .map_err(|e| e.to_string())?;

    let result = state
        .finish(finalization, ServerLoginParameters::default())
        .map_err(|e| e.to_string())?;

    Ok(result.session_key.to_vec())
}
