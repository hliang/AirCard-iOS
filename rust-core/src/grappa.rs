use std::ffi::CStr;

// Resolve `ALGetGrappaToken` at link time instead of via `dlsym`.
//
// It is implemented in the app target (`GrappaHelper.m`) and used to be looked
// up at runtime with `dlsym(RTLD_DEFAULT, "ALGetGrappaToken")`. That works in
// Debug/local builds but fails in TestFlight/App Store builds: the archive's
// deployment post-processing (`STRIP_INSTALLED_PRODUCT=YES` +
// `DEAD_CODE_STRIPPING=YES`) removes the otherwise-unreferenced symbol from the
// export trie, so `dlsym` returns NULL and AirTraffic sync is rejected
// (`SyncFailed ErrorCode 4`). A direct reference makes the linker keep it.
extern "C" {
    fn ALGetGrappaToken(
        in_version: u32,
        in_device_type: u32,
        in_protocol_version: u32,
        out_buf: *mut u8,
        max_len: usize,
        out_len: *mut usize,
        err_buf: *mut libc::c_char,
        err_len: usize,
    ) -> libc::c_int;
}

/// Generate an authentic Grappa client token for AirTraffic sync.
///
/// Calls `ALGetGrappaToken`, which is implemented in `GrappaHelper.m` with full
/// `@autoreleasepool` and `@try/@catch` protection against ObjC exceptions.
pub fn generate_grappa_token<F: Fn(&str)>(
    device_info: Option<(u32, u32, u32)>,
    log: F,
) -> Option<Vec<u8>> {
    unsafe {
        let (ver, dt, pv) = device_info.unwrap_or((1, 0, 1));
        let mut buf = vec![0u8; 512];
        let mut out_len: usize = 0;
        let mut err_buf = [0 as libc::c_char; 256];

        let rc = ALGetGrappaToken(
            ver,
            dt,
            pv,
            buf.as_mut_ptr(),
            buf.len(),
            &mut out_len,
            err_buf.as_mut_ptr(),
            err_buf.len(),
        );

        if rc != 0 || out_len == 0 {
            let err_str = CStr::from_ptr(err_buf.as_ptr()).to_string_lossy();
            log(&format!("airlift: grappa: token generation failed (rc={rc}): {err_str}"));
            return None;
        }

        buf.truncate(out_len);
        log(&format!("airlift: grappa: successfully generated authentic Grappa token ({out_len} bytes) ✅"));
        Some(buf)
    }
}
