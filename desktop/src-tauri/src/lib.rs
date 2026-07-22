mod api_client;
mod canonical;
mod commands;
mod config;
mod discovery;
mod guild;
mod ingest;
mod lua;
mod models;
mod queue;
mod state;
mod watcher;

use api_client::ApiClient;
use config::ConfigStore;
use queue::QueueStore;
use state::AppState;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app,_args,_cwd|{if let Some(window)=app.get_webview_window("main"){let _=window.show();let _=window.unminimize();let _=window.set_focus();}}))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent,Some(vec!["--background"])))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![commands::get_status,commands::get_coverage,commands::get_diagnostics,commands::add_wow_root,commands::scan_now,commands::sync_now,commands::start_pairing,commands::poll_pairing,commands::revoke_device,commands::unlock_with_passphrase,commands::delete_local_data])
        .setup(|app|{
            let data_dir=app.path().app_data_dir().map_err(|error|format!("Unable to locate app data: {error}"))?;
            let queue=QueueStore::open(&data_dir.join("queue.sqlite3")).map_err(|error|error.to_string())?;
            let vault_error=queue.unlock_from_os_vault().err().map(|error|error.to_string());
            queue.recover_uploading().map_err(|error|error.to_string())?;
            let config=ConfigStore::open(data_dir.join("config.json")).map_err(|error|error.to_string())?;
            let api=ApiClient::new(queue.clone()).map_err(|error|error.to_string())?;
            let state=AppState::new(config,queue,api);
            if let Some(error)=vault_error{state.diagnostic(models::DiagnosticLevel::Warning,format!("Operating-system credential vault unavailable; encrypted queue remains locked until a passphrase is supplied: {error}"));}
            app.manage(state.clone());
            build_tray(app.handle())?;
            if std::env::args().any(|argument|argument=="--background"){if let Some(window)=app.get_webview_window("main"){let _=window.hide();}}
            if let Err(error)=state.start_watcher(app.handle().clone()){state.diagnostic(models::DiagnosticLevel::Warning,format!("SavedVariables watcher could not start: {error}"));}
            let scan_state=state.clone();let scan_app=app.handle().clone();tauri::async_runtime::spawn_blocking(move||{let _=scan_state.scan(&scan_app);});
            Ok(())
        })
        .on_window_event(|window,event|{if let WindowEvent::CloseRequested{api,..}=event{api.prevent_close();let _=window.hide();}})
        .run(tauri::generate_context!())
        .expect("error while running EmberSync");
}

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open EmberSync", true, None::<&str>)?;
    let sync = MenuItem::with_id(app, "sync", "Sync now", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit EmberSync", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &sync, &quit])?;
    TrayIconBuilder::new()
        .tooltip("EmberSync — Raining Embers")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.unminimize();
                    let _ = window.set_focus();
                }
            }
            "sync" => {
                let state = app.state::<AppState>().inner().clone();
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    let paired = state.config().snapshot().paired_device;
                    if let Some(paired) = paired {
                        let _ = state.api().process_queue(&paired).await;
                        state.emit(&handle);
                    }
                });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}
