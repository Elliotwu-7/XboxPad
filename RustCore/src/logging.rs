use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::RwLock;

pub type LogSinkFn = extern "C" fn(level: u8, message: *const c_char);

static LOG_SINK: RwLock<Option<LogSinkFn>> = RwLock::new(None);

/// Register an external C callback (e.g. Swift `os.Logger`) to receive all Rust logs.
/// level: 0 = info, 1 = warn, 2 = error
pub fn set_log_sink(sink: Option<LogSinkFn>) {
    if let Ok(mut guard) = LOG_SINK.write() {
        *guard = sink;
    }
}

fn dispatch(level: u8, message: String) {
    if let Ok(guard) = LOG_SINK.read() {
        if let Some(sink) = *guard {
            if let Ok(cstr) = CString::new(message.replace('\0', " ")) {
                sink(level, cstr.as_ptr());
                return;
            }
        }
    }
    match level {
        0 => eprintln!("[nano_rs] {message}"),
        1 => eprintln!("[nano_rs][WARN] {message}"),
        _ => eprintln!("[nano_rs][ERROR] {message}"),
    }
}

pub fn info(message: String) {
    dispatch(0, message);
}

pub fn warn(message: String) {
    dispatch(1, message);
}

pub fn error(message: String) {
    dispatch(2, message);
}

#[macro_export]
macro_rules! nano_log {
    ($($arg:tt)*) => {
        $crate::logging::info(format!($($arg)*))
    };
}

#[macro_export]
macro_rules! nano_warn {
    ($($arg:tt)*) => {
        $crate::logging::warn(format!($($arg)*))
    };
}

#[macro_export]
macro_rules! nano_error {
    ($($arg:tt)*) => {
        $crate::logging::error(format!($($arg)*))
    };
}
