use crate::discovery;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use parking_lot::Mutex;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub struct WatcherService {
    running: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Default for WatcherService {
    fn default() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        }
    }
}

impl WatcherService {
    pub fn start<F>(&self, roots: Vec<PathBuf>, callback: F) -> Result<(), notify::Error>
    where
        F: Fn() + Send + 'static,
    {
        self.stop();
        let (event_tx, event_rx) = mpsc::channel();
        let notify_tx = event_tx.clone();
        let mut watcher: RecommendedWatcher =
            notify::recommended_watcher(move |result: notify::Result<Event>| {
                if result.is_ok_and(|event| {
                    event
                        .paths
                        .iter()
                        .any(|path| discovery::is_ember_sync_candidate_file(path))
                }) {
                    let _ = notify_tx.send(());
                }
            })?;
        let mut watched = 0;
        for root in roots.iter().filter(|root| root.exists()) {
            if watcher.watch(root, RecursiveMode::Recursive).is_ok() {
                watched += 1;
            }
        }
        if watched == 0 && !roots.is_empty() {
            return Err(notify::Error::generic(
                "no readable World of Warcraft roots",
            ));
        }
        let running = self.running.clone();
        running.store(true, Ordering::Release);
        let handle = thread::Builder::new()
            .name("embersync-watcher".into())
            .spawn(move || {
                let _watcher = watcher;
                let mut fingerprints = discovery::saved_variables_fingerprints(&roots);
                let mut last_scan = Instant::now() - Duration::from_secs(10);
                let mut event_pending = false;
                let mut event_at = Instant::now();
                while running.load(Ordering::Acquire) {
                    match event_rx.recv_timeout(Duration::from_secs(3)) {
                        Ok(()) => {
                            event_pending = true;
                            event_at = Instant::now();
                            while event_rx.try_recv().is_ok() {}
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                    let now = Instant::now();
                    let debounced = event_pending
                        && now.duration_since(event_at) >= Duration::from_millis(1500);
                    let polling = now.duration_since(last_scan) >= Duration::from_secs(10);
                    if debounced || polling {
                        let next = discovery::saved_variables_fingerprints(&roots);
                        if next != fingerprints {
                            fingerprints = next;
                            callback();
                        }
                        event_pending = false;
                        last_scan = now;
                    }
                }
            })
            .map_err(|error| notify::Error::generic(&error.to_string()))?;
        *self.thread.lock() = Some(handle);
        Ok(())
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::Release);
        if let Some(handle) = self.thread.lock().take() {
            let _ = handle.join();
        }
    }
    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }
}

impl Drop for WatcherService {
    fn drop(&mut self) {
        self.stop();
    }
}
