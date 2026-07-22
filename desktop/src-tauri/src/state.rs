use crate::{
    api_client::ApiClient,
    config::ConfigStore,
    discovery,
    ingest::{IngestError, Ingestor},
    models::*,
    queue::{QueueError, QueueStore},
    watcher::WatcherService,
};
use chrono::Utc;
use parking_lot::{Mutex, RwLock};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::atomic::{AtomicBool, Ordering},
    sync::Arc,
};
use tauri::{AppHandle, Emitter};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState(Arc<AppStateInner>);

struct AppStateInner {
    pub config: ConfigStore,
    pub queue: Arc<QueueStore>,
    pub api: ApiClient,
    pub status: RwLock<DesktopStatus>,
    pub coverage: RwLock<Vec<CoverageRow>>,
    pub diagnostics: RwLock<VecDeque<DiagnosticEvent>>,
    pub watcher: WatcherService,
    scan_lock: Mutex<()>,
    sync_in_progress: AtomicBool,
}

impl AppState {
    pub fn new(config: ConfigStore, queue: Arc<QueueStore>, api: ApiClient) -> Self {
        let snapshot = config.snapshot();
        let queue_summary = queue.summary().unwrap_or_default();
        let status = DesktopStatus {
            vault: if queue.is_unlocked() {
                VaultState::Ready
            } else {
                VaultState::Locked
            },
            connection: if snapshot.paired_device.is_some() {
                ConnectionState::Paired
            } else {
                ConnectionState::Unpaired
            },
            device_name: snapshot
                .paired_device
                .as_ref()
                .map(|device| device.device_name.clone()),
            device_id: snapshot
                .paired_device
                .as_ref()
                .map(|device| device.device_id.clone()),
            roots: snapshot
                .wow_roots
                .iter()
                .map(|path| path.display().to_string())
                .collect(),
            queue: queue_summary,
            ..DesktopStatus::default()
        };
        Self(Arc::new(AppStateInner {
            config,
            queue,
            api,
            status: RwLock::new(status),
            coverage: RwLock::new(vec![]),
            diagnostics: RwLock::new(VecDeque::new()),
            watcher: WatcherService::default(),
            scan_lock: Mutex::new(()),
            sync_in_progress: AtomicBool::new(false),
        }))
    }

    pub fn status(&self) -> DesktopStatus {
        let mut value = self.0.status.read().clone();
        value.queue = self.0.queue.summary().unwrap_or_default();
        value
    }
    pub fn coverage(&self) -> Vec<CoverageRow> {
        self.0.coverage.read().clone()
    }
    pub fn diagnostics(&self) -> Vec<DiagnosticEvent> {
        self.0.diagnostics.read().iter().cloned().collect()
    }
    pub fn config(&self) -> &ConfigStore {
        &self.0.config
    }
    pub fn api(&self) -> &ApiClient {
        &self.0.api
    }
    pub fn queue(&self) -> &QueueStore {
        &self.0.queue
    }

    pub fn start_watcher(&self, app: AppHandle) -> Result<(), String> {
        let roots = self.0.config.snapshot().wow_roots;
        let state = self.clone();
        let callback_app = app.clone();
        self.0
            .watcher
            .start(roots, move || {
                let _ = state.scan(&callback_app);
                state.schedule_background_sync(callback_app.clone());
            })
            .map_err(|error| error.to_string())?;
        self.0.status.write().watcher_running = true;
        self.emit(&app);
        Ok(())
    }

    pub fn restart_watcher(&self, app: AppHandle) -> Result<(), String> {
        self.0.watcher.stop();
        self.start_watcher(app)
    }

    pub fn scan(&self, app: &AppHandle) -> Result<DesktopStatus, String> {
        let _guard = self.0.scan_lock.lock();
        let config = self.0.config.snapshot();
        let files = discovery::discover_saved_variables(&config.wow_roots);
        let ingestor = Ingestor::new(self.0.queue.clone());
        let mut guilds: BTreeMap<GuildKey, GuildStatus> = BTreeMap::new();
        let mut coverage: BTreeMap<String, CoverageRow> = BTreeMap::new();
        let mut denied = 0;
        let mut errors = 0;
        let mut backups = 0;
        let mut queued = 0;
        for file in &files {
            match ingestor.ingest_path(file) {
                Ok(result) => {
                    queued += result.queued;
                    if result.used_backup {
                        backups += 1;
                    }
                    for guild in result.guilds {
                        guilds
                            .entry(guild.key)
                            .and_modify(|current| {
                                current.source_characters += guild.source_characters;
                                if guild.last_captured_at > current.last_captured_at {
                                    current.last_captured_at = guild.last_captured_at;
                                }
                            })
                            .or_insert(guild);
                    }
                    for row in result.coverage {
                        coverage.insert(
                            format!(
                                "{}:{}:{}",
                                row.guild_key.as_str(),
                                row.dataset,
                                row.subject_id
                            ),
                            row,
                        );
                    }
                }
                Err(IngestError::Guild(_) | IngestError::DatasetMismatch) => denied += 1,
                Err(IngestError::Queue(QueueError::Locked)) => errors += 1,
                Err(_) => errors += 1,
            }
        }
        *self.0.coverage.write() = coverage.into_values().collect();
        let membership = if !guilds.is_empty() {
            MembershipState::Authorized
        } else if denied > 0 {
            MembershipState::Denied
        } else {
            MembershipState::NoExports
        };
        let message = if !guilds.is_empty() {
            Some(format!(
                "Validated {} approved export{}; {} segment{} queued.",
                guilds.len(),
                if guilds.len() == 1 { "" } else { "s" },
                queued,
                if queued == 1 { "" } else { "s" }
            ))
        } else if denied > 0 {
            Some("SavedVariables did not match an approved Raining Embers guild identity.".into())
        } else if files.is_empty() {
            Some(
                "No EmberSync SavedVariables files were found in the configured WoW locations."
                    .into(),
            )
        } else if errors > 0 {
            Some("Membership could not be verified from the available SavedVariables.".into())
        } else {
            None
        };
        {
            let mut status = self.0.status.write();
            status.membership = membership;
            status.discovered_files = files.len();
            status.last_scan_at = Some(Utc::now());
            status.guilds = guilds.into_values().collect();
            status.roots = config
                .wow_roots
                .iter()
                .map(|path| path.display().to_string())
                .collect();
            status.queue = self.0.queue.summary().unwrap_or_default();
            status.vault = if self.0.queue.is_unlocked() {
                VaultState::Ready
            } else {
                VaultState::Locked
            };
            status.message = message;
            status.watcher_running = self.0.watcher.is_running();
        }
        if denied > 0 {
            self.diagnostic(DiagnosticLevel::Warning,format!("Rejected {denied} SavedVariables file{} with an unapproved or mismatched guild identity.",if denied==1{""}else{"s"}));
        }
        if errors > 0 {
            self.diagnostic(
                DiagnosticLevel::Warning,
                format!(
                    "Could not safely process {errors} SavedVariables file{}.",
                    if errors == 1 { "" } else { "s" }
                ),
            );
        }
        if backups > 0 {
            self.diagnostic(
                DiagnosticLevel::Warning,
                format!(
                    "Recovered {backups} export{} from a read-only .bak file.",
                    if backups == 1 { "" } else { "s" }
                ),
            );
        }
        self.emit(app);
        Ok(self.status())
    }

    pub fn update_connection(&self, connection: ConnectionState) {
        self.0.status.write().connection = connection;
    }
    pub fn schedule_background_sync(&self, app: AppHandle) {
        if !self.0.queue.is_unlocked()
            || self
                .0
                .sync_in_progress
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return;
        }
        let Some(paired) = self.0.config.snapshot().paired_device else {
            self.0.sync_in_progress.store(false, Ordering::Release);
            return;
        };
        let state = self.clone();
        tauri::async_runtime::spawn(async move {
            match state.api().process_queue(&paired).await {
                Ok(count) => {
                    state.update_connection(ConnectionState::Paired);
                    if count > 0 {
                        state.set_last_upload_now();
                        state.diagnostic(
                            DiagnosticLevel::Info,
                            format!(
                                "Automatically uploaded {count} encrypted segment{}.",
                                if count == 1 { "" } else { "s" }
                            ),
                        );
                    }
                }
                Err(error) => {
                    state.update_connection(ConnectionState::Error);
                    state.diagnostic(
                        DiagnosticLevel::Warning,
                        format!("Automatic sync deferred safely: {error}"),
                    );
                }
            }
            state.0.sync_in_progress.store(false, Ordering::Release);
            state.emit(&app);
        });
    }
    pub fn refresh_pairing_status(&self) {
        let config = self.0.config.snapshot();
        let mut status = self.0.status.write();
        status.connection = if config.paired_device.is_some() {
            ConnectionState::Paired
        } else {
            ConnectionState::Unpaired
        };
        status.device_name = config
            .paired_device
            .as_ref()
            .map(|value| value.device_name.clone());
        status.device_id = config
            .paired_device
            .as_ref()
            .map(|value| value.device_id.clone());
    }
    pub fn set_last_upload_now(&self) {
        self.0.status.write().last_upload_at = Some(Utc::now());
    }
    pub fn emit(&self, app: &AppHandle) {
        let _ = app.emit("embersync://status", self.status());
    }
    pub fn diagnostic(&self, level: DiagnosticLevel, message: String) {
        let mut values = self.0.diagnostics.write();
        values.push_front(DiagnosticEvent {
            id: Uuid::new_v4().to_string(),
            at: Utc::now(),
            level,
            message,
        });
        values.truncate(200);
    }
}

impl Ord for GuildKey {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_str().cmp(other.as_str())
    }
}
impl PartialOrd for GuildKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
