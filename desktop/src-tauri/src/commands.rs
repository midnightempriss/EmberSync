use crate::{
    models::*,
    state::{AppState, SyncTrigger},
};
use serde::Serialize;
use std::path::PathBuf;
use tauri::{AppHandle, State};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingStartView {
    pub verification_uri: String,
    pub user_code: String,
    pub expires_at: chrono::DateTime<chrono::Utc>,
}

#[tauri::command]
pub fn get_status(state: State<'_, AppState>) -> DesktopStatus {
    state.status()
}

#[tauri::command]
pub fn get_coverage(state: State<'_, AppState>) -> Vec<CoverageRow> {
    state.coverage()
}

#[tauri::command]
pub fn get_diagnostics(state: State<'_, AppState>) -> Vec<DiagnosticEvent> {
    state.diagnostics()
}

#[tauri::command]
pub async fn add_wow_root(
    path: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<DesktopStatus, String> {
    let path = PathBuf::from(path);
    state
        .config()
        .add_root(&path)
        .map_err(|error| error.to_string())?;
    state.restart_watcher(app.clone())?;
    let owned = state.inner().clone();
    let scan_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || owned.scan(&scan_app))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn scan_now(app: AppHandle, state: State<'_, AppState>) -> Result<DesktopStatus, String> {
    let owned = state.inner().clone();
    let scan_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || owned.scan(&scan_app))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn sync_now(app: AppHandle, state: State<'_, AppState>) -> Result<DesktopStatus, String> {
    state.sync_queue(&app, SyncTrigger::Manual).await
}

#[tauri::command]
pub async fn start_pairing(state: State<'_, AppState>) -> Result<PairingStartView, String> {
    let (response, pending) = state
        .api()
        .start_pairing()
        .await
        .map_err(|error| error.to_string())?;
    state
        .config()
        .set_pending_pairing(Some(pending))
        .map_err(|error| error.to_string())?;
    Ok(PairingStartView {
        verification_uri: response.verification_uri,
        user_code: response.verification_code,
        expires_at: response.expires_at,
    })
}

#[tauri::command]
pub async fn poll_pairing(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<DesktopStatus, String> {
    let pending = state
        .config()
        .snapshot()
        .pending_pairing
        .ok_or_else(|| "No pairing request is active.".to_string())?;
    if let Some(paired) = state
        .api()
        .poll_pairing(&pending)
        .await
        .map_err(|error| error.to_string())?
    {
        state
            .queue()
            .release_authorization_required()
            .map_err(|error| error.to_string())?;
        state
            .config()
            .set_paired_device(Some(paired))
            .map_err(|error| error.to_string())?;
        state
            .config()
            .set_pending_pairing(None)
            .map_err(|error| error.to_string())?;
        state.refresh_pairing_status();
        state.diagnostic(
            DiagnosticLevel::Info,
            "This device was paired with a verified Raining Embers member.".into(),
        );
        state.emit(&app);
    }
    Ok(state.status())
}

#[tauri::command]
pub async fn revoke_device(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<DesktopStatus, String> {
    let paired = state.config().snapshot().paired_device;
    if let Some(paired) = paired.as_ref() {
        if let Err(error) = state.api().revoke(paired).await {
            if error.confirms_device_is_inactive() {
                state.diagnostic(
                    DiagnosticLevel::Warning,
                    "The website had already revoked this device; EmberSync removed the stale local connection.".into(),
                );
            } else {
                state.diagnostic(
                    DiagnosticLevel::Error,
                    format!("Website device revocation failed safely: {error}"),
                );
                state.emit(&app);
                return Err(error.to_string());
            }
        }
    }
    state
        .config()
        .clear_pairing()
        .map_err(|error| error.to_string())?;
    if paired.is_some() {
        if let Err(error) = state.api().forget_signing_key() {
            // The server and local connection are already revoked. A stale key
            // is encrypted at rest and cannot authorize a revoked device, so a
            // cleanup failure should not make the Revoke button appear broken.
            state.diagnostic(
                DiagnosticLevel::Warning,
                format!("The device was revoked, but its obsolete local signing key could not be removed: {error}"),
            );
        }
    }
    state.refresh_pairing_status();
    state.diagnostic(
        DiagnosticLevel::Info,
        "This device's upload authorization was revoked.".into(),
    );
    state.emit(&app);
    Ok(state.status())
}

#[tauri::command]
pub async fn unlock_with_passphrase(
    passphrase: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<DesktopStatus, String> {
    let queue = state.queue();
    queue
        .unlock_with_passphrase(&passphrase)
        .map_err(|error| error.to_string())?;
    let owned = state.inner().clone();
    let scan_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || owned.scan(&scan_app))
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub fn delete_local_data(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<DesktopStatus, String> {
    state
        .queue()
        .delete_all()
        .map_err(|error| error.to_string())?;
    state.diagnostic(
        DiagnosticLevel::Info,
        "Encrypted local upload queue was deleted.".into(),
    );
    state.emit(&app);
    Ok(state.status())
}
