use crate::{
    api_client::ApiClient,
    api_client::ApiError,
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
    future::Future,
    sync::atomic::{AtomicBool, Ordering},
    sync::Arc,
    time::Duration,
};
use tauri::{AppHandle, Emitter};
use tokio::time::{Instant, MissedTickBehavior};
use uuid::Uuid;

const MAX_DRAIN_BATCHES: usize = 32;
const AUTO_SYNC_INTERVAL: Duration = Duration::from_secs(AUTO_SYNC_INTERVAL_MINUTES * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DrainStep {
    Done,
    Continue,
    ContinueLater,
}

fn next_drain_step(has_ready_work: bool, batches_completed: usize) -> DrainStep {
    if !has_ready_work {
        DrainStep::Done
    } else if batches_completed >= MAX_DRAIN_BATCHES {
        DrainStep::ContinueLater
    } else {
        DrainStep::Continue
    }
}

fn automatic_sync_eligible(vault_unlocked: bool, paired: bool) -> bool {
    vault_unlocked && paired
}

async fn run_periodic<F, Fut>(interval: Duration, mut on_tick: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = ()>,
{
    let mut ticker = tokio::time::interval_at(Instant::now() + interval, interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        on_tick().await;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncTrigger {
    Manual,
    Tray,
    Watcher,
    Startup,
    Scheduled,
    Continuation,
}

impl SyncTrigger {
    fn is_user_initiated(self) -> bool {
        matches!(self, Self::Manual | Self::Tray)
    }

    fn success_message(self, count: usize) -> String {
        let noun = if count == 1 { "segment" } else { "segments" };
        match self {
            Self::Manual | Self::Tray => {
                format!("Completed {count} encrypted upload {noun}.")
            }
            Self::Watcher | Self::Startup | Self::Scheduled | Self::Continuation => {
                format!("Automatically uploaded {count} encrypted {noun}.")
            }
        }
    }

    fn failure_message(self, error: &str) -> String {
        match self {
            Self::Manual | Self::Tray => format!("Website sync failed safely: {error}"),
            Self::Watcher | Self::Startup | Self::Scheduled | Self::Continuation => {
                format!("Automatic sync deferred safely: {error}")
            }
        }
    }
}

struct SingleFlightGuard<'a>(&'a AtomicBool);

impl Drop for SingleFlightGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn try_acquire_single_flight(flag: &AtomicBool) -> Option<SingleFlightGuard<'_>> {
    flag.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .ok()
        .map(|_| SingleFlightGuard(flag))
}

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
                if state.scan(&callback_app).is_ok() {
                    state.schedule_automatic_sync(callback_app.clone(), SyncTrigger::Watcher);
                }
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

    pub fn start_auto_sync(&self, app: AppHandle) {
        self.start_auto_sync_with_interval(app, AUTO_SYNC_INTERVAL);
    }

    fn start_auto_sync_with_interval(&self, app: AppHandle, interval: Duration) {
        self.set_next_auto_sync(&app, interval);
        let state = self.clone();
        tauri::async_runtime::spawn(async move {
            run_periodic(interval, move || {
                let state = state.clone();
                let app = app.clone();
                async move {
                    // Publish the following due time before doing any file or
                    // network work so the UI never shows an elapsed deadline.
                    state.set_next_auto_sync(&app, interval);
                    state.run_scheduled_sync_cycle(&app).await;
                }
            })
            .await;
        });
    }

    async fn run_scheduled_sync_cycle(&self, app: &AppHandle) {
        let scan_state = self.clone();
        let scan_app = app.clone();
        match tauri::async_runtime::spawn_blocking(move || scan_state.scan(&scan_app)).await {
            Ok(Ok(_)) => {
                self.schedule_automatic_sync(app.clone(), SyncTrigger::Scheduled);
            }
            Ok(Err(error)) => {
                self.diagnostic(
                    DiagnosticLevel::Warning,
                    format!("Scheduled SavedVariables scan could not complete safely: {error}"),
                );
                self.emit(app);
            }
            Err(error) => {
                self.diagnostic(
                    DiagnosticLevel::Warning,
                    format!("Scheduled SavedVariables scan could not start safely: {error}"),
                );
                self.emit(app);
            }
        }
    }

    pub fn schedule_automatic_sync(&self, app: AppHandle, trigger: SyncTrigger) {
        if automatic_sync_eligible(
            self.0.queue.is_unlocked(),
            self.0.config.snapshot().paired_device.is_some(),
        ) {
            self.schedule_sync(app, trigger);
        }
    }

    pub fn schedule_sync(&self, app: AppHandle, trigger: SyncTrigger) {
        let state = self.clone();
        tauri::async_runtime::spawn(async move {
            let _ = state.sync_queue(&app, trigger).await;
        });
    }

    pub fn schedule_rescan_and_sync(&self, app: AppHandle, trigger: SyncTrigger) {
        let state = self.clone();
        tauri::async_runtime::spawn(async move {
            let _ = state.rescan_and_sync(&app, trigger).await;
        });
    }

    pub async fn rescan_and_sync(
        &self,
        app: &AppHandle,
        trigger: SyncTrigger,
    ) -> Result<DesktopStatus, String> {
        let scan_state = self.clone();
        let scan_app = app.clone();
        tauri::async_runtime::spawn_blocking(move || scan_state.scan(&scan_app))
            .await
            .map_err(|error| error.to_string())??;
        self.sync_queue(app, trigger).await
    }

    pub fn start_pairing_poll(&self, app: AppHandle, interval_seconds: u64) {
        let state = self.clone();
        let interval = Duration::from_secs(interval_seconds.clamp(1, 60));
        tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;
                let snapshot = state.0.config.snapshot();
                if snapshot.paired_device.is_some() {
                    break;
                }
                let Some(pending) = snapshot.pending_pairing else {
                    break;
                };
                if pending.expires_at <= Utc::now() {
                    let _ = state.0.config.set_pending_pairing(None);
                    state.diagnostic(
                        DiagnosticLevel::Warning,
                        "The website pairing request expired before approval.".into(),
                    );
                    state.emit(&app);
                    break;
                }
                match state.0.api.poll_pairing(&pending).await {
                    Ok(Some(paired)) => {
                        if let Err(error) = state.0.config.set_paired_device(Some(paired)) {
                            state.diagnostic(
                                DiagnosticLevel::Error,
                                format!("Approved pairing could not be saved safely: {error}"),
                            );
                            state.emit(&app);
                            break;
                        }
                        let _ = state.0.config.set_pending_pairing(None);
                        let _ = state.0.queue.release_authorization_required();
                        state.refresh_pairing_status();
                        state.diagnostic(
                            DiagnosticLevel::Info,
                            "This device was paired automatically after website approval.".into(),
                        );
                        state.emit(&app);
                        state.schedule_automatic_sync(app.clone(), SyncTrigger::Scheduled);
                        break;
                    }
                    Ok(None) => {}
                    Err(ApiError::PairingExpired | ApiError::PairingDenied) => {
                        let _ = state.0.config.set_pending_pairing(None);
                        state.diagnostic(
                            DiagnosticLevel::Warning,
                            "The website pairing request expired or was denied.".into(),
                        );
                        state.emit(&app);
                        break;
                    }
                    Err(_) => {
                        // A transient provider or network failure is retried at
                        // the server-supplied cadence until the request expires.
                    }
                }
            }
        });
    }

    pub async fn sync_queue(
        &self,
        app: &AppHandle,
        trigger: SyncTrigger,
    ) -> Result<DesktopStatus, String> {
        let Some(flight) = try_acquire_single_flight(&self.0.sync_in_progress) else {
            return Err(
                "A sync is already in progress; EmberSync did not start a duplicate upload.".into(),
            );
        };
        if !self.0.queue.is_unlocked() {
            return Err("Unlock the encrypted local vault before syncing.".into());
        }
        let paired = self.0.config.snapshot().paired_device.ok_or_else(|| {
            "Connect this device to rainingembers.org before syncing.".to_string()
        })?;

        // Only a deliberate user action releases uploads paused after the
        // website requested fresh Battle.net verification. Watcher and startup
        // activity must never turn that policy failure into a retry storm.
        if trigger.is_user_initiated() {
            self.0
                .queue
                .release_authorization_required()
                .map_err(|error| error.to_string())?;
            self.update_connection(ConnectionState::Connecting);
            self.emit(app);
        }

        let mut uploaded = 0;
        let mut reached_drain_limit = false;
        for batch_index in 0..MAX_DRAIN_BATCHES {
            match self.0.api.process_queue(&paired).await {
                Ok(count) => {
                    uploaded += count;
                    let has_ready_work = match self.0.queue.has_ready_now() {
                        Ok(value) => value,
                        Err(error) => {
                            self.refresh_pairing_status();
                            self.diagnostic(
                                if trigger.is_user_initiated() {
                                    DiagnosticLevel::Error
                                } else {
                                    DiagnosticLevel::Warning
                                },
                                trigger.failure_message(&error.to_string()),
                            );
                            self.emit(app);
                            return Err(error.to_string());
                        }
                    };
                    match next_drain_step(has_ready_work, batch_index + 1) {
                        DrainStep::Done => break,
                        DrainStep::Continue => tokio::task::yield_now().await,
                        DrainStep::ContinueLater => {
                            reached_drain_limit = true;
                            break;
                        }
                    }
                }
                Err(error) => {
                    // Upload availability and pairing are separate states. The
                    // encrypted queue records whether a retry or fresh Battle.net
                    // verification is needed without silently dropping pairing.
                    self.refresh_pairing_status();
                    self.diagnostic(
                        if trigger.is_user_initiated() {
                            DiagnosticLevel::Error
                        } else {
                            DiagnosticLevel::Warning
                        },
                        trigger.failure_message(&error.to_string()),
                    );
                    self.emit(app);
                    return Err(error.to_string());
                }
            }
        }

        self.refresh_pairing_status();
        if uploaded > 0 {
            self.set_last_upload_now();
            self.diagnostic(DiagnosticLevel::Info, trigger.success_message(uploaded));
        }
        self.emit(app);

        // Bound each worker so a continuously changing SavedVariables file cannot
        // monopolize the async runtime. A continuation reacquires the same global
        // single-flight guard after this worker has fully released it.
        drop(flight);
        if reached_drain_limit {
            self.schedule_sync(app.clone(), SyncTrigger::Continuation);
        }
        Ok(self.status())
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
    fn set_next_auto_sync(&self, app: &AppHandle, interval: Duration) {
        let interval = chrono::Duration::from_std(interval)
            .unwrap_or_else(|_| chrono::Duration::minutes(AUTO_SYNC_INTERVAL_MINUTES as i64));
        self.0.status.write().next_auto_sync_at = Some(Utc::now() + interval);
        self.emit(app);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn single_flight_rejects_overlap_and_releases_on_drop() {
        let flag = AtomicBool::new(false);
        let first = try_acquire_single_flight(&flag).expect("first worker acquires the guard");
        assert!(try_acquire_single_flight(&flag).is_none());
        drop(first);
        assert!(try_acquire_single_flight(&flag).is_some());
    }

    #[test]
    fn drain_continues_while_work_is_ready_and_yields_at_its_bound() {
        for completed in 1..MAX_DRAIN_BATCHES {
            assert_eq!(next_drain_step(true, completed), DrainStep::Continue);
        }
        assert_eq!(
            next_drain_step(true, MAX_DRAIN_BATCHES),
            DrainStep::ContinueLater
        );
        assert_eq!(next_drain_step(false, 1), DrainStep::Done);
    }

    #[test]
    fn automatic_sync_requires_both_pairing_and_an_unlocked_vault() {
        assert!(automatic_sync_eligible(true, true));
        assert!(!automatic_sync_eligible(false, true));
        assert!(!automatic_sync_eligible(true, false));
        assert!(!automatic_sync_eligible(false, false));
    }

    #[tokio::test(start_paused = true)]
    async fn periodic_runner_waits_for_each_injected_interval() {
        let ticks = Arc::new(AtomicUsize::new(0));
        let task_ticks = ticks.clone();
        let task = tokio::spawn(async move {
            run_periodic(Duration::from_secs(15), move || {
                task_ticks.fetch_add(1, Ordering::SeqCst);
                std::future::ready(())
            })
            .await;
        });

        tokio::task::yield_now().await;
        assert_eq!(ticks.load(Ordering::SeqCst), 0);

        tokio::time::advance(Duration::from_secs(14)).await;
        tokio::task::yield_now().await;
        assert_eq!(ticks.load(Ordering::SeqCst), 0);

        tokio::time::advance(Duration::from_secs(1)).await;
        tokio::task::yield_now().await;
        assert_eq!(ticks.load(Ordering::SeqCst), 1);

        tokio::time::advance(Duration::from_secs(15)).await;
        tokio::task::yield_now().await;
        assert_eq!(ticks.load(Ordering::SeqCst), 2);

        task.abort();
    }
}
